# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/pe_snapshot/providers/proxmox'

describe PeSnapshot::Providers::Proxmox do
  subject(:provider) { described_class.new(endpoint, http: http) }

  let(:endpoint) { { 'name' => 'lab', 'url' => 'https://pve:8006', 'credentials' => { 'token_id' => 'u@pve!t', 'token_secret' => 's' } } }
  let(:http) { instance_double(PeSnapshot::HTTP) }
  let(:resources) do
    { 'data' => [
      { 'type' => 'qemu', 'vmid' => 101, 'node' => 'pve1', 'template' => 0 },
      { 'type' => 'qemu', 'vmid' => 9000, 'node' => 'pve1', 'template' => 1 },
      { 'type' => 'lxc', 'vmid' => 700, 'node' => 'stolat' },
    ] }
  end
  let(:vm) { { 'vm_id' => '101', 'node' => 'pve1', 'vmid' => 101 } }

  before(:each) do
    allow(http).to receive(:get).with('/cluster/resources?type=vm').and_return(resources)
    stub_const('PeSnapshot::Providers::Proxmox::POLL_SECONDS', 0)
  end

  it 'needs a token' do
    expect { described_class.new(endpoint.merge('credentials' => {}), http: http) }.to raise_error(PeSnapshot::Error, %r{token_id})
  end

  it 'lists only qemu VMs that are not templates' do
    expect(provider.vms.map { |v| v['vmid'] }).to eq([101])
  end

  it 'resolves a VM by its SMBIOS uuid' do
    allow(http).to receive(:get).with('/nodes/pve1/qemu/101/config').and_return('data' => { 'smbios1' => 'uuid=53F5C75D-42C9-4FC3-B79B-285A14DD05BA' })
    expect(provider.resolve('53f5c75d-42c9-4fc3-b79b-285a14dd05ba')).to include('vmid' => 101, 'node' => 'pve1')
  end

  it 'refuses a uuid shared by two VMs, as a clone can be' do
    resources['data'] << { 'type' => 'qemu', 'vmid' => 102, 'node' => 'morpork', 'template' => 0 }
    allow(http).to receive(:get).with(%r{/qemu/10[12]/config}).and_return('data' => { 'smbios1' => 'uuid=53f5c75d-42c9-4fc3-b79b-285a14dd05ba' })
    expect { provider.resolve('53f5c75d-42c9-4fc3-b79b-285a14dd05ba') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/ambiguous_vm') }
  end

  it 'resolves a VM by vmid' do
    expect(provider.resolve('101')).to include('node' => 'pve1')
  end

  it 'reports a VM it cannot find' do
    expect { provider.resolve('555') }.to raise_error(PeSnapshot::Error, %r{No VM matches '555' on endpoint lab})
  end

  it 'leaves out the current pseudo-snapshot' do
    allow(http).to receive(:get).with('/nodes/pve1/qemu/101/snapshot')
                                .and_return('data' => [{ 'name' => 'current' }, { 'name' => 'pes-a', 'description' => 'd', 'snaptime' => 5 }])
    expect(provider.list(vm)).to eq([{ 'name' => 'pes-a', 'description' => 'd', 'created' => 5 }])
  end

  it 'creates a snapshot and waits for its task to finish' do
    allow(http).to receive(:post).with('/nodes/pve1/qemu/101/snapshot', 'snapname' => 'pes-a', 'description' => 'meta', 'vmstate' => 1).and_return('data' => 'UPID:x')
    allow(http).to receive(:get).with('/nodes/pve1/tasks/UPID%3Ax/status').and_return({ 'data' => { 'status' => 'running' } },
                                                                                      { 'data' => { 'status' => 'stopped', 'exitstatus' => 'OK' } })
    expect(provider.create(vm, 'pes-a', 'meta', memory: true)).to be(true)
    expect(http).to have_received(:get).with('/nodes/pve1/tasks/UPID%3Ax/status').twice
  end

  it 'raises when the task fails' do
    allow(http).to receive(:delete).and_return('data' => 'UPID:y')
    allow(http).to receive(:get).with('/nodes/pve1/tasks/UPID%3Ay/status').and_return('data' => { 'status' => 'stopped', 'exitstatus' => 'snapshot is locked' })
    expect { provider.delete(vm, 'pes-a') }.to raise_error(PeSnapshot::Error, %r{locked})
  end
end

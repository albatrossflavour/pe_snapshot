# frozen_string_literal: true

require 'spec_helper'

describe 'pe_snapshot' do
  let(:base) { { 'os' => { 'family' => 'RedHat' }, 'dmi' => { 'product' => { 'uuid' => 'ABC-1' } } } }

  def target_config
    JSON.parse(catalogue.resource('File', '/etc/puppetlabs/pe_snapshot/target.json')[:content])
  end

  context 'on a kvm guest with proxy and endpoint in Hiera' do
    let(:facts) { base.merge('virtual' => 'kvm') }
    let(:params) { { 'proxy' => 'puppet.example.com', 'endpoint' => 'lab_pve' } }

    it { is_expected.to compile.with_all_deps }
    it { expect(target_config).to eq('provider' => 'proxmox', 'proxy' => 'puppet.example.com', 'endpoint' => 'lab_pve', 'vm_id' => 'abc-1', 'mapped' => true) }
  end

  context 'with no proxy' do
    let(:facts) { base.merge('virtual' => 'kvm') }

    it { expect(target_config['mapped']).to be(false) }
  end

  context 'on GCE' do
    let(:facts) { base.merge('virtual' => 'gce', 'gce' => { 'instance' => { 'name' => 'web1', 'zone' => 'projects/1/zones/australia-southeast1-b' } }) }

    it { expect(target_config).to include('provider' => 'gce', 'vm_id' => 'australia-southeast1-b/web1') }
  end

  context 'on AWS, where virtual is kvm too' do
    let(:facts) { base.merge('virtual' => 'kvm', 'ec2_metadata' => { 'instance-id' => 'i-0abc' }) }

    it { expect(target_config).to include('provider' => 'aws', 'vm_id' => 'i-0abc') }
  end

  context 'on Windows' do
    let(:facts) { base.merge('virtual' => 'kvm', 'os' => { 'family' => 'windows' }) }

    it { is_expected.to contain_file('C:/ProgramData/PuppetLabs/pe_snapshot/target.json') }
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require_relative '../../../lib/pe_snapshot/actions'

# An in-memory provider with the same interface as the real ones.
class FakeProvider
  attr_reader :snaps, :calls

  def initialize(snaps = {})
    @snaps = snaps
    @calls = []
  end

  def vms
    @snaps.keys.map { |id| { 'vm_id' => id } }
  end

  def resolve(vm_id)
    raise PeSnapshot::Error.new('vm_not_found', "no #{vm_id}") unless @snaps.key?(vm_id)

    { 'vm_id' => vm_id }
  end

  def list(vm)
    @snaps[vm['vm_id']]
  end

  def create(vm, name, description, memory:, quiesce:)
    @calls << [:create, vm['vm_id'], name, memory, quiesce]
    @snaps[vm['vm_id']] << { 'name' => name, 'description' => description, 'created' => 0 }
  end

  def delete(vm, name)
    @calls << [:delete, vm['vm_id'], name]
    @snaps[vm['vm_id']].reject! { |s| s['name'] == name }
  end

  def restore(vm, name, start:)
    @calls << [:restore, vm['vm_id'], name, start]
  end
end

describe PeSnapshot::Actions do
  let(:now) { Time.at(1_760_000_000) }
  let(:endpoint) { { 'name' => 'lab', 'provider' => 'fake', 'default_retention_hours' => 24, 'max_retention_hours' => 168 } }
  let(:provider) { FakeProvider.new('100' => [], '200' => []) }
  let(:vms) { [{ 'certname' => 'a.example.com', 'vm_id' => '100' }, { 'certname' => 'b.example.com', 'vm_id' => '200' }] }

  def managed_snap(name, tag, created, expires)
    meta = { 'pe_snapshot' => 1, 'certname' => 'a.example.com', 'tag' => tag, 'created' => created, 'expires' => expires }
    { 'name' => name, 'description' => PeSnapshot.encode_meta(meta), 'created' => created }
  end

  describe 'create' do
    it 'snapshots every VM with the same name and default expiry' do
      out = described_class.create(provider, endpoint, { 'tag' => 'run1', 'vms' => vms }, now)['results']
      expect(out.keys).to eq(['a.example.com', 'b.example.com'])
      expect(out.values.map { |v| v['name'] }.uniq.size).to eq(1)
      expect(out['a.example.com']['expires']).to eq(now.to_i + (24 * 3600))
      expect(out['a.example.com']['name']).to match(%r{\Apes-[0-9a-f]{8}-1760000000\z})
    end

    it 'writes metadata the module can read back' do
      described_class.create(provider, endpoint, { 'tag' => 'run1', 'vms' => vms }, now)
      meta = PeSnapshot.decode_meta(provider.snaps['100'].first['description'])
      expect(meta).to include('certname' => 'a.example.com', 'tag' => 'run1', 'created' => now.to_i)
    end

    it 'reports a VM it cannot resolve without failing the others' do
      out = described_class.create(provider, endpoint, { 'tag' => 't', 'vms' => vms + [{ 'certname' => 'c', 'vm_id' => '999' }] }, now)['results']
      expect(out['c']['_error']['kind']).to eq('pe_snapshot/vm_not_found')
      expect(out['a.example.com']).not_to have_key('_error')
    end

    it 'refuses retention over the proxy maximum' do
      expect { described_class.create(provider, endpoint, { 'tag' => 't', 'vms' => vms, 'retention_hours' => 169 }, now) }
        .to raise_error(PeSnapshot::Error, %r{maximum of 168})
    end

    it 'refuses no expiry unless the proxy allows it' do
      expect { described_class.retention(0, endpoint) }.to raise_error(PeSnapshot::Error, %r{not allowed})
      expect(described_class.retention(0, endpoint.merge('allow_no_expiry' => true))).to eq(0)
    end

    it 'needs a tag' do
      expect { described_class.create(provider, endpoint, { 'vms' => vms }, now) }.to raise_error(PeSnapshot::Error, %r{tag is required})
    end
  end

  describe 'delete' do
    before(:each) do
      provider.snaps['100'] << managed_snap('pes-aaaaaaaa-1', 'run1', 1, 2)
      provider.snaps['100'] << managed_snap('pes-bbbbbbbb-1', 'run2', 1, 2)
      provider.snaps['100'] << { 'name' => 'pes-handmade', 'description' => 'made by hand', 'created' => 1 }
      provider.snaps['100'] << { 'name' => 'before-upgrade', 'description' => '', 'created' => 1 }
    end

    it 'deletes only managed snapshots with the tag' do
      out = described_class.delete(provider, endpoint, { 'tag' => 'run1', 'vms' => vms.take(1) }, now)['results']
      expect(out['a.example.com']['deleted']).to eq(['pes-aaaaaaaa-1'])
      expect(provider.snaps['100'].map { |s| s['name'] }).to eq(['pes-bbbbbbbb-1', 'pes-handmade', 'before-upgrade'])
    end

    it 'succeeds when there is nothing to delete' do
      out = described_class.delete(provider, endpoint, { 'tag' => 'gone', 'vms' => vms.take(1) }, now)['results']
      expect(out['a.example.com']['deleted']).to eq([])
    end
  end

  describe 'restore' do
    it 'refuses an ambiguous tag' do
      provider.snaps['100'] << managed_snap('pes-aaaaaaaa-1', 'run1', 1, 0)
      provider.snaps['100'] << managed_snap('pes-aaaaaaaa-2', 'run1', 2, 0)
      out = described_class.restore(provider, endpoint, { 'tag' => 'run1', 'vms' => vms.take(1) }, now)['results']
      expect(out['a.example.com']['_error']['kind']).to eq('pe_snapshot/ambiguous_snapshot')
      expect(provider.calls).to be_empty
    end

    it 'refuses more than one VM' do
      expect { described_class.restore(provider, endpoint, { 'tag' => 'run1', 'vms' => vms }, now) }.to raise_error(PeSnapshot::Error, %r{exactly one})
    end

    it 'rolls back the single match' do
      provider.snaps['100'] << managed_snap('pes-aaaaaaaa-1', 'run1', 1, 0)
      described_class.restore(provider, endpoint, { 'tag' => 'run1', 'vms' => vms.take(1) }, now)
      expect(provider.calls).to eq([[:restore, '100', 'pes-aaaaaaaa-1', true]])
    end
  end

  describe 'list' do
    it 'marks expired snapshots and buckets their age' do
      provider.snaps['100'] << managed_snap('pes-aaaaaaaa-1', 'run1', now.to_i - 7200, now.to_i - 60)
      snap = described_class.list(provider, endpoint, { 'vms' => vms.take(1) }, now)['results']['a.example.com']['snapshots'].first
      expect(snap).to include('state' => 'expired', 'age_bucket' => '1h_24h')
    end
  end
end

describe PeSnapshot do
  it 'ignores descriptions it did not write' do
    expect(described_class.decode_meta('pe_snapshot: not json')).to be_nil
    expect(described_class.decode_meta('pe_snapshot:{"other":1}')).to be_nil
    expect(described_class.decode_meta(nil)).to be_nil
  end

  it 'refuses a provider name that could be a path' do
    expect { described_class.provider_class('../core') }.to raise_error(PeSnapshot::Error, %r{Invalid provider})
  end

  describe 'load_endpoint' do
    let(:dir) { Dir.mktmpdir }

    before(:each) do
      File.write(File.join(dir, 'lab.json'), JSON.generate('name' => 'lab', 'provider' => 'proxmox'))
      File.write(File.join(dir, 'lab.creds.json'), JSON.generate('token_id' => 'x'))
      allow(File).to receive(:stat).and_call_original
    end

    after(:each) { FileUtils.rm_rf(dir) }

    it 'refuses a key from both the file and the caller' do
      allow(File).to receive(:stat).with(%r{creds}).and_return(instance_double(File::Stat, uid: 0, mode: 0o100600))
      expect { described_class.load_endpoint('lab', { 'token_id' => 'y' }, dir) }.to raise_error(PeSnapshot::Error, %r{both})
    end

    it 'merges caller credentials that do not clash' do
      allow(File).to receive(:stat).with(%r{creds}).and_return(instance_double(File::Stat, uid: 0, mode: 0o100600))
      expect(described_class.load_endpoint('lab', { 'token_secret' => 's' }, dir)['credentials']).to eq('token_id' => 'x', 'token_secret' => 's')
    end

    it 'refuses a credentials file others can read' do
      allow(File).to receive(:stat).with(%r{creds}).and_return(instance_double(File::Stat, uid: 0, mode: 0o100644))
      expect { described_class.load_endpoint('lab', nil, dir) }.to raise_error(PeSnapshot::Error, %r{group or others})
    end
  end
end

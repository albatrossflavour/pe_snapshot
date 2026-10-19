# frozen_string_literal: true

require 'spec_helper'
$LOAD_PATH.unshift(File.expand_path('../../../lib', __dir__))
require 'pe_snapshot/actions'

# A provider with VMs and their snapshots held in memory.
class FakeFactProvider
  def initialize(snapshots, fail_with: nil)
    @snapshots = snapshots
    @fail_with = fail_with
  end

  def vms
    raise @fail_with if @fail_with

    @snapshots.keys.map { |id| { 'vm_id' => id } }
  end

  def list(vm)
    @snapshots[vm['vm_id']]
  end
end

describe 'pe_snapshot_proxy fact' do
  let(:now) { Time.now.to_i }

  def snap(name, certname, created, expires, tag = 'chg-1')
    { 'name' => name, 'created' => created,
      'description' => PeSnapshot.encode_meta('pe_snapshot' => 1, 'certname' => certname, 'tag' => tag, 'created' => created, 'expires' => expires) }
  end

  def value(endpoints)
    Facter.clear
    allow(PeSnapshot).to receive(:endpoint_names).and_return(endpoints.keys)
    endpoints.each do |name, provider|
      allow(PeSnapshot).to receive(:load_endpoint).with(name).and_return('name' => name, 'provider' => 'fake')
      allow(PeSnapshot).to receive(:provider_for).with(hash_including('name' => name)).and_return(provider)
    end
    load File.expand_path('../../../lib/facter/pe_snapshot_proxy.rb', __dir__)
    Facter.fact(:pe_snapshot_proxy)&.value
  end

  after(:each) { Facter.clear }

  it 'is absent on a node with no endpoints' do
    expect(value({})).to be_nil
  end

  it 'lists managed snapshots with state, age and the joined fields POBS counts' do
    provider = FakeFactProvider.new({ 'vm-1' => [snap('pes-a', 'web1', now - 7200, now - 60), { 'name' => 'by-hand', 'created' => now, 'description' => 'mine' }],
                                      'vm-2' => [snap('pes-b', 'web2', now - 60, 0)] })
    fact = value('lab' => provider)
    expect(fact['endpoints']).to eq([{ 'name' => 'lab', 'provider' => 'fake', 'status' => 'ok', 'error' => nil, 'count' => 2, 'health' => 'lab:ok' }])
    expect(fact['snapshots'].map { |s| s.slice('name', 'certname', 'vm_id', 'endpoint', 'state', 'age_bucket', 'summary') }).to eq(
      [{ 'name' => 'pes-a', 'certname' => 'web1', 'vm_id' => 'vm-1', 'endpoint' => 'lab', 'state' => 'expired', 'age_bucket' => '1h_24h', 'summary' => 'lab:expired:1h_24h' },
       { 'name' => 'pes-b', 'certname' => 'web2', 'vm_id' => 'vm-2', 'endpoint' => 'lab', 'state' => 'active', 'age_bucket' => 'lt_1h', 'summary' => 'lab:active:lt_1h' }],
    )
    expect(fact['snapshots'].last['detail']).to eq('web2|lab|chg-1|pes-b|active|lt_1h|never')
  end

  it 'takes | out of the free-text parts of detail' do
    fact = value('lab' => FakeFactProvider.new({ 'vm-1' => [snap('pes-a', 'web1', now, now + 3600, 'a|b')] }))
    expect(fact['snapshots'].first['detail']).to start_with('web1|lab|ab|pes-a|active|lt_1h|')
  end

  it 'reports an endpoint that fails and carries on with the others' do
    fact = value('down' => FakeFactProvider.new({}, fail_with: PeSnapshot::Error.new('api_unreachable', 'https://pve: connection refused')),
                 'up' => FakeFactProvider.new({ 'vm-1' => [snap('pes-a', 'web1', now, 0)] }))
    expect(fact['endpoints']).to eq([{ 'name' => 'down', 'provider' => 'fake', 'status' => 'error', 'error' => 'https://pve: connection refused', 'count' => nil, 'health' => 'down:error' },
                                     { 'name' => 'up', 'provider' => 'fake', 'status' => 'ok', 'error' => nil, 'count' => 1, 'health' => 'up:ok' }])
    expect(fact['snapshots'].map { |s| s['endpoint'] }).to eq(['up'])
  end
end

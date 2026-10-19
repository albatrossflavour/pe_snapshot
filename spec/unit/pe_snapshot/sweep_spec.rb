# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require_relative '../../../lib/pe_snapshot/sweep'

# A provider whose snapshots live in memory and whose deletes are recorded.
class FakeSweepProvider
  attr_reader :deleted

  def initialize(snapshots, fail_on: {})
    @snapshots = snapshots
    @fail_on = fail_on
    @deleted = []
  end

  def resolve(vm_id)
    raise @fail_on[vm_id] if @fail_on[vm_id]

    { 'vm_id' => vm_id }
  end

  def list(vm)
    @snapshots.fetch(vm['vm_id'], [])
  end

  def delete(vm, name)
    @deleted << [vm['vm_id'], name]
  end
end

describe PeSnapshot::Sweep do
  let(:now) { Time.utc(2026, 10, 19, 12, 0, 0) }
  let(:out) { StringIO.new }

  def snap(name, expires)
    { 'name' => name, 'created' => now.to_i - 7200,
      'description' => PeSnapshot.encode_meta('pe_snapshot' => 1, 'certname' => 'web1', 'tag' => 't', 'created' => now.to_i - 7200, 'expires' => expires) }
  end

  def sweep(provider, *pairs)
    allow(PeSnapshot).to receive(:load_endpoint).with('lab').and_return('name' => 'lab', 'provider' => 'fake')
    allow(PeSnapshot).to receive(:provider_for).and_return(provider)
    described_class.run(['lab', *pairs], now: now, out: out)
  end

  it 'deletes what is still expired when it gets there' do
    provider = FakeSweepProvider.new({ 'vm-1' => [snap('pes-a', now.to_i - 60)] })
    expect(sweep(provider, 'vm-1=pes-a')).to eq(0)
    expect(provider.deleted).to eq([['vm-1', 'pes-a']])
    expect(out.string).to eq("lab vm-1 pes-a: deleted, expired 2026-10-19 11:59:00 UTC\n")
  end

  it 'leaves alone a snapshot that is no longer expired or never expires, and one already gone' do
    provider = FakeSweepProvider.new({ 'vm-1' => [snap('pes-a', now.to_i + 3600), snap('pes-b', 0)] })
    expect(sweep(provider, 'vm-1=pes-a', 'vm-1=pes-b', 'vm-1=pes-gone')).to eq(0)
    expect(provider.deleted).to be_empty
    expect(out.string.lines.map(&:chomp)).to eq(['lab vm-1 pes-a: not expired, left alone', 'lab vm-1 pes-b: not expired, left alone', 'lab vm-1 pes-gone: already gone'])
  end

  it 'carries on past a failure and exits non-zero' do
    provider = FakeSweepProvider.new({ 'vm-2' => [snap('pes-b', now.to_i - 60)] }, fail_on: { 'vm-1' => PeSnapshot::Error.new('vm_not_found', 'No VM matches') })
    expect(sweep(provider, 'vm-1=pes-a', 'vm-2=pes-b')).to eq(1)
    expect(provider.deleted).to eq([['vm-2', 'pes-b']])
    expect(out.string.lines.first.chomp).to eq('lab vm-1 pes-a: pe_snapshot/vm_not_found: No VM matches')
  end
end

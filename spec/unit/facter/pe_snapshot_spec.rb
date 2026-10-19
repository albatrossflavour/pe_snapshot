# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
$LOAD_PATH.unshift(File.expand_path('../../../lib', __dir__))
require 'pe_snapshot/core'

describe 'pe_snapshot fact' do
  let(:dir) { Dir.mktmpdir }
  let(:now) { Time.now.to_i }
  let(:target) { { 'provider' => 'proxmox', 'proxy' => 'p', 'endpoint' => 'lab', 'vm_id' => 'u1', 'restorable' => true, 'mapped' => true } }

  def write(file, data)
    File.write(File.join(dir, file), data.is_a?(String) ? data : JSON.generate(data))
  end

  def value
    Facter.clear
    stub_const('PeSnapshot::CONFIG_DIR', dir)
    load File.expand_path('../../../lib/facter/pe_snapshot.rb', __dir__)
    Facter.fact(:pe_snapshot).value
  end

  after(:each) do
    FileUtils.remove_entry(dir)
    Facter.clear
  end

  it 'is absent on a node with neither file' do
    expect(value).to be_nil
  end

  it 'reports the mapping and no snapshots' do
    write('target.json', target)
    expect(value).to eq(target.merge('active' => false, 'count' => 0, 'oldest_created' => nil, 'state' => 'none', 'age_bucket' => 'none',
                                     'snapshots' => [], 'coverage' => 'proxmox:mapped'))
  end

  it 'lists live snapshots, drops expired ones, and keeps those that never expire' do
    write('target.json', target)
    write('active.json', [{ 'name' => 'pes-a', 'created' => now - 7200, 'expires' => now + 60 },
                          { 'name' => 'pes-b', 'created' => now - 600, 'expires' => now - 1 },
                          { 'name' => 'pes-c', 'created' => now - 300, 'expires' => 0 }])
    fact = value
    expect(fact['snapshots'].map { |s| s['name'] }).to eq(['pes-a', 'pes-c'])
    expect(fact.slice('active', 'count', 'oldest_created', 'state', 'age_bucket')).to eq('active' => true, 'count' => 2, 'oldest_created' => now - 7200, 'state' => 'active',
                                                                                         'age_bucket' => '1h_24h')
  end

  it 'reports an unmapped node for the POBS coverage count' do
    write('target.json', target.merge('proxy' => nil, 'mapped' => false))
    expect(value['coverage']).to eq('proxmox:unmapped')
  end

  it 'treats a corrupt file as missing' do
    write('target.json', '{not json')
    write('active.json', [{ 'name' => 'pes-a', 'created' => now, 'expires' => now + 60 }])
    expect(value).to include('count' => 1, 'coverage' => 'none:unmapped')
  end
end

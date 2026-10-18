# frozen_string_literal: true

require 'spec_helper'

describe 'pe_snapshot::proxy' do
  let(:dir) { '/etc/puppetlabs/pe_snapshot/endpoints' }
  let(:endpoints) { [{ 'name' => 'lab_pve', 'provider' => 'proxmox', 'url' => 'https://pve:8006', 'options' => { 'task_timeout' => 600 } }] }
  let(:facts) { { 'os' => { 'family' => 'RedHat' } } }

  context 'with plain credentials' do
    let(:params) { { 'endpoints' => endpoints, 'credentials' => { 'lab_pve' => { 'token_id' => 'a', 'token_secret' => 'b' } } } }

    it { is_expected.to compile.with_all_deps }

    it 'writes the endpoint config with options and retention settings merged in' do
      config = JSON.parse(catalogue.resource('File', "#{dir}/lab_pve.json")[:content])
      expect(config).to eq('name' => 'lab_pve', 'provider' => 'proxmox', 'url' => 'https://pve:8006', 'task_timeout' => 600,
                           'default_retention_hours' => 24, 'max_retention_hours' => 168, 'allow_no_expiry' => false)
    end

    it 'writes credentials root-only and Sensitive' do
      is_expected.to contain_file("#{dir}/lab_pve.creds.json").with(mode: '0600', owner: 'root', show_diff: false)
                                                              .with_content(sensitive('{"token_id":"a","token_secret":"b"}'))
    end

    it { is_expected.not_to contain_exec('pe_snapshot sweep lab_pve') }
  end

  context 'when the fact lists expired snapshots' do
    let(:params) { { 'endpoints' => endpoints } }
    let(:facts) do
      super().merge('pe_snapshot_proxy' => { 'snapshots' => [
                      { 'endpoint' => 'lab_pve', 'vm_id' => '101', 'name' => 'pes-0123abcd-1760000000', 'state' => 'expired' },
                      { 'endpoint' => 'lab_pve', 'vm_id' => '102', 'name' => 'pes-0123abcd-1760000000', 'state' => 'active' },
                      { 'endpoint' => 'lab_pve', 'vm_id' => '103; rm -rf /', 'name' => 'pes-0123abcd-1760000000', 'state' => 'expired' },
                    ] })
    end

    it 'deletes exactly the expired ones that look like ours' do
      is_expected.to contain_exec('pe_snapshot sweep lab_pve').with_command(%r{ lab_pve 101=pes-0123abcd-1760000000\z})
    end
  end

  context 'with default retention above the maximum' do
    let(:params) { { 'default_retention_hours' => 200 } }

    it { is_expected.to compile.and_raise_error(%r{over max_retention_hours}) }
  end
end

# rspec-puppet can't render a Deferred as a class parameter, so this declares
# the class from a manifest. It also resolves Deferred values, so a real
# function stands in for a KMS lookup.
describe 'proxy.example.com', type: :host do
  let(:facts) { { 'os' => { 'family' => 'RedHat' } } }
  let(:pre_condition) do
    <<~PP
      class { 'pe_snapshot::proxy':
        endpoints   => [{ 'name' => 'lab_pve', 'provider' => 'proxmox', 'url' => 'https://pve:8006' }],
        credentials => { 'lab_pve' => Deferred('sprintf', ['{"token_id":"%s"}', 'from-kms']) },
      }
    PP
  end

  it 'resolves the lookup, then converts it, into Sensitive content' do
    is_expected.to contain_file('/etc/puppetlabs/pe_snapshot/endpoints/lab_pve.creds.json').with_content(sensitive('{"token_id":"from-kms"}'))
  end
end

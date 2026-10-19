# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/pe_snapshot/providers/gce'

describe PeSnapshot::Providers::Gce do
  subject(:provider) { described_class.new(endpoint, http: http, token_http: token_http) }

  let(:rsa) { OpenSSL::PKey::RSA.new(2048) }
  let(:key) { { 'client_email' => 'pe-snapshot@p.iam.gserviceaccount.com', 'private_key' => rsa.to_pem, 'token_uri' => 'https://oauth2.googleapis.com/token' } }
  let(:endpoint) { { 'name' => 'gce_demo', 'provider' => 'gce', 'project' => 'p', 'credentials' => key } }
  let(:http) { instance_double(PeSnapshot::HTTP) }
  let(:token_http) { instance_double(PeSnapshot::HTTP) }
  let(:base) { 'https://www.googleapis.com/compute/v1' }
  let(:disk) { '/projects/p/zones/z1/disks/web1' }
  let(:instance) { { 'name' => 'web1', 'zone' => "#{base}/projects/p/zones/z1", 'disks' => [{ 'source' => "#{base}#{disk}", 'boot' => true }] } }
  let(:vm) { { 'vm_id' => 'z1/web1', 'zone' => 'z1', 'name' => 'web1', 'disks' => [disk] } }
  let(:done) { { 'status' => 'DONE', 'name' => 'op1', 'selfLink' => "#{base}/projects/p/zones/z1/operations/op1" } }

  before(:each) { stub_const('PeSnapshot::Providers::Gce::POLL_SECONDS', 0) }

  def snapshot(name, part, disk_path = disk)
    { 'name' => part, 'sourceDisk' => "#{base}#{disk_path}", 'description' => 'meta', 'creationTimestamp' => '2026-10-19T01:00:00.000-07:00',
      'labels' => { 'pe_snapshot' => '1', 'pe_snapshot_name' => name } }
  end

  it 'needs a project and a key' do
    expect { described_class.new(endpoint.merge('project' => nil)) }.to raise_error(PeSnapshot::Error, %r{needs a project})
    expect { described_class.new(endpoint.merge('credentials' => {})) }.to raise_error(PeSnapshot::Error, %r{service account key})
  end

  it 'resolves zone/name to the instance and its disks' do
    allow(http).to receive(:get).with('/projects/p/zones/z1/instances/web1').and_return(instance)
    expect(provider.resolve('z1/web1')).to eq(vm)
  end

  it 'reports an instance that does not exist' do
    allow(http).to receive(:get).and_raise(PeSnapshot::Error.new('api_error', 'not found', 'status' => 404))
    expect { provider.resolve('z1/gone') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/vm_not_found') }
  end

  it 'snapshots each disk with a project-unique name and the shared label, and waits' do
    allow(http).to receive(:post).and_return(done.merge('status' => 'RUNNING'))
    allow(http).to receive(:get).with('/projects/p/zones/z1/operations/op1').and_return(done)
    provider.create(vm, 'pes-0123abcd-1792360000', 'meta', quiesce: true)
    expect(http).to have_received(:post).with(
      '/projects/p/zones/z1/disks/web1/createSnapshot?guestFlush=true',
      hash_including('name' => match(%r{\Apes-0123abcd-1792360000-[0-9a-f]{8}\z}), 'labels' => { 'pe_snapshot' => '1', 'pe_snapshot_name' => 'pes-0123abcd-1792360000' }),
    )
  end

  it 'raises when an operation finishes with an error' do
    allow(http).to receive(:post).and_return(done.merge('error' => { 'errors' => [{ 'code' => 'QUOTA_EXCEEDED' }] }))
    expect { provider.create(vm, 'pes-a', 'meta') }.to raise_error(PeSnapshot::Error, %r{QUOTA_EXCEEDED})
  end

  it 'groups disk snapshots into one logical snapshot per VM' do
    allow(http).to receive(:get).with(%r{/global/snapshots\?filter=labels\.pe_snapshot%3D1}).and_return(
      'items' => [snapshot('pes-a', 'pes-a-1'), snapshot('pes-a', 'pes-a-2', '/projects/p/zones/z1/disks/other-vm')],
    )
    expect(provider.list(vm)).to eq([{ 'name' => 'pes-a', 'description' => 'meta', 'created' => Time.parse('2026-10-19T01:00:00.000-07:00').to_i, 'parts' => ['pes-a-1'] }])
  end

  it 'deletes every disk snapshot of the logical one, and a missing one is fine' do
    allow(http).to receive(:get).with(%r{/global/snapshots\?}).and_return('items' => [snapshot('pes-a', 'pes-a-1')])
    allow(http).to receive(:delete).and_raise(PeSnapshot::Error.new('api_error', 'gone', 'status' => 404))
    expect(provider.delete(vm, 'pes-a')).to be(true)
    expect(http).to have_received(:delete).with('/projects/p/global/snapshots/pes-a-1')
  end

  it 'refuses to restore, saying how to do it by hand' do
    expect { provider.restore(vm, 'pes-a') }.to raise_error(PeSnapshot::Error, %r{pe_snapshot_name=pes-a}) { |e| expect(e.kind).to eq('pe_snapshot/restore_unsupported') }
  end

  describe 'the access token' do
    subject(:provider) { described_class.new(endpoint, token_http: token_http) }

    it 'is fetched with a JWT the key signed, and nothing else secret is sent' do
      allow(token_http).to receive(:post_form).and_return('access_token' => 'ya29.x')
      expect(provider.send(:access_token)).to eq('ya29.x')
      expect(token_http).to have_received(:post_form) do |path, form|
        expect(path).to eq('/token')
        expect(form.to_s).not_to include('PRIVATE KEY')
        head, body, sig = form['assertion'].split('.')
        expect(rsa.public_key.verify(OpenSSL::Digest.new('SHA256'), Base64.urlsafe_decode64(sig), "#{head}.#{body}")).to be(true)
        expect(JSON.parse(Base64.urlsafe_decode64(body))).to include('iss' => key['client_email'], 'aud' => key['token_uri'])
      end
    end

    it 'does not describe a key it cannot read' do
      bad = described_class.new(endpoint.merge('credentials' => key.merge('private_key' => 'not a key')), token_http: token_http)
      expect { bad.send(:access_token) }.to raise_error(PeSnapshot::Error, %r{could not be read}) { |e| expect(e.message).not_to include('not a key') }
    end
  end
end

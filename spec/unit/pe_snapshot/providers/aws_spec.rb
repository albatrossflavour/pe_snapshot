# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/pe_snapshot/providers/aws'

# Answers each EC2 action from a table, and records the requests.
class FakeEc2
  Response = Struct.new(:code, :body) do
    def is_a?(klass)
      (klass == Net::HTTPSuccess) ? code == '200' : super
    end
  end

  attr_reader :requests

  def initialize
    @answers = Hash.new { |_, a| raise "no answer for #{a}" }
    @requests = []
  end

  def on(action, *answers)
    @answers[action] = answers
  end

  def sent(action)
    @requests.select { |a, _| a == action }.map(&:last)
  end

  def raw(_klass, _path, body, _type, headers: {})
    params = URI.decode_www_form(body).to_h
    @requests << [params['Action'], params.merge('headers' => headers)]
    answers = @answers[params['Action']]
    code, xml = (answers.size > 1) ? answers.shift : answers.first
    Response.new(code, xml)
  end
end

# Responses are shaped on what moto's EC2 server returned for the same calls.
describe PeSnapshot::Providers::Aws do
  subject(:provider) { described_class.new(endpoint, http: http) }

  let(:creds) { { 'access_key_id' => 'AKIDEXAMPLE', 'secret_access_key' => 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' } }
  let(:endpoint) { { 'name' => 'syd', 'provider' => 'aws', 'region' => 'ap-southeast-2', 'credentials' => creds } }
  let(:http) { FakeEc2.new }
  let(:ns) { 'xmlns="http://ec2.amazonaws.com/doc/2016-11-15/"' }

  def ok(action, inner)
    ['200', "<#{action}Response #{ns}><requestId>r</requestId>#{inner}</#{action}Response>"]
  end

  def error(code, message, status = '400')
    [status, "<Response><Errors><Error><Code>#{code}</Code><Message>#{message}</Message></Error></Errors><RequestID>r</RequestID></Response>"]
  end

  def instance(id, state = 'running', volumes = ['vol-1'])
    maps = volumes.map { |v| "<item><deviceName>/dev/sda1</deviceName><ebs><volumeId>#{v}</volumeId></ebs></item>" }.join
    "<item><instanceId>#{id}</instanceId><instanceState><name>#{state}</name></instanceState><blockDeviceMapping>#{maps}</blockDeviceMapping></item>"
  end

  def reservations(*instances, token: nil)
    ok('DescribeInstances', "<reservationSet><item><instancesSet>#{instances.join}</instancesSet></item></reservationSet>#{token ? "<nextToken>#{token}</nextToken>" : ''}")
  end

  def snapshot(id, name, instance, description = 'meta')
    "<item><snapshotId>#{id}</snapshotId><description>#{description}</description><startTime>2026-10-19T08:00:00.000Z</startTime><tagSet>" \
      "<item><key>pe_snapshot_name</key><value>#{name}</value></item><item><key>pe_snapshot_instance</key><value>#{instance}</value></item></tagSet></item>"
  end

  it 'needs a region and keys' do
    expect { described_class.new(endpoint.merge('region' => nil)) }.to raise_error(PeSnapshot::Error, %r{needs a region})
    expect { described_class.new(endpoint.merge('credentials' => { 'access_key_id' => 'a' })) }.to raise_error(PeSnapshot::Error, %r{needs access_key_id and secret_access_key})
  end

  # The expected signatures came from botocore's SigV4Auth for the same request.
  it 'signs requests as botocore does' do
    at = Time.utc(2026, 10, 19, 8, 13, 55)
    body = 'Action=DescribeInstances&Version=2016-11-15'
    plain = described_class.new(endpoint, http: http, clock: -> { at }).send(:sign, body)
    expect(plain['authorization']).to eq('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261019/ap-southeast-2/ec2/aws4_request, SignedHeaders=content-type;host;x-amz-date, ' \
                                         'Signature=7d51a98faf99b1584917685233423e56cca393e447f35781e9ecddba4c65f2ff')
    session = described_class.new(endpoint.merge('credentials' => creds.merge('session_token' => 'SESSIONTOKEN')), http: http, clock: -> { at }).send(:sign, body)
    expect(session['authorization']).to end_with('SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, Signature=52fe62cf75d780c57579bdc03029e8af10849126ac597a1385846f4099cc3d80')
    expect(session['x-amz-security-token']).to eq('SESSIONTOKEN')
  end

  it 'resolves an instance id to the instance and its volumes' do
    http.on('DescribeInstances', reservations(instance('i-1', 'running', ['vol-1', 'vol-2'])))
    expect(provider.resolve('i-1')).to eq('vm_id' => 'i-1', 'name' => 'i-1', 'volumes' => ['vol-1', 'vol-2'])
  end

  it 'reports an instance that does not exist or is terminated' do
    http.on('DescribeInstances', error('InvalidInstanceID.NotFound', "The instance ID 'i-9' does not exist"))
    expect { provider.resolve('i-9') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/vm_not_found') }
    http.on('DescribeInstances', reservations(instance('i-8', 'terminated')))
    expect { provider.resolve('i-8') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/vm_not_found') }
  end

  it 'reports rejected credentials as auth_failed, with the code' do
    http.on('DescribeInstances', error('AuthFailure', 'AWS was not able to validate the provided access credentials', '401'))
    expect { provider.resolve('i-1') }.to raise_error(PeSnapshot::Error) { |e| expect([e.kind, e.details['code']]).to eq(['pe_snapshot/auth_failed', 'AuthFailure']) }
  end

  it 'lists every instance across pages, leaving out terminated ones' do
    http.on('DescribeInstances', reservations(instance('i-1'), token: 'n1'), reservations(instance('i-2', 'terminated'), instance('i-3')))
    expect(provider.vms.map { |v| v['vm_id'] }).to eq(['i-1', 'i-3'])
    expect(http.sent('DescribeInstances').last['NextToken']).to eq('n1')
  end

  it 'snapshots every volume in one call, tagged so they group back together' do
    http.on('CreateSnapshots', ok('CreateSnapshots', '<snapshotSet><item><snapshotId>snap-1</snapshotId></item></snapshotSet>'))
    provider.create({ 'vm_id' => 'i-1' }, 'pes-a', 'pe_snapshot:{"tag":"x"}')
    sent = http.sent('CreateSnapshots').first
    expect(sent).to include('InstanceSpecification.InstanceId' => 'i-1', 'Description' => 'pe_snapshot:{"tag":"x"}', 'TagSpecification.1.ResourceType' => 'snapshot')
    tags = (1..4).to_h { |i| [sent["TagSpecification.1.Tag.#{i}.Key"], sent["TagSpecification.1.Tag.#{i}.Value"]] }
    expect(tags).to eq('Name' => 'pes-a', 'pe_snapshot' => '1', 'pe_snapshot_name' => 'pes-a', 'pe_snapshot_instance' => 'i-1')
  end

  it 'refuses memory, quiesce and a description EC2 would truncate' do
    expect { provider.create({ 'vm_id' => 'i-1' }, 'pes-a', 'm', quiesce: true) }.to raise_error(PeSnapshot::Error, %r{cannot quiesce})
    expect { provider.create({ 'vm_id' => 'i-1' }, 'pes-a', 'm', memory: true) }.to raise_error(PeSnapshot::Error, %r{no memory state})
    expect { provider.create({ 'vm_id' => 'i-1' }, 'pes-a', 'm' * 256) }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/bad_description') }
  end

  it 'groups volume snapshots into one logical snapshot per instance' do
    http.on('DescribeSnapshots', ok('DescribeSnapshots', "<snapshotSet>#{snapshot('snap-1', 'pes-a', 'i-1')}#{snapshot('snap-2', 'pes-a', 'i-1')}#{snapshot('snap-3', 'pes-a', 'i-2')}</snapshotSet>"))
    expect(provider.list('vm_id' => 'i-1')).to eq([{ 'name' => 'pes-a', 'description' => 'meta', 'created' => 1_792_396_800, 'parts' => ['snap-1', 'snap-2'] }])
    expect(http.sent('DescribeSnapshots').first).to include('Owner.1' => 'self', 'Filter.1.Name' => 'tag:pe_snapshot', 'Filter.1.Value.1' => '1')
  end

  it 'deletes every part, and treats one already gone as done' do
    http.on('DescribeSnapshots', ok('DescribeSnapshots', "<snapshotSet>#{snapshot('snap-1', 'pes-a', 'i-1')}#{snapshot('snap-2', 'pes-a', 'i-1')}</snapshotSet>"))
    http.on('DeleteSnapshot', ok('DeleteSnapshot', '<return>true</return>'), error('InvalidSnapshot.NotFound', 'gone'))
    expect(provider.delete({ 'vm_id' => 'i-1' }, 'pes-a')).to be(true)
    expect(http.sent('DeleteSnapshot').map { |p| p['SnapshotId'] }).to eq(['snap-1', 'snap-2'])
  end

  it 'refuses restore' do
    expect { provider.restore({ 'vm_id' => 'i-1' }, 'pes-a') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/restore_unsupported') }
  end
end

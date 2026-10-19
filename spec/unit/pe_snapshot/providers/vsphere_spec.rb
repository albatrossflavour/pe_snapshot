# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/pe_snapshot/providers/vsphere'

# Answers each SOAP method from a table, and records the requests.
class FakeSoap
  Response = Struct.new(:code, :body, :headers) do
    def is_a?(klass)
      (klass == Net::HTTPSuccess) ? code == '200' : super
    end

    def [](key)
      headers[key]
    end
  end

  attr_reader :requests

  def initialize
    @answers = Hash.new { |_, m| raise "no answer for #{m}" }
    @requests = []
  end

  def on(method, *bodies)
    @answers[method] = bodies
  end

  def sent(method)
    @requests.select { |m, _| m == method }.map { |r| r.drop(1) }
  end

  def raw(_klass, _path, body, _type, headers: {})
    method = body[%r{<soapenv:Body><(\w+)}, 1]
    @requests << [method, body, headers]
    answers = @answers[method]
    answer = (answers.size > 1) ? answers.shift : answers.first
    return Response.new('500', envelope(answer), {}) if answer.include?('Fault>')

    Response.new('200', envelope("<#{method}Response xmlns=\"urn:vim25\">#{answer}</#{method}Response>"), 'set-cookie' => 'vmware_soap_session="abc"; Path=/; HttpOnly')
  end

  def envelope(inner)
    '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' \
      "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><soapenv:Body>#{inner}</soapenv:Body></soapenv:Envelope>"
  end
end

# Responses are shaped on what vcsim (govmomi's vCenter simulator) returned
# for the same calls.
describe PeSnapshot::Providers::Vsphere do
  subject(:provider) { described_class.new(endpoint, http: http) }

  let(:endpoint) { { 'name' => 'vc', 'provider' => 'vsphere', 'url' => 'https://vc', 'credentials' => { 'username' => 'svc', 'password' => 'p&ss' } } }
  let(:http) { FakeSoap.new }
  let(:uuid) { '4229a0b1-c2d3-e4f5-0617-28394a5b6c7d' }

  def fault(type, text)
    "<soapenv:Fault><faultcode>ServerFaultCode</faultcode><faultstring>#{text}</faultstring><detail><#{type}Fault xmlns=\"urn:vim25\" xsi:type=\"#{type}\"/></detail></soapenv:Fault>"
  end

  def props(moref, type, pairs)
    sets = pairs.map { |name, val| "<propSet><name>#{name}</name><val>#{val}</val></propSet>" }.join
    "<returnval><objects><obj type=\"#{type}\">#{moref}</obj>#{sets}</objects></returnval>"
  end

  def tree_xml(*snaps)
    snaps.map { |name, moref, kids|
      "<snapshot type=\"VirtualMachineSnapshot\">#{moref}</snapshot><name>#{name}</name><description>meta #{name}</description>" \
        "<createTime>2026-10-19T18:27:29.314860835+11:00</createTime>#{(kids || []).map { |k| "<childSnapshotList>#{tree_xml(k)}</childSnapshotList>" }.join}"
    }.join
  end

  def info(state, error = nil)
    props('task-1', 'Task', 'info' => "<state>#{state}</state>#{error}")
  end

  before(:each) do
    stub_const('PeSnapshot::Providers::Vsphere::POLL_SECONDS', 0)
    http.on('RetrieveServiceContent', '<returnval><rootFolder type="Folder">group-d1</rootFolder><propertyCollector type="PropertyCollector">propertyCollector</propertyCollector>' \
                                      '<viewManager type="ViewManager">ViewManager</viewManager><searchIndex type="SearchIndex">SearchIndex</searchIndex>' \
                                      '<sessionManager type="SessionManager">SessionManager</sessionManager></returnval>')
    http.on('Login', '<returnval><key>s1</key></returnval>')
  end

  it 'needs a username and password' do
    expect { described_class.new(endpoint.merge('credentials' => { 'username' => 'svc' })) }.to raise_error(PeSnapshot::Error, %r{needs username and password})
  end

  it 'logs in once, escapes the password, and sends the session cookie after' do
    http.on('FindAllByUuid', '<returnval type="VirtualMachine">vm-68</returnval>')
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'name' => 'web1', 'config.uuid' => uuid, 'config.template' => 'false'))
    provider.resolve(uuid)
    expect(http.sent('Login').size).to eq(1)
    expect(http.sent('Login').first.first).to include('<password>p&amp;ss</password>')
    expect(http.sent('FindAllByUuid').first.last).to include('Cookie' => 'vmware_soap_session="abc"', 'SOAPAction' => 'urn:vim25/7.0')
  end

  it 'resolves a BIOS uuid to the VM and leaves templates out' do
    http.on('FindAllByUuid', '<returnval type="VirtualMachine">vm-68</returnval><returnval type="VirtualMachine">vm-90</returnval>')
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'name' => 'web1', 'config.uuid' => uuid, 'config.template' => 'false'),
            props('vm-90', 'VirtualMachine', 'name' => 'web1-template', 'config.uuid' => uuid, 'config.template' => 'true'))
    expect(provider.resolve(uuid)).to eq('vm_id' => 'vm-68', 'moref' => 'vm-68', 'name' => 'web1', 'uuid' => uuid)
  end

  it 'refuses a uuid two VMs share' do
    http.on('FindAllByUuid', '<returnval type="VirtualMachine">vm-68</returnval><returnval type="VirtualMachine">vm-69</returnval>')
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'name' => 'web1', 'config.template' => 'false'),
            props('vm-69', 'VirtualMachine', 'name' => 'web1-clone', 'config.template' => 'false'))
    expect { provider.resolve(uuid) }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/ambiguous_vm') }
  end

  it 'tries the byte-swapped uuid that older virtual hardware shows the guest' do
    http.on('FindAllByUuid', '', '<returnval type="VirtualMachine">vm-68</returnval>')
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'name' => 'web1', 'config.template' => 'false'))
    provider.resolve(uuid)
    expect(http.sent('FindAllByUuid').last.first).to include('<uuid>b1a02942-d3c2-f5e4-0617-28394a5b6c7d</uuid>')
  end

  it 'takes a managed object id, and reports one that does not exist' do
    http.on('RetrievePropertiesEx', fault('ManagedObjectNotFound', 'The object has already been deleted'))
    expect { provider.resolve('vm-99') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/vm_not_found') }
  end

  it 'reports a bad login as auth_failed' do
    http.on('Login', fault('InvalidLogin', 'Login failure'))
    expect { provider.resolve('vm-1') }.to raise_error(PeSnapshot::Error) { |e| expect([e.kind, e.message]).to eq(['pe_snapshot/auth_failed', 'vSphere Login failed: Login failure']) }
  end

  it 'flattens the snapshot tree' do
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'snapshot' => "<rootSnapshotList>#{tree_xml(['pes-a', 'snapshot-1', [['pes-b', 'snapshot-2']]])}</rootSnapshotList>"))
    expect(provider.list('moref' => 'vm-68').map { |s| s['name'] }).to eq(['pes-a', 'pes-b'])
    expect(provider.list('moref' => 'vm-68').first).to eq('name' => 'pes-a', 'description' => 'meta pes-a', 'created' => 1_792_394_849)
  end

  it 'snapshots with memory and quiesce, and waits for the task' do
    http.on('CreateSnapshot_Task', '<returnval type="Task">task-1</returnval>')
    http.on('RetrievePropertiesEx', info('running'), info('success'))
    provider.create({ 'moref' => 'vm-68' }, 'pes-a', 'pe_snapshot:{"tag":"a<b"}', memory: true, quiesce: true)
    expect(http.sent('CreateSnapshot_Task').first.first).to include('<description>pe_snapshot:{"tag":"a&lt;b"}</description><memory>true</memory><quiesce>true</quiesce>')
  end

  it 'raises the task error' do
    http.on('CreateSnapshot_Task', '<returnval type="Task">task-1</returnval>')
    http.on('RetrievePropertiesEx', info('error', '<error><fault xsi:type="ToolsUnavailable"/><localizedMessage>Cannot quiesce</localizedMessage></error>'))
    expect { provider.create({ 'moref' => 'vm-68' }, 'pes-a', 'm', quiesce: true) }.to raise_error(PeSnapshot::Error) { |e|
      expect([e.kind, e.message, e.details['fault']]).to eq(['pe_snapshot/provider_task_failed', 'vSphere task failed: Cannot quiesce', 'ToolsUnavailable'])
    }
  end

  it 'deletes every snapshot with the name, and treats one already gone as done' do
    roots = ['snapshot-1', 'snapshot-2'].map { |m| "<rootSnapshotList>#{tree_xml(['pes-a', m])}</rootSnapshotList>" }.join
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'snapshot' => roots), info('success'))
    http.on('RemoveSnapshot_Task', '<returnval type="Task">task-1</returnval>', fault('ManagedObjectNotFound', 'gone'))
    expect(provider.delete({ 'moref' => 'vm-68' }, 'pes-a')).to be(true)
    expect(http.sent('RemoveSnapshot_Task').map { |b, _| b[%r{snapshot-\d}] }).to eq(['snapshot-1', 'snapshot-2'])
  end

  it 'reverts and powers on a VM the snapshot left off' do
    http.on('RetrievePropertiesEx', props('vm-68', 'VirtualMachine', 'snapshot' => "<rootSnapshotList>#{tree_xml(['pes-a', 'snapshot-1'])}</rootSnapshotList>"),
            info('success'), props('vm-68', 'VirtualMachine', 'runtime.powerState' => 'poweredOff'), info('success'))
    http.on('RevertToSnapshot_Task', '<returnval type="Task">task-1</returnval>')
    http.on('PowerOnVM_Task', '<returnval type="Task">task-1</returnval>')
    provider.restore({ 'moref' => 'vm-68', 'name' => 'web1' }, 'pes-a', start: true)
    expect(http.sent('RevertToSnapshot_Task').first.first).to include('<suppressPowerOn>false</suppressPowerOn>')
    expect(http.sent('PowerOnVM_Task').size).to eq(1)
  end

  it 'lists every VM with its snapshots through a container view, following the paging token' do
    http.on('CreateContainerView', '<returnval type="ContainerView">session[1]view</returnval>')
    http.on('DestroyView', '')
    page1 = '<returnval><token>t1</token><objects><obj type="VirtualMachine">vm-1</obj><propSet><name>name</name><val>a</val></propSet>' \
            "<propSet><name>config.uuid</name><val>#{uuid}</val></propSet><propSet><name>config.template</name><val>false</val></propSet></objects></returnval>"
    http.on('RetrievePropertiesEx', page1)
    http.on('ContinueRetrievePropertiesEx', props('vm-2', 'VirtualMachine', 'name' => 'tpl', 'config.template' => 'true'))
    expect(provider.vms).to eq([{ 'vm_id' => 'vm-1', 'moref' => 'vm-1', 'name' => 'a', 'uuid' => uuid, 'snapshots' => [] }])
    expect(http.sent('ContinueRetrievePropertiesEx').first.first).to include('<token>t1</token>')
  end
end

# frozen_string_literal: true

require 'rexml/document'
require 'time'
require_relative '../core'

module PeSnapshot
  module Providers
    # VMware vSphere, through vCenter's SOAP API (vim25). The REST API has no
    # VM snapshot calls, so this speaks SOAP by hand.
    #
    # endpoint: url (https://vcenter.example.com), verify_tls, ca_file,
    # credentials {username, password}, options api_version (default 7.0).
    # A VM is identified by its BIOS uuid, which is what the guest reports as
    # dmi.product.uuid, or by its managed object id (vm-123).
    #
    # Memory and quiesce map to vSphere's own snapshot options. Quiesce needs
    # VMware Tools in the guest, and the snapshot fails without it.
    class Vsphere
      POLL_SECONDS = 2
      MOREF = %r{\Avm-\d+\z}
      SOAP_ENV = 'http://schemas.xmlsoap.org/soap/envelope/'
      XSI = 'http://www.w3.org/2001/XMLSchema-instance'

      def initialize(endpoint, http: nil)
        @endpoint = endpoint
        @creds = endpoint['credentials'] || {}
        raise Error.new('missing_credentials', "vSphere endpoint '#{endpoint['name']}' needs username and password") unless @creds['username'] && @creds['password']

        @http = http || HTTP.new(endpoint['url'].to_s.chomp('/'), verify_tls: endpoint.fetch('verify_tls', true), ca_file: endpoint['ca_file'])
        @api_version = endpoint.fetch('api_version', '7.0').to_s
        @task_timeout = endpoint.fetch('task_timeout', 900).to_i
        @session = Mutex.new
      end

      # Every VM this account can see, with its snapshot tree, in as few calls
      # as the property collector allows. The proxy fact lists from these.
      def vms
        @vms ||= begin
          view = call('CreateContainerView', 'ViewManager', content['viewManager'],
                      "#{mor('container', 'Folder', content['rootFolder'])}<type>VirtualMachine</type><recursive>true</recursive>").text
          spec = '<propSet><type>VirtualMachine</type><pathSet>name</pathSet><pathSet>config.uuid</pathSet><pathSet>config.template</pathSet><pathSet>snapshot</pathSet></propSet>' \
                 "<objectSet>#{mor('obj', 'ContainerView', view)}<skip>true</skip>" \
                 '<selectSet xsi:type="TraversalSpec"><name>view</name><type>ContainerView</type><path>view</path><skip>false</skip></selectSet></objectSet>'
          objects = retrieve(spec)
          call('DestroyView', 'ContainerView', view)
          objects.reject { |_, p| text(p['config.template']) == 'true' }.map { |moref, p| handle(moref, p).merge('snapshots' => tree(p['snapshot'])) }
        end
      end

      def resolve(vm_id)
        id = vm_id.to_s.downcase
        morefs = if id.match?(MOREF)
                   [id]
                 else
                   found = find_by_uuid(id)
                   found = find_by_uuid(swapped(id)) if found.empty? && swapped(id)
                   found
                 end
        matches = morefs.filter_map do |moref|
          p = properties('VirtualMachine', moref, ['name', 'config.uuid', 'config.template'])
          handle(moref, p) unless text(p['config.template']) == 'true'
        rescue Error => e
          raise unless e.details['fault'] == 'ManagedObjectNotFound'

          nil
        end
        PeSnapshot.one_vm(matches, vm_id, @endpoint['name'])
      end

      def list(vm)
        (vm['snapshots'] || snapshots(vm)).map { |s| s.slice('name', 'description', 'created') }
      end

      def create(vm, name, description, memory: false, quiesce: false)
        wait(call('CreateSnapshot_Task', 'VirtualMachine', vm['moref'],
                  "<name>#{esc(name)}</name><description>#{esc(description)}</description><memory>#{memory}</memory><quiesce>#{quiesce}</quiesce>").text)
      end

      # vSphere doesn't keep names unique, so every snapshot with the name goes.
      def delete(vm, name)
        snapshots(vm).select { |s| s['name'] == name }.each do |s|
          wait(call('RemoveSnapshot_Task', 'VirtualMachineSnapshot', s['moref'], '<removeChildren>false</removeChildren><consolidate>true</consolidate>').text)
        rescue Error => e
          raise unless e.details['fault'] == 'ManagedObjectNotFound'
        end
        true
      end

      def restore(vm, name, start: true)
        found = snapshots(vm).select { |s| s['name'] == name }
        raise Error.new('snapshot_not_found', "No snapshot named #{name} on #{vm['name']}") if found.empty?
        raise Error.new('ambiguous_snapshot', "#{found.size} snapshots named #{name} on #{vm['name']}", 'names' => [name]) if found.size > 1

        wait(call('RevertToSnapshot_Task', 'VirtualMachineSnapshot', found.first['moref'], "<suppressPowerOn>#{!start}</suppressPowerOn>").text)
        # A snapshot without memory reverts to powered off, whatever suppressPowerOn says.
        wait(call('PowerOnVM_Task', 'VirtualMachine', vm['moref']).text) if start && text(properties('VirtualMachine', vm['moref'], ['runtime.powerState'])['runtime.powerState']) != 'poweredOn'
        true
      end

      private

      def handle(moref, props)
        { 'vm_id' => moref, 'moref' => moref, 'name' => text(props['name']), 'uuid' => text(props['config.uuid']).downcase }
      end

      def snapshots(vm)
        tree(properties('VirtualMachine', vm['moref'], ['snapshot'])['snapshot'])
      end

      # The snapshot property is a tree. Flatten it.
      def tree(info)
        return [] unless info

        walk = ->(node) do
          own = { 'name' => text(child(node, 'name')), 'description' => text(child(node, 'description')),
                  'created' => Time.parse(text(child(node, 'createTime'))).to_i, 'moref' => text(child(node, 'snapshot')) }
          [own] + children(node, 'childSnapshotList').flat_map(&walk)
        end
        children(info, 'rootSnapshotList').flat_map(&walk)
      end

      def find_by_uuid(uuid)
        call('FindAllByUuid', 'SearchIndex', content['searchIndex'], "<uuid>#{esc(uuid)}</uuid><vmSearch>true</vmSearch><instanceUuid>false</instanceUuid>",
             all: true).map(&:text)
      end

      # Older virtual hardware reports the first three uuid fields to the guest
      # in the other byte order, so the guest's dmi uuid and vCenter's differ.
      def swapped(uuid)
        parts = uuid.split('-')
        return nil unless parts.size == 5

        (parts[0, 3].map { |p| p.scan(%r{..}).reverse.join } + parts[3, 2]).join('-')
      end

      def wait(task)
        deadline = Time.now + @task_timeout
        loop do
          info = properties('Task', task, ['info'])['info']
          case text(child(info, 'state'))
          when 'success' then return true
          when 'error'
            err = child(info, 'error')
            raise Error.new('provider_task_failed', "vSphere task failed: #{text(child(err, 'localizedMessage'))}", 'task' => task, 'fault' => fault_type(child(err, 'fault')))
          end
          raise Error.new('provider_timeout', "vSphere task still running after #{@task_timeout}s", 'task' => task) if Time.now > deadline

          sleep POLL_SECONDS
        end
      end

      def properties(type, moref, paths)
        spec = "<propSet><type>#{type}</type>#{paths.map { |p| "<pathSet>#{p}</pathSet>" }.join}</propSet><objectSet>#{mor('obj', type, moref)}<skip>false</skip></objectSet>"
        retrieve(spec).fetch(moref, {})
      end

      # moref => {path => value element}, following the collector's paging.
      def retrieve(spec)
        out = {}
        ret = call('RetrievePropertiesEx', 'PropertyCollector', content['propertyCollector'], "<specSet>#{spec}</specSet><options/>")
        while ret
          children(ret, 'objects').each do |o|
            out[text(child(o, 'obj'))] = children(o, 'propSet').to_h { |p| [text(child(p, 'name')), child(p, 'val')] }
          end
          token = text(child(ret, 'token'))
          ret = token.empty? ? nil : call('ContinueRetrievePropertiesEx', 'PropertyCollector', content['propertyCollector'], "<token>#{esc(token)}</token>")
        end
        out
      end

      def content
        @content ||= begin
          doc = REXML::Document.new(soap('RetrieveServiceContent', 'ServiceInstance', 'ServiceInstance').body.to_s)
          children(REXML::XPath.first(doc, "//*[local-name()='returnval']"), nil).to_h { |e| [e.name, e.text] }
        end
      end

      def login
        @session.synchronize do
          return if @cookie

          res = soap('Login', 'SessionManager', content['sessionManager'],
                     "<userName>#{esc(@creds['username'])}</userName><password>#{esc(@creds['password'])}</password>")
          @cookie = res['set-cookie'].to_s.split(';').first
          at_exit { logout }
        end
      end

      def logout
        soap('Logout', 'SessionManager', content['sessionManager'])
      rescue StandardError
        nil
      end

      # The returnval element, or every returnval with all: true.
      def call(method, type, this, body = '', all: false)
        login
        doc = REXML::Document.new(soap(method, type, this, body).body.to_s)
        vals = REXML::XPath.match(doc, "//*[local-name()='#{method}Response']/*[local-name()='returnval']")
        all ? vals : vals.first
      end

      def soap(method, type, this, body = '')
        envelope = %(<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="#{SOAP_ENV}" xmlns:xsi="#{XSI}"><soapenv:Body>) +
                   %(<#{method} xmlns="urn:vim25">#{mor('_this', type, this)}#{body}</#{method}></soapenv:Body></soapenv:Envelope>)
        headers = { 'SOAPAction' => "urn:vim25/#{@api_version}" }
        headers['Cookie'] = @cookie if @cookie
        res = @http.raw(Net::HTTP::Post, '/sdk', envelope, 'text/xml; charset=utf-8', headers: headers)
        fault = REXML::XPath.first(REXML::Document.new(res.body.to_s), "//*[local-name()='Fault']") if res.body.to_s.include?('Fault>')
        if fault
          type = fault_type(REXML::XPath.first(fault, "*[local-name()='detail']/*"))
          kind = ['InvalidLogin', 'NotAuthenticated'].include?(type) ? 'auth_failed' : 'api_error'
          raise Error.new(kind, "vSphere #{method} failed: #{text(REXML::XPath.first(fault, "*[local-name()='faultstring']"))}", 'status' => res.code.to_i, 'fault' => type)
        end
        raise Error.new('api_error', "vSphere #{method} returned HTTP #{res.code}", 'status' => res.code.to_i) unless res.is_a?(Net::HTTPSuccess)

        res
      end

      # The fault's type, from xsi:type or the element name (InvalidLoginFault).
      def fault_type(element)
        return nil unless element

        (element.attributes['xsi:type'] || element.attributes['type'] || element.name).to_s.sub(%r{\A.*:}, '').delete_suffix('Fault')
      end

      def mor(tag, type, value)
        %(<#{tag} type="#{type}">#{esc(value)}</#{tag}>)
      end

      def esc(value)
        value.to_s.encode(xml: :text)
      end

      def child(element, name)
        element&.elements&.find { |e| e.name == name }
      end

      def children(element, name)
        element ? element.elements.select { |e| name.nil? || e.name == name } : []
      end

      def text(element)
        element ? element.text.to_s : ''
      end
    end
  end
end

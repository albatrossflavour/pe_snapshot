# frozen_string_literal: true

require_relative '../core'

module PeSnapshot
  module Providers
    # Proxmox VE, through the API with a token.
    #
    # endpoint: url (https://host:8006), verify_tls, ca_file, credentials
    # {token_id, token_secret}. A VM is identified by its vmid or by its SMBIOS
    # uuid, which is what the guest reports as dmi.product.uuid.
    #
    # Proxmox has no quiesce switch: it freezes the filesystem through the guest
    # agent whenever the agent is enabled on the VM.
    class Proxmox
      POLL_SECONDS = 2

      def initialize(endpoint, http: nil)
        @endpoint = endpoint
        creds = endpoint['credentials'] || {}
        raise Error.new('missing_credentials', "Proxmox endpoint '#{endpoint['name']}' needs token_id and token_secret") unless creds['token_id'] && creds['token_secret']

        @http = http || HTTP.new("#{endpoint['url'].to_s.chomp('/')}/api2/json",
                                 headers: { 'Authorization' => "PVEAPIToken=#{creds['token_id']}=#{creds['token_secret']}" },
                                 verify_tls: endpoint.fetch('verify_tls', true), ca_file: endpoint['ca_file'])
        @task_timeout = endpoint.fetch('task_timeout', 900).to_i
        @configs = {}
      end

      # Every VM the token can see, as handles. Templates and containers are
      # left out: neither is a patch target.
      def vms
        @vms ||= @http.get('/cluster/resources?type=vm')['data']
                      .select { |r| r['type'] == 'qemu' && r['template'].to_i.zero? }
                      .map { |r| { 'vm_id' => r['vmid'].to_s, 'node' => r['node'], 'vmid' => r['vmid'].to_i } }
      end

      def resolve(vm_id)
        id = vm_id.to_s.downcase
        found = if id.match?(%r{\A\d+\z})
                  vms.find { |v| v['vmid'] == id.to_i }
                else
                  vms.find { |v| smbios_uuid(v) == id }
                end
        raise Error.new('vm_not_found', "No Proxmox VM matches '#{vm_id}'", 'vm_id' => vm_id) unless found

        found
      end

      def list(vm)
        @http.get("#{vm_path(vm)}/snapshot")['data']
             .reject { |s| s['name'] == 'current' }
             .map { |s| { 'name' => s['name'], 'description' => s['description'].to_s, 'created' => s['snaptime'].to_i } }
      end

      def create(vm, name, description, memory: false, quiesce: false) # rubocop:disable Lint/UnusedMethodArgument
        wait(vm, @http.post("#{vm_path(vm)}/snapshot", 'snapname' => name, 'description' => description, 'vmstate' => memory ? 1 : 0)['data'])
      end

      def delete(vm, name)
        wait(vm, @http.delete("#{vm_path(vm)}/snapshot/#{name}")['data'])
      end

      def restore(vm, name, start: true)
        wait(vm, @http.post("#{vm_path(vm)}/snapshot/#{name}/rollback", 'start' => start ? 1 : 0)['data'])
      end

      private

      def vm_path(vm)
        "/nodes/#{vm['node']}/qemu/#{vm['vmid']}"
      end

      def smbios_uuid(vm)
        @configs[vm['vmid']] ||= @http.get("#{vm_path(vm)}/config")['data']
        @configs[vm['vmid']]['smbios1'].to_s[%r{uuid=([0-9a-fA-F-]+)}, 1].to_s.downcase
      end

      # Snapshot calls return a task id (UPID). The work is done when the task
      # stops, and it succeeded only if its exit status is OK.
      def wait(vm, upid)
        deadline = Time.now + @task_timeout
        path = "/nodes/#{vm['node']}/tasks/#{URI.encode_www_form_component(upid)}/status"
        loop do
          status = @http.get(path)['data']
          if status['status'] == 'stopped'
            return true if status['exitstatus'] == 'OK'

            raise Error.new('provider_task_failed', "Proxmox task failed: #{status['exitstatus']}", 'upid' => upid)
          end
          raise Error.new('provider_timeout', "Proxmox task still running after #{@task_timeout}s", 'upid' => upid) if Time.now > deadline

          sleep POLL_SECONDS
        end
      end
    end
  end
end

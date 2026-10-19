# frozen_string_literal: true

require 'base64'
require 'time'
require_relative '../core'

module PeSnapshot
  module Providers
    # Google Compute Engine, through the Compute API with a service account key.
    #
    # endpoint: project, credentials = a Google credentials file as gcloud
    # writes it: a service account's JSON key (client_email, private_key), or
    # an authorized_user file from `gcloud auth application-default login`
    # (client_id, client_secret, refresh_token). Use the service account; the
    # user form acts as that person and their session policy applies to it. A VM is identified as
    # "<zone>/<instance name>", which the pe_snapshot class builds from the
    # gce fact.
    #
    # GCE snapshots disks, not VMs. One pe_snapshot snapshot is one disk
    # snapshot per attached disk, all labelled with the same pe_snapshot_name.
    # Disk snapshot names are global to the project, so each gets the logical
    # name plus a hash of instance and disk. There is no memory state, and
    # restore is not supported: it means building disks from the snapshots and
    # swapping them in, which pe_snapshot leaves to a person.
    class Gce
      API = 'https://compute.googleapis.com/compute/v1'
      # How the API spells resources in links it returns.
      LINK_PREFIX = 'https://www.googleapis.com/compute/v1'
      SCOPE = 'https://www.googleapis.com/auth/compute'
      POLL_SECONDS = 3

      def initialize(endpoint, http: nil, token_http: nil)
        @endpoint = endpoint
        @project = endpoint['project'].to_s
        raise Error.new('bad_endpoint', "GCE endpoint '#{endpoint['name']}' needs a project") if @project.empty?

        @key = endpoint['credentials'] || {}
        needed = (@key['type'] == 'authorized_user') ? ['client_id', 'client_secret', 'refresh_token'] : ['client_email', 'private_key']
        missing = needed.reject { |k| @key[k] }
        raise Error.new('missing_credentials', "GCE endpoint '#{endpoint['name']}' credentials lack #{missing.join(', ')}: give a service account key or an authorized_user file") unless missing.empty?

        @token_http = token_http
        @http = http
        @task_timeout = endpoint.fetch('task_timeout', 900).to_i
      end

      # Every instance in the project, as handles. Disks are filled in by
      # resolve, because the sweep only needs names to match snapshots.
      def vms
        @vms ||= http.get("/projects/#{@project}/aggregated/instances?maxResults=500").fetch('items', {}).values.flat_map do |scope|
          Array(scope['instances']).map { |i| handle(i) }
        end
      end

      def resolve(vm_id)
        zone, name = vm_id.to_s.split('/', 2)
        raise Error.new('vm_not_found', "GCE vm_id '#{vm_id}' is not <zone>/<instance>", 'vm_id' => vm_id) if name.to_s.empty?

        instance = begin
          http.get("/projects/#{@project}/zones/#{zone}/instances/#{name}")
        rescue Error => e
          raise unless e.details['status'] == 404

          nil
        end
        PeSnapshot.one_vm(instance ? [handle(instance)] : [], vm_id, @endpoint['name'])
      end

      # Logical snapshots on this instance: disk snapshots grouped by label.
      def list(vm)
        mine = all_snapshots.select { |s| vm['disks'].include?(s['sourceDisk'].to_s.delete_prefix(LINK_PREFIX)) }
        mine.group_by { |s| s.dig('labels', 'pe_snapshot_name') }.map do |name, disks|
          { 'name' => name, 'description' => disks.first['description'].to_s, 'created' => Time.parse(disks.first['creationTimestamp']).to_i, 'parts' => disks.map { |d| d['name'] } }
        end
      end

      def create(vm, name, description, memory: false, quiesce: false) # rubocop:disable Lint/UnusedMethodArgument
        vm['disks'].each do |disk|
          zone, disk_name = disk.split('/').values_at(-3, -1)
          op = http.post("/projects/#{@project}/zones/#{zone}/disks/#{disk_name}/createSnapshot#{quiesce ? '?guestFlush=true' : ''}",
                         'name' => part_name(name, vm, disk), 'description' => description,
                         'labels' => { 'pe_snapshot' => '1', 'pe_snapshot_name' => name })
          wait(op)
        end
        @all_snapshots = nil
        true
      end

      def delete(vm, name)
        list(vm).select { |s| s['name'] == name }.flat_map { |s| s['parts'] }.each do |part|
          wait(http.delete("/projects/#{@project}/global/snapshots/#{part}"))
        rescue Error => e
          raise unless e.details['status'] == 404
        end
        @all_snapshots = nil
        true
      end

      def restore(_vm, name, start: true) # rubocop:disable Lint/UnusedMethodArgument
        raise Error.new('restore_unsupported',
                        "pe_snapshot does not restore GCE instances. Create disks from the #{name} disk snapshots (label pe_snapshot_name=#{name}), " \
                        'stop the instance, swap the disks and start it.', 'snapshot' => name)
      end

      private

      def handle(instance)
        zone = instance['zone'].to_s.split('/').last
        { 'vm_id' => "#{zone}/#{instance['name']}", 'zone' => zone, 'name' => instance['name'],
          'disks' => Array(instance['disks']).map { |d| d['source'].to_s.delete_prefix(LINK_PREFIX) } }
      end

      # Global to the project, so unique per instance and disk, and inside
      # GCE's 63-character [a-z]([-a-z0-9]*[a-z0-9])? rule.
      def part_name(name, vm, disk)
        "#{name}-#{Digest::SHA256.hexdigest("#{vm['vm_id']}|#{disk}")[0, 8]}"
      end

      # One listing per provider, filtered to snapshots this module labelled.
      def all_snapshots
        @all_snapshots ||= begin
          items = []
          page = nil
          loop do
            query = "filter=#{URI.encode_www_form_component('labels.pe_snapshot=1')}&maxResults=500#{page ? "&pageToken=#{page}" : ''}"
            res = http.get("/projects/#{@project}/global/snapshots?#{query}")
            items.concat(Array(res['items']))
            page = res['nextPageToken']
            break unless page
          end
          items
        end
      end

      def wait(operation)
        deadline = Time.now + @task_timeout
        path = operation['selfLink'].to_s.sub(%r{\Ahttps://(www|compute)\.googleapis\.com/compute/v1}, '')
        loop do
          if operation['status'] == 'DONE'
            raise Error.new('provider_task_failed', "GCE operation failed: #{operation['error'].to_json}", 'operation' => operation['name']) if operation['error']

            return true
          end
          raise Error.new('provider_timeout', "GCE operation still running after #{@task_timeout}s", 'operation' => operation['name']) if Time.now > deadline

          sleep POLL_SECONDS
          operation = http.get(path)
        end
      end

      def http
        @http ||= HTTP.new(API, headers: { 'Authorization' => "Bearer #{access_token}" }, ca_file: @endpoint['ca_file'])
      end

      # A short-lived token. A service account signs a JWT (RFC 7523), so the
      # key never leaves the proxy; an authorized_user file trades its refresh
      # token. Errors name the identity, never the secret.
      def access_token
        uri = URI(@key['token_uri'] || 'https://oauth2.googleapis.com/token')
        form = if @key['type'] == 'authorized_user'
                 { 'grant_type' => 'refresh_token', 'client_id' => @key['client_id'], 'client_secret' => @key['client_secret'], 'refresh_token' => @key['refresh_token'] }
               else
                 { 'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion' => jwt(uri) }
               end
        http = @token_http || HTTP.new("#{uri.scheme}://#{uri.host}", ca_file: @endpoint['ca_file'])
        token = http.post_form(uri.path, form)['access_token']
        raise Error.new('auth_failed', "GCE token endpoint returned no access_token for #{identity}") unless token

        token
      end

      def jwt(uri)
        now = Time.now.to_i
        claims = { 'iss' => @key['client_email'], 'scope' => SCOPE, 'aud' => uri.to_s, 'iat' => now, 'exp' => now + 3600 }
        unsigned = [{ 'alg' => 'RS256', 'typ' => 'JWT' }, claims].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join('.')
        signature = OpenSSL::PKey::RSA.new(@key['private_key']).sign(OpenSSL::Digest.new('SHA256'), unsigned)
        "#{unsigned}.#{Base64.urlsafe_encode64(signature, padding: false)}"
      rescue OpenSSL::PKey::PKeyError
        # The message could describe the key; say only which key.
        raise Error.new('auth_failed', "The private key for #{identity} could not be read")
      end

      def identity
        @key['client_email'] || "authorized_user client #{@key['client_id']}"
      end
    end
  end
end

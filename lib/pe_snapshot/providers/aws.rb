# frozen_string_literal: true

require 'rexml/document'
require 'time'
require_relative '../core'

module PeSnapshot
  module Providers
    # Amazon EC2, through the EC2 Query API with SigV4 signed by hand.
    #
    # endpoint: region (as an option), url (defaults to the region's EC2
    # endpoint), credentials {access_key_id, secret_access_key, session_token}.
    # A VM is identified by its instance id, which the pe_snapshot class takes
    # from the ec2_metadata fact.
    #
    # EBS snapshots volumes, not instances. One pe_snapshot snapshot is a
    # CreateSnapshots call: a crash-consistent snapshot of every attached
    # volume, all tagged with the same pe_snapshot_name. A snapshot is usable
    # from the moment it starts, so create returns then and doesn't wait for
    # the copy to finish. There's no quiesce or memory state, and restore is
    # not supported: it means building volumes from the snapshots and
    # swapping them in, which pe_snapshot leaves to a person.
    class Aws
      API_VERSION = '2016-11-15'
      NOT_FOUND = ['InvalidInstanceID.NotFound', 'InvalidInstanceID.Malformed'].freeze
      AUTH = ['AuthFailure', 'InvalidClientTokenId', 'SignatureDoesNotMatch', 'ExpiredToken', 'RequestExpired'].freeze
      DESCRIPTION_MAX = 255
      CONTENT_TYPE = 'application/x-www-form-urlencoded; charset=utf-8'

      def initialize(endpoint, http: nil, clock: -> { Time.now })
        @endpoint = endpoint
        @region = endpoint['region'].to_s
        raise Error.new('bad_endpoint', "AWS endpoint '#{endpoint['name']}' needs a region") if @region.empty?

        @creds = endpoint['credentials'] || {}
        raise Error.new('missing_credentials', "AWS endpoint '#{endpoint['name']}' needs access_key_id and secret_access_key") unless @creds['access_key_id'] && @creds['secret_access_key']

        url = endpoint['url'] || "https://ec2.#{@region}.amazonaws.com"
        @uri = URI(url)
        @http = http || HTTP.new(url, verify_tls: endpoint.fetch('verify_tls', true), ca_file: endpoint['ca_file'])
        @clock = clock
      end

      # Every instance the credentials can see, except terminated ones.
      def vms
        @vms ||= paged('DescribeInstances', 'MaxResults' => '1000').flat_map do |doc|
          items(doc, 'reservationSet').flat_map { |r| items(r, 'instancesSet') }.filter_map { |i| handle(i) }
        end
      end

      def resolve(vm_id)
        instance = begin
          items(call('DescribeInstances', 'InstanceId.1' => vm_id.to_s), 'reservationSet').flat_map { |r| items(r, 'instancesSet') }.first
        rescue Error => e
          raise unless NOT_FOUND.include?(e.details['code'])

          nil
        end
        found = instance && handle(instance)
        PeSnapshot.one_vm(found ? [found] : [], vm_id, @endpoint['name'])
      end

      # Logical snapshots on this instance: volume snapshots grouped by tag.
      def list(vm)
        mine = all_snapshots.select { |s| s['tags']['pe_snapshot_instance'] == vm['vm_id'] }
        mine.group_by { |s| s['tags']['pe_snapshot_name'] }.map do |name, parts|
          { 'name' => name, 'description' => parts.first['description'], 'created' => parts.map { |p| p['created'] }.min, 'parts' => parts.map { |p| p['id'] } }
        end
      end

      def create(vm, name, description, memory: false, quiesce: false)
        raise Error.new('unsupported_option', 'EBS snapshots have no memory state; take this snapshot with memory false') if memory
        raise Error.new('unsupported_option', 'EBS snapshots cannot quiesce the guest; take this snapshot with quiesce false') if quiesce
        raise Error.new('bad_description', "EC2 snapshot descriptions are limited to #{DESCRIPTION_MAX} characters, and this one is #{description.length}") if description.length > DESCRIPTION_MAX

        tags = { 'Name' => name, 'pe_snapshot' => '1', 'pe_snapshot_name' => name, 'pe_snapshot_instance' => vm['vm_id'] }
        params = { 'InstanceSpecification.InstanceId' => vm['vm_id'], 'InstanceSpecification.ExcludeBootVolume' => 'false', 'Description' => description,
                   'TagSpecification.1.ResourceType' => 'snapshot' }
        tags.each_with_index do |(k, v), i|
          params["TagSpecification.1.Tag.#{i + 1}.Key"] = k
          params["TagSpecification.1.Tag.#{i + 1}.Value"] = v
        end
        call('CreateSnapshots', params)
        @all_snapshots = nil
        true
      end

      def delete(vm, name)
        list(vm).select { |s| s['name'] == name }.flat_map { |s| s['parts'] }.each do |id|
          call('DeleteSnapshot', 'SnapshotId' => id)
        rescue Error => e
          raise unless e.details['code'] == 'InvalidSnapshot.NotFound'
        end
        @all_snapshots = nil
        true
      end

      def restore(_vm, name, start: true) # rubocop:disable Lint/UnusedMethodArgument
        raise Error.new('restore_unsupported',
                        "pe_snapshot does not restore EC2 instances. Create volumes from the #{name} snapshots (tag pe_snapshot_name=#{name}), " \
                        'stop the instance, swap the volumes and start it.', 'snapshot' => name)
      end

      private

      def handle(instance)
        return nil if text(instance, 'instanceState/name') == 'terminated'

        { 'vm_id' => text(instance, 'instanceId'), 'name' => text(instance, 'instanceId'),
          'volumes' => items(instance, 'blockDeviceMapping').map { |b| text(b, 'ebs/volumeId') }.reject(&:empty?) }
      end

      # One listing per provider, of the snapshots this module tagged.
      def all_snapshots
        @all_snapshots ||= paged('DescribeSnapshots', 'Owner.1' => 'self', 'Filter.1.Name' => 'tag:pe_snapshot', 'Filter.1.Value.1' => '1', 'MaxResults' => '1000').flat_map do |doc|
          items(doc, 'snapshotSet').map do |s|
            { 'id' => text(s, 'snapshotId'), 'description' => text(s, 'description'), 'created' => Time.parse(text(s, 'startTime')).to_i,
              'tags' => items(s, 'tagSet').to_h { |t| [text(t, 'key'), text(t, 'value')] } }
          end
        end
      end

      def paged(action, params)
        docs = []
        token = nil
        loop do
          doc = call(action, token ? params.merge('NextToken' => token) : params)
          docs << doc
          token = text(doc, 'nextToken')
          break if token.empty?
        end
        docs
      end

      def call(action, params = {})
        body = URI.encode_www_form({ 'Action' => action, 'Version' => API_VERSION }.merge(params))
        res = @http.raw(Net::HTTP::Post, '/', body, CONTENT_TYPE, headers: sign(body))
        doc = REXML::Document.new(res.body.to_s).root
        return doc if res.is_a?(Net::HTTPSuccess)

        code = text(doc, '//Error/Code')
        kind = AUTH.include?(code) ? 'auth_failed' : 'api_error'
        raise Error.new(kind, "EC2 #{action} returned HTTP #{res.code} #{code}: #{text(doc, '//Error/Message')}", 'status' => res.code.to_i, 'code' => code)
      end

      # AWS Signature Version 4 for a POST to /, with the region's ec2 scope.
      def sign(body, now = @clock.call)
        amz_date = now.utc.strftime('%Y%m%dT%H%M%SZ')
        scope = "#{amz_date[0, 8]}/#{@region}/ec2/aws4_request"
        host = (@uri.port == @uri.default_port) ? @uri.host : "#{@uri.host}:#{@uri.port}"
        headers = { 'content-type' => CONTENT_TYPE, 'host' => host, 'x-amz-date' => amz_date }
        headers['x-amz-security-token'] = @creds['session_token'] if @creds['session_token']
        signed = headers.keys.sort.join(';')
        canonical = ['POST', '/', '', headers.sort.map { |k, v| "#{k}:#{v}\n" }.join, signed, sha256(body)].join("\n")
        to_sign = ['AWS4-HMAC-SHA256', amz_date, scope, sha256(canonical)].join("\n")
        key = ['ec2', 'aws4_request'].inject(hmac(hmac("AWS4#{@creds['secret_access_key']}", amz_date[0, 8]), @region)) { |k, part| hmac(k, part) }
        headers.merge('authorization' => "AWS4-HMAC-SHA256 Credential=#{@creds['access_key_id']}/#{scope}, SignedHeaders=#{signed}, " \
                                         "Signature=#{OpenSSL::HMAC.hexdigest('SHA256', key, to_sign)}")
      end

      def hmac(key, data)
        OpenSSL::HMAC.digest('SHA256', key, data)
      end

      def sha256(data)
        OpenSSL::Digest::SHA256.hexdigest(data)
      end

      # EC2 lists are <name><item>...</item></name>.
      def items(element, name)
        REXML::XPath.match(element, "*[local-name()='#{name}']/*[local-name()='item']")
      end

      # The text at a slash-separated path of local names, or '' if absent.
      def text(element, path)
        xpath = path.start_with?('//') ? "//*[local-name()='#{path[2..].split('/').join("']/*[local-name()='")}']" : path.split('/').map { |p| "*[local-name()='#{p}']" }.join('/')
        REXML::XPath.first(element, xpath)&.text.to_s
      end
    end
  end
end

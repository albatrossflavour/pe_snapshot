# frozen_string_literal: true

require_relative 'core'

module PeSnapshot
  # The operations behind the tasks and the sweep. Each one takes the task's
  # input hash and returns { 'results' => { certname => value } }, where a
  # failed node's value is { '_error' => {...} } and the rest carry on.
  module Actions
    module_function

    def call(action, params, now: Time.now)
      raise Error.new('bad_action', "Unknown action '#{action}'") unless ['create', 'delete', 'list', 'restore'].include?(action)

      endpoint = PeSnapshot.load_endpoint(params['endpoint'], params['credentials'])
      raise Error.new('provider_mismatch', "Endpoint '#{endpoint['name']}' is #{endpoint['provider']}, not #{params['provider']}") if params['provider'] && params['provider'] != endpoint['provider']

      provider = PeSnapshot.provider_for(endpoint)
      send(action, provider, endpoint, params, now)
    end

    def create(provider, endpoint, params, now)
      tag = required(params, 'tag')
      hours = retention(params['retention_hours'], endpoint)
      name = PeSnapshot.snapshot_name(tag, now)
      expires = hours.zero? ? 0 : now.to_i + (hours * 3600)
      per_vm(provider, params) do |vm, certname|
        meta = { 'pe_snapshot' => 1, 'certname' => certname, 'tag' => tag, 'created' => now.to_i, 'expires' => expires, 'by' => params['by'] || 'pe_snapshot' }
        provider.create(vm, name, PeSnapshot.encode_meta(meta), memory: params['memory'] == true, quiesce: params['quiesce'] == true)
        { 'name' => name, 'tag' => tag, 'created' => now.to_i, 'expires' => expires }
      end
    end

    # Deleting something already gone is a success, so a retry is safe.
    def delete(provider, _endpoint, params, now)
      raise Error.new('missing_parameter', 'delete needs a tag or a name') unless params['tag'] || params['name']

      per_vm(provider, params) do |vm, _certname|
        doomed = select(managed(provider, vm, now), params)
        doomed.each { |s| provider.delete(vm, s['name']) }
        { 'deleted' => doomed.map { |s| s['name'] } }
      end
    end

    def list(provider, _endpoint, params, now)
      per_vm(provider, params) { |vm, _certname| { 'snapshots' => select(managed(provider, vm, now), params) } }
    end

    def restore(provider, _endpoint, params, now)
      required(params, 'tag')
      raise Error.new('too_many_targets', 'restore takes exactly one VM') unless Array(params['vms']).size == 1

      per_vm(provider, params) do |vm, _certname|
        matches = select(managed(provider, vm, now), params)
        raise Error.new('snapshot_not_found', "No managed snapshot matches tag '#{params['tag']}'") if matches.empty?
        raise Error.new('ambiguous_snapshot', "#{matches.size} snapshots match tag '#{params['tag']}', pass a name", 'names' => matches.map { |s| s['name'] }) if matches.size > 1

        provider.restore(vm, matches.first['name'], start: params.fetch('start', true))
        { 'name' => matches.first['name'], 'tag' => params['tag'] }
      end
    end

    # Snapshots this module created on one VM, with their metadata decoded.
    def managed(provider, vm, now)
      provider.list(vm).filter_map do |s|
        meta = PeSnapshot.decode_meta(s['description'])
        next unless PeSnapshot.managed?(s['name'], meta)

        created = (meta['created'] || s['created']).to_i
        { 'name' => s['name'], 'tag' => meta['tag'], 'certname' => meta['certname'], 'created' => created, 'expires' => meta['expires'].to_i,
          'state' => PeSnapshot.state(meta, now), 'age_bucket' => PeSnapshot.age_bucket(now.to_i - created) }
      end
    end

    def select(snapshots, params)
      snapshots.select { |s| (params['tag'].nil? || s['tag'] == params['tag']) && (params['name'].nil? || s['name'] == params['name']) }
    end

    # The proxy decides the default and the ceiling, so a direct task call
    # can't get past them.
    def retention(requested, endpoint)
      hours = requested.nil? ? endpoint.fetch('default_retention_hours', 24).to_i : Integer(requested)
      max = endpoint.fetch('max_retention_hours', 168).to_i
      raise Error.new('bad_retention', 'retention_hours cannot be negative') if hours.negative?
      raise Error.new('bad_retention', 'retention_hours 0 (no expiry) is not allowed on this proxy') if hours.zero? && !endpoint['allow_no_expiry']
      raise Error.new('bad_retention', "retention_hours #{hours} is over this proxy's maximum of #{max}", 'max' => max) if hours > max

      hours
    rescue ArgumentError, TypeError
      raise Error.new('bad_retention', "retention_hours must be an integer, got #{requested.inspect}")
    end

    def required(params, key)
      value = params[key]
      raise Error.new('missing_parameter', "#{key} is required") if value.nil? || value.to_s.empty?

      value
    end

    # VMs are resolved one at a time, because resolving warms the provider's
    # caches, then the work runs concurrently.
    def per_vm(provider, params)
      vms = Array(params['vms'])
      raise Error.new('missing_parameter', 'vms is empty') if vms.empty?

      resolved = vms.map do |v|
        [v['certname'], provider.resolve(v['vm_id'])]
      rescue Error => e
        [v['certname'], e]
      end
      values = PeSnapshot.each_concurrently(resolved, params.fetch('concurrency', 5)) do |certname, vm|
        next { '_error' => vm.to_h } if vm.is_a?(Error)

        begin
          yield(vm, certname)
        rescue Error => e
          { '_error' => e.to_h }
        rescue StandardError => e
          { '_error' => Error.new('unexpected', "#{e.class}: #{e.message}").to_h }
        end
      end
      { 'results' => resolved.map(&:first).zip(values).to_h }
    end
  end
end

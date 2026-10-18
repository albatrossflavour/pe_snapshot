# frozen_string_literal: true

require_relative 'actions'

module PeSnapshot
  # Deletes expired snapshots that the proxy fact listed. Each one is checked
  # again before it goes, because the fact was gathered at the start of the
  # run and someone may have changed things since.
  #
  # Usage: sweep.rb <endpoint> <vm_id>=<name> ...
  module Sweep
    module_function

    def run(args, now: Time.now, out: $stdout)
      endpoint_name, *pairs = args
      provider = PeSnapshot.provider_for(PeSnapshot.load_endpoint(endpoint_name))
      failures = pairs.count do |pair|
        vm_id, name = pair.split('=', 2)
        vm = provider.resolve(vm_id)
        snap = Actions.managed(provider, vm, now).find { |s| s['name'] == name }
        if snap.nil?
          out.puts "#{endpoint_name} #{vm_id} #{name}: already gone"
        elsif snap['state'] != 'expired'
          out.puts "#{endpoint_name} #{vm_id} #{name}: not expired, left alone"
        else
          provider.delete(vm, name)
          out.puts "#{endpoint_name} #{vm_id} #{name}: deleted, expired #{Time.at(snap['expires']).utc}"
        end
        false
      rescue Error => e
        out.puts "#{endpoint_name} #{vm_id} #{name}: #{e.kind}: #{e.message}"
        true
      end
      failures.zero? ? 0 : 1
    end
  end
end

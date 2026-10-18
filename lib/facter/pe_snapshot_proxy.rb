# frozen_string_literal: true

# On a proxy, every managed snapshot on every endpoint it holds. This is the
# authoritative list, and the sweep acts on its expired entries. An endpoint
# that can't be reached is reported here, not raised, so the agent run goes on.
Facter.add(:pe_snapshot_proxy) do
  confine do
    require 'pe_snapshot/actions'
    !PeSnapshot.endpoint_names.empty?
  end

  setcode do
    require 'timeout'
    now = Time.now
    endpoints = []
    snapshots = []
    PeSnapshot.endpoint_names.each do |name|
      provider_name = nil
      begin
        endpoint = PeSnapshot.load_endpoint(name)
        provider_name = endpoint['provider']
        provider = PeSnapshot.provider_for(endpoint)
        found = Timeout.timeout(endpoint.fetch('fact_timeout', 120).to_i) do
          PeSnapshot.each_concurrently(provider.vms, 8) { |vm|
            PeSnapshot::Actions.managed(provider, vm, now).map { |s| s.merge('endpoint' => name, 'vm_id' => vm['vm_id']) }
          }.flatten
        end
        snapshots.concat(found)
        endpoints << { 'name' => name, 'provider' => provider_name, 'status' => 'ok', 'error' => nil, 'count' => found.size }
      rescue StandardError => e # Timeout::Error included
        endpoints << { 'name' => name, 'provider' => provider_name, 'status' => 'error', 'error' => e.message.to_s[0, 300], 'count' => nil }
      end
    end
    { 'endpoints' => endpoints, 'snapshots' => snapshots }
  end
end

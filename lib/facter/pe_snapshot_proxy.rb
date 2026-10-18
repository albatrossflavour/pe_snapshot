# frozen_string_literal: true

# On a proxy, every managed snapshot on every endpoint it holds. This is the
# authoritative list, and the sweep acts on its expired entries. An endpoint
# that can't be reached is reported here, not raised, so the agent run goes on.
# One string per snapshot for the pe_snapshot_detail custom metric, which
# can only label a series with whole fields. The Snapshots board splits it on
# |, so | is taken out of the free-text parts.
def detail(snap, endpoint)
  expires = snap['expires'].to_i.zero? ? 'never' : Time.at(snap['expires'].to_i).utc.strftime('%Y-%m-%d %H:%M UTC')
  [snap['certname'], endpoint, snap['tag'], snap['name'], snap['state'], snap['age_bucket'], expires].map { |v| v.to_s.delete('|') }.join('|')
end

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
        # summary and health are colon-joined so the POBS plugin can count
        # them with one count_values each and split them into labels.
        snapshots.concat(found.map { |f| f.merge('summary' => "#{name}:#{f['state']}:#{f['age_bucket']}", 'detail' => detail(f, name)) })
        endpoints << { 'name' => name, 'provider' => provider_name, 'status' => 'ok', 'error' => nil, 'count' => found.size, 'health' => "#{name}:ok" }
      rescue StandardError => e # Timeout::Error included
        endpoints << { 'name' => name, 'provider' => provider_name, 'status' => 'error', 'error' => e.message.to_s[0, 300], 'count' => nil, 'health' => "#{name}:error" }
      end
    end
    { 'endpoints' => endpoints, 'snapshots' => snapshots }
  end
end

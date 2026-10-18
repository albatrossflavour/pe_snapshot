# frozen_string_literal: true

# The node's own view: how it maps to a hypervisor (written by the pe_snapshot
# class) and the snapshots the plans recorded for it (written by the marker
# task). Entries past their expiry are dropped, because the proxy's sweep
# deletes those and never touches this file.
Facter.add(:pe_snapshot) do
  setcode do
    require 'pe_snapshot/core'

    read = ->(file) do
      path = File.join(PeSnapshot::CONFIG_DIR, file)
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    rescue JSON::ParserError
      nil
    end

    target = read.call('target.json')
    now = Time.now.to_i
    live = Array(read.call('active.json')).select { |e| e['expires'].to_i.zero? || e['expires'].to_i > now }
    next nil if target.nil? && live.empty?

    oldest = live.map { |e| e['created'].to_i }.min
    (target || {}).merge(
      'active' => !live.empty?,
      'count' => live.size,
      'oldest_created' => oldest,
      'state' => live.empty? ? 'none' : 'active',
      'age_bucket' => oldest ? PeSnapshot.age_bucket(now - oldest) : 'none',
      'snapshots' => live,
      # For the POBS plugin: provider and whether the plans can reach this node.
      'coverage' => "#{(target || {})['provider'] || 'none'}:#{(target || {})['mapped'] ? 'mapped' : 'unmapped'}",
    )
  end
end

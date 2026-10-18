# @summary Ships pe_snapshot's collector, board and alert rules as a Puppet Observability plugin.
#
# Declare on the PE primary that runs Puppet Observability, where
# observability::enable_collector_plugins is true. The collector counts the
# pe_snapshot facts in PuppetDB, and the board and rules reach the dashboard
# node on its next run. Makes no change to Puppet Observability itself.
#
# The plugin can only count, so the board's per-node tables come from two
# Puppet Observability custom metrics instead, one series per snapshot and one
# per unmapped node. Each is capped at 1,000 rows by Puppet Observability.
# They need observability::enable_custom_metrics on the primary.
#
# @param ensure absent removes the collector, board, rules and custom metrics.
# @param node_tables Declare the custom metrics behind the per-node tables.
class pe_snapshot::pobs (
  Enum['present', 'absent'] $ensure = 'present',
  Boolean $node_tables = true,
) {
  observability::plugin { 'pe_snapshot':
    ensure => $ensure,
    source => 'pe_snapshot/pobs',
  }

  $tables = $ensure ? {
    'present' => $node_tables,
    default   => false,
  }
  pobs_custom_metric { 'pe_snapshot_detail':
    ensure     => $tables.bool2str('present', 'absent'),
    pql        => 'fact_contents[value] { path ~> ["pe_snapshot_proxy", "snapshots", ".*", "detail"] and nodes { deactivated is null and expired is null } }',
    help       => 'One series per managed snapshot, labelled node|endpoint|tag|name|state|age_bucket|expires',
    value_mode => 'info',
    labels     => ['value'],
  }
  pobs_custom_metric { 'pe_snapshot_unmapped':
    ensure     => $tables.bool2str('present', 'absent'),
    pql        => 'fact_contents[certname, value] { path = ["pe_snapshot", "coverage"] and value ~ ":unmapped$" and nodes { deactivated is null and expired is null } }',
    help       => 'One series per node with the pe_snapshot class that the plans cannot reach, labelled with its provider',
    value_mode => 'info',
    labels     => ['certname', 'value'],
  }
}

# @summary Ships pe_snapshot's collector, board and alert rules as a Puppet Observability plugin.
#
# Declare on the PE primary that runs Puppet Observability, where
# observability::enable_collector_plugins is true. The collector counts the
# pe_snapshot facts in PuppetDB, and the board and rules reach the dashboard
# node on its next run. Makes no change to Puppet Observability itself.
#
# @param ensure absent removes the collector, board and rules.
class pe_snapshot::pobs (
  Enum['present', 'absent'] $ensure = 'present',
) {
  observability::plugin { 'pe_snapshot':
    ensure => $ensure,
    source => 'pe_snapshot/pobs',
  }
}

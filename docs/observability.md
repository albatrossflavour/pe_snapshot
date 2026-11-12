# Puppet Observability

`pe_snapshot::pobs` ships a Puppet Observability collector plugin, with a board and alert rules. Declare it on the primary, where `observability::enable_collector_plugins` is true:

```puppet
include pe_snapshot::pobs
```

The collector is declarative (`files/pobs/collector.yaml`). Puppet Observability counts the pe_snapshot facts in PuppetDB with its own code, so no pe_snapshot code runs in the daemon, and no family has a series per node:

| Family | Labels | From |
| --- | --- | --- |
| `pe_snapshot_snapshots` | `endpoint`, `state`, `age_bucket` | each proxy's `pe_snapshot_proxy.snapshots` |
| `pe_snapshot_endpoints` | `endpoint`, `status` | each proxy's `pe_snapshot_proxy.endpoints` |
| `pe_snapshot_nodes` | `provider`, `mapping` | every node's `pe_snapshot.coverage` |
| `pe_snapshot_nodes_with_snapshot` | | nodes whose `pe_snapshot.active` is true |

The plugin can only count, so the board's two per-node tables, Snapshots By Node and Unmapped Nodes, come from two Puppet Observability custom metrics that `pe_snapshot::pobs` also declares: `puppet_custom_pe_snapshot_detail` (one series per snapshot) and `puppet_custom_pe_snapshot_unmapped` (one per unmapped node). Each is capped at 1,000 rows by Puppet Observability, and both need `observability::enable_custom_metrics` on the primary. Set `pe_snapshot::pobs::node_tables: false` to leave them out.

The board asks for Puppet Observability's Patch windows annotation layer (`annotations: [patches]`), because snapshots are taken around patch runs and the layer is what explains them. That key arrived with observability R1136: an older Puppet Observability refuses the board, and the rest of the plugin still loads.

The alerts are `PeSnapshotExpiredNotSwept` (warning, 75 minutes, which allows for the fact lagging the sweep by one agent run), `PeSnapshotEndpointUnreachable` (warning, 1 hour) and `PeSnapshotOlderThanAWeek` (info). The Snapshots board is in its own Snapshots folder.

A change to the board or rules takes two agent runs on the primary, then one on the dashboard node. The primary carries them to the dashboard node in its `pobs_plugins` fact, and facts are collected at the start of a run, before that run updates the plugin files. So the first primary run places the new files, the second publishes them, and the dashboard run provisions them.

Check a change to the plugin before shipping it, with Puppet Observability's own checker:

```sh
/opt/puppetlabs/puppet/bin/ruby <observability module>/files/pobs_ctl.rb plugin check files/pobs --name pe_snapshot
```

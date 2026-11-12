# 6. Watch it in Puppet Observability

## Why

A snapshot that nobody deletes costs disk until the sweep removes it, and an endpoint that stops answering means no snapshots at all. The plugin puts both on a Snapshots board and alerts on them.

## Before you start

- Steps 1 to 4 done
- Puppet Observability on the primary and its dashboard node (the node running its Prometheus and Grafana), with `observability::enable_collector_plugins` true, and `observability::enable_custom_metrics` true if you want the per-node tables

## Do it

On the primary:

```puppet
include pe_snapshot::pobs
```

Then run the agent twice on the primary and once on the dashboard node. [Puppet Observability](../observability.md) explains why it takes three runs, and what the plugin counts.

## Done when

The Snapshots board is in Grafana's Snapshots folder, and Prometheus has a series for each endpoint:

```promql
pe_snapshot_endpoints
```

with `status="ok"` on each, such as `pe_snapshot_endpoints{endpoint="lab_pve", status="ok"} 1`.

## If it fails

| You see | Do |
|---|---|
| No board, or an old one | Run the agent again on the primary, then on the dashboard node |
| The board is refused | It needs the Patch windows annotation layer, from observability R1136 or later. The rest of the plugin still loads |
| Empty per-node tables | `observability::enable_custom_metrics` is off on the primary |

[Troubleshooting](../troubleshooting.md#the-board) has more on the board and the alerts.

## Next

To add an endpoint later, do steps 1 and 2 for it, then step 3 for its nodes.

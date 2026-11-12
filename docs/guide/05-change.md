# 5. Snapshot around a change

## Why

A snapshot is most use taken just before a change. A plan that snapshots first, changes only the nodes that have a snapshot, and then deletes the snapshots where the change worked leaves the failures with a way back and nothing behind elsewhere.

## Before you start

- Step 4 done
- A module in your control repo to hold the plan
- Credentials on the proxy from Hiera or the external file, so the plan doesn't have to pass them

## Do it

Write the plan. [Around a change](../plans.md#around-a-change) has a complete one that upgrades a package with the `package` task that ships with PE. The pattern is:

```puppet
$snaps = run_plan('pe_snapshot::create', 'targets' => $targets, 'tag' => $change, 'retention_hours' => 48)
$result = run_task('package', $snaps.ok_set.targets, 'action' => 'upgrade', 'name' => $package, '_catch_errors' => true)
run_plan('pe_snapshot::delete', 'targets' => $result.ok_set.targets, 'tag' => $change)
```

Use a tag that names the change, such as a ticket number, so the snapshots can be found later. Deploy the module, then run the plan from the console or with `puppet plan run`.

## Done when

After the run, on the primary:

```sh
puppet plan run pe_snapshot::list targets=<the nodes>
```

shows no snapshot with the change's tag on the nodes the change worked on, and one with `"state": "active"` on each node where it failed, until it expires.

## If it fails

| You see | Do |
|---|---|
| Nodes left out of the change | Their snapshot failed. The create result has the error kind. See [Errors by kind](../troubleshooting.md#errors-by-kind) |
| `missing_parameter` | The plan passed no `tag` to create or delete |
| `missing_credentials` | The proxy has no credentials of its own for that endpoint. Put them in Hiera or the external file |
| A node to roll back | `puppet plan run pe_snapshot::restore targets=<node> tag=<change>`. See [Plans](../plans.md#plans) |

## Next

[Watch it in Puppet Observability](06-observability.md), or nothing more.

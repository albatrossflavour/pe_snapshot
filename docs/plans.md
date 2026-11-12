# Plans and facts

## Plans

```sh
puppet plan run pe_snapshot::create targets=web1.example.com,web2.example.com tag=change-1234 retention_hours=48
puppet plan run pe_snapshot::list targets=web1.example.com
puppet plan run pe_snapshot::delete targets=web1.example.com,web2.example.com tag=change-1234
puppet plan run pe_snapshot::restore targets=web1.example.com tag=change-1234
```

| Plan | What it does |
| --- | --- |
| `pe_snapshot::create` | Snapshots each target. The same tag groups a run's snapshots |
| `pe_snapshot::list` | Lists the managed snapshots on each target, from the hypervisor |
| `pe_snapshot::delete` | Deletes by `tag` or `snapshot_name`. Deleting one that's already gone succeeds |
| `pe_snapshot::restore` | Rolls exactly one target back. The tag is required, and if more than one snapshot has it, so is `snapshot_name` |

Every plan returns a ResultSet with one Result per target. A node that failed has an `_error` value, and the rest carry on. A node without a complete mapping fails as `pe_snapshot/unmapped`.

Plans can be called from other plans:

```puppet
$snaps = run_plan('pe_snapshot::create', 'targets' => $nodes, 'tag' => $change, 'retention_hours' => 48)
$patch_these = $snaps.ok_set.targets
```

## Around a change

A plan that snapshots before a change, makes it only on the nodes that have a snapshot, and deletes the snapshots of the nodes where it worked. The ones where it failed keep theirs until they expire, for `pe_snapshot::restore`. This one upgrades a package with the `package` task that ships with PE:

```puppet
plan mysite::upgrade (
  TargetSpec $targets,
  String[1]  $package,
  String[1]  $change,
) {
  # Snapshot first, and only touch the nodes that have one to go back to.
  $snaps = run_plan('pe_snapshot::create', 'targets' => $targets, 'tag' => $change, 'retention_hours' => 48)
  $upgraded = run_task('package', $snaps.ok_set.targets, 'action' => 'upgrade', 'name' => $package, '_catch_errors' => true)

  # Keep the snapshots of anything that failed, for a restore, and delete the rest.
  run_plan('pe_snapshot::delete', 'targets' => $upgraded.ok_set.targets, 'tag' => $change)
  return $upgraded
}
```

```sh
puppet plan run mysite::upgrade targets=web1.example.com,web2.example.com package=openssl change=change-1234
```

## Facts

`pe_snapshot`, on every node with the class:

```json
{
  "provider": "proxmox", "proxy": "puppet.example.com", "endpoint": "lab_pve", "vm_id": "68c3794b-...", "mapped": true,
  "active": true, "count": 1, "oldest_created": 1792359663, "state": "active", "age_bucket": "lt_1h",
  "snapshots": [{"name": "pes-02c2a43e-1792359663", "tag": "change-1234", "created": 1792359663, "expires": 1792532463}]
}
```

The fact first reaches PuppetDB on the second agent run after the class is applied, because facts are collected before the run writes `target.json`. Until then the plans report the node as `pe_snapshot/unmapped`.

The snapshot list comes from a marker file that the plans write on the target. The sweep doesn't update it, so the fact drops entries once they're past expiry.

`pe_snapshot_proxy`, on a proxy: each endpoint's `status`, and every managed snapshot with its `certname`, `vm_id`, `state` (`active` or `expired`) and `age_bucket`. This is the authoritative list.

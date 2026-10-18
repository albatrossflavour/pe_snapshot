# pe_snapshot

Hypervisor and cloud snapshots for Puppet Enterprise plans. Take a snapshot of a set of nodes before risky work, then delete it when you're done or let it expire. Works under the PE orchestrator, and as a step in a `pe_patch::runbook`.

| Provider | Status |
| --- | --- |
| Proxmox VE | Built, tested on a Proxmox 9.2 cluster |
| GCE | Planned |
| vSphere, libvirt, AWS, Azure | Planned |

The design and the reasoning behind it are in [docs/design.md](docs/design.md).

## How it fits together

- Every node that can be snapshotted gets the `pe_snapshot` class. It works out which provider, proxy, endpoint and VM id apply to the node, and publishes them in the `pe_snapshot` fact.
- A proxy node gets `pe_snapshot::proxy`. It holds the API endpoints and their credentials, and it is where the tasks run. It can be the primary, or any node with network access to the hypervisor API.
- The plans look up each target's `pe_snapshot` fact in PuppetDB, group the targets by proxy, and run one task per proxy.
- On every agent run, the `pe_snapshot_proxy` fact lists the managed snapshots on the proxy's endpoints. The proxy class deletes the ones that have expired.

Only snapshots this module created are ever listed, swept or deleted. A managed snapshot is named `pes-<8 hex>-<epoch>` and carries its metadata in its description.

## Setup

Declare the class on every node, and the proxy class on the proxy:

```puppet
include pe_snapshot
```

```puppet
include pe_snapshot::proxy
```

Then tell nodes where their proxy is. This is usually per location or network zone:

```yaml
pe_snapshot::proxy: puppet.example.com
pe_snapshot::endpoint: lab_pve
```

`pe_snapshot::endpoint` can also be a list. Use one where a VM can move between hosts or clusters that have separate APIs: standalone ESXi hosts, libvirt hosts, or more than one vCenter. Each VM is looked up on every endpoint in the list, and it must be found on exactly one. A VM found on two is refused, and so is a VM where one endpoint couldn't be asked, because that endpoint might be the one holding it. Don't list the same cluster twice. A single cluster-level endpoint (vCenter, any node of a Proxmox cluster) already follows vMotion and migrations, because the VM is looked up again on every call.

The provider and VM id are detected from facts. On a `kvm` guest the provider defaults to Proxmox, through `pe_snapshot::virtual_map`. Set `pe_snapshot::provider` where that's wrong, and set `pe_snapshot::vm_id` where detection can't find the VM.

On the proxy, list the endpoints and their credentials:

```yaml
pe_snapshot::proxy::endpoints:
  - name: lab_pve
    provider: proxmox
    url: https://pve1.example.com:8006
pe_snapshot::proxy::credentials:
  lab_pve: >
    ENC[PKCS7,...]
```

A credentials value can be a Hash, a JSON string, or a `Deferred` that returns one of those. A `Deferred` (for example a Vault lookup) resolves on the proxy at run time, so the secret is never in the catalog. The class writes each endpoint's credentials to a root-only file under `/etc/puppetlabs/pe_snapshot/endpoints/`.

### Proxmox

Use an API token with `VM.Audit`, `VM.Snapshot`, `VM.Snapshot.Rollback`, `VM.PowerMgmt` and `Sys.Audit` on `/vms` and `/nodes`:

```sh
pveum role add PESnapshot --privs "VM.Audit,VM.Snapshot,VM.Snapshot.Rollback,VM.PowerMgmt,Sys.Audit"
pveum user add pe_snapshot@pve
pveum acl modify /vms --users pe_snapshot@pve --roles PESnapshot
pveum acl modify /nodes --users pe_snapshot@pve --roles PESnapshot
pveum user token add pe_snapshot@pve pe_snapshot --privsep 0
```

The credentials are `{"token_id": "pe_snapshot@pve!pe_snapshot", "token_secret": "..."}`. The VM is found by matching its SMBIOS UUID (`dmi.product.uuid`) against each VM's `smbios1` setting, or by setting `pe_snapshot::vm_id` to the vmid. Proxmox has no quiesce option. It freezes the guest filesystem through the QEMU guest agent whenever the agent is enabled on the VM.

## Retention

Snapshots expire after 24 hours by default, and a request for more than 168 hours is refused. Both limits are proxy settings:

```yaml
pe_snapshot::proxy::default_retention_hours: 24
pe_snapshot::proxy::max_retention_hours: 168
pe_snapshot::proxy::allow_no_expiry: false
```

The proxy enforces them, so a direct task call can't get round them. Expired snapshots are deleted on the proxy's next agent run.

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

### In a pe_patch runbook

```yaml
- name: snapshot
  run: pe_snapshot::create
  type: plan
  context: true
  params:
    retention_hours: 48
  on_failure: drop
```

With `context: true` the runbook's `run_id` becomes the tag, so a later `pe_snapshot::delete` step with `context: true` removes exactly that run's snapshots. Use `type: plan`: each plan name is also a task name. A runbook is plain data, so it can't pass `credentials`, and the proxy's credentials file has to supply them.

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

## Puppet Observability

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

The alerts are `PeSnapshotExpiredNotSwept` (warning, 75 minutes, which allows for the fact lagging the sweep by one agent run), `PeSnapshotEndpointUnreachable` (warning, 1 hour) and `PeSnapshotOlderThanAWeek` (info). The Snapshots board is in its own Snapshots folder.

Check a change to the plugin before shipping it, with Puppet Observability's own checker:

```sh
/opt/puppetlabs/puppet/bin/ruby <observability module>/files/pobs_ctl.rb plugin check files/pobs --name pe_snapshot
```

## Limits

- A VM id that matches more than one VM is refused with `pe_snapshot/ambiguous_vm`. Clones can keep their source's BIOS UUID (vCenter asks whether to keep it), and guessing could snapshot or restore the wrong machine. Set `pe_snapshot::vm_id` for those nodes.
- The proxy must be Linux.
- `restore` keeps the snapshot. The target's own marker file is rolled back with its disk, so its `pe_snapshot` fact won't list the snapshot afterwards. The proxy's fact still does.
- The plans run their tasks on the proxy, so the user running a plan needs PE permission to run tasks on the proxy as well as on the targets.

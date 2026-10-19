# pe_snapshot

Hypervisor and cloud snapshots for Puppet Enterprise plans. Take a snapshot of a set of nodes before risky work, then delete it when you're done or let it expire. Works under the PE orchestrator, and as a step in a `pe_patch::runbook`.

| Provider | Status |
| --- | --- |
| Proxmox VE | Built, tested on a Proxmox 9.2 cluster |
| GCE | Built, tested on the lab's GCE instances. No restore |
| vSphere, libvirt, AWS, Azure | Planned |

| Document | Covers |
| --- | --- |
| [docs/design.md](docs/design.md) | The design and the reasoning behind it |
| [docs/operations.md](docs/operations.md) | Retention, endpoints, rotating credentials, moving the proxy, upgrading and uninstalling |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Every error kind, unmapped nodes, the sweep, the board and the alerts |
| [CONTRIBUTING.md](CONTRIBUTING.md) | The dev loop, lab validation and adding a provider |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability. The security model is in [Secrets](#secrets) |

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

If something other than Puppet manages the secret, such as Vault Agent or CyberArk, have it write `/etc/puppetlabs/pe_snapshot/credentials.d/<endpoint>.json`, root-owned and `0600`. Puppet creates that directory and never touches its contents. The tasks read both files, and the plans' `credentials` parameter, for every call. A key supplied by more than one of them is an error.

`verify_tls` defaults to true. Setting it to false sends the token to whatever answers at that address, so use `ca_file` for an internal CA instead and keep `verify_tls: false` for a lab you are happy to have intercepted.

### Proxmox

Use a privilege-separated API token, granted on the VMs it may snapshot and nothing else:

```sh
pveum role add PESnapshot --privs "VM.Audit,VM.Snapshot,VM.Snapshot.Rollback,VM.PowerMgmt"
pveum user add pe_snapshot@pve
pveum user token add pe_snapshot@pve pe_snapshot --privsep 1
for id in <vmid> ...; do
  pveum acl modify /vms/$id --users pe_snapshot@pve --tokens 'pe_snapshot@pve!pe_snapshot' --roles PESnapshot
done
```

`VM.PowerMgmt` is only for starting a VM after a restore. Nothing needs `Sys.Audit` or an ACL on `/nodes`, because a token can read the status of its own tasks. Granting per VM (or per pool, if your pools separate patchable VMs from infrastructure) keeps the PE primary, compilers and anything else you would never roll back out of the token's sight: a VM it can't see fails as `pe_snapshot/vm_not_found`. A new VM needs its ACL before it can be snapshotted.

The credentials are `{"token_id": "pe_snapshot@pve!pe_snapshot", "token_secret": "..."}`. The VM is found by matching its SMBIOS UUID (`dmi.product.uuid`) against each VM's `smbios1` setting, or by setting `pe_snapshot::vm_id` to the vmid. Proxmox has no quiesce option. It freezes the guest filesystem through the QEMU guest agent whenever the agent is enabled on the VM.

### GCE

A service account with a custom role holding only what pe_snapshot calls:

```sh
P=<project>
gcloud iam roles create peSnapshot --project $P --title "pe_snapshot" \
  --permissions compute.instances.get,compute.instances.list,compute.disks.get,compute.disks.createSnapshot,compute.snapshots.create,compute.snapshots.get,compute.snapshots.list,compute.snapshots.delete,compute.snapshots.setLabels,compute.zoneOperations.get,compute.globalOperations.get
gcloud iam service-accounts create pe-snapshot --project $P
gcloud projects add-iam-policy-binding $P --role projects/$P/roles/peSnapshot --member serviceAccount:pe-snapshot@$P.iam.gserviceaccount.com
gcloud iam service-accounts keys create key.json --iam-account pe-snapshot@$P.iam.gserviceaccount.com
```

The endpoint takes the project as an option, and the credentials are the key file's JSON as it comes:

```yaml
pe_snapshot::proxy::endpoints:
  - name: gce_prod
    provider: gce
    options:
      project: my-project
pe_snapshot::proxy::credentials:
  gce_prod: ENC[PKCS7,...]
```

The credentials can also be an `authorized_user` file from `gcloud auth application-default login`, which makes the proxy act as that person. That's for trying the provider before a service account is set up: the snapshots are logged as the person, the refresh token carries everything they can do, and an org's session policy can expire it. Swap it for a service account key by changing the Hiera value.

The proxy signs a JWT with the key and exchanges it for an hour-long token, so the key itself never leaves the proxy. It is still a long-lived credential: keep it out of any repository, rotate it with `gcloud iam service-accounts keys`, and prefer the external credentials file if a secrets agent can write it.

A node is identified as `<zone>/<instance>` from its `gce` fact, which works when the instance name differs from the certname. GCE snapshots disks, not VMs, so one pe_snapshot snapshot is one disk snapshot per attached disk, all labelled `pe_snapshot_name=<name>`. `quiesce: true` asks the guest to flush (`guestFlush`), and there is no memory state. Restore is refused with `pe_snapshot/restore_unsupported`: create disks from the labelled snapshots, stop the instance, swap the disks and start it.

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

The plugin can only count, so the board's two per-node tables, Snapshots By Node and Unmapped Nodes, come from two Puppet Observability custom metrics that `pe_snapshot::pobs` also declares: `puppet_custom_pe_snapshot_detail` (one series per snapshot) and `puppet_custom_pe_snapshot_unmapped` (one per unmapped node). Each is capped at 1,000 rows by Puppet Observability, and both need `observability::enable_custom_metrics` on the primary. Set `pe_snapshot::pobs::node_tables: false` to leave them out.

The board asks for Puppet Observability's Patch windows annotation layer (`annotations: [patches]`), because snapshots are taken around patch runs and the layer is what explains them. That key arrived with observability R1136: an older Puppet Observability refuses the board, and the rest of the plugin still loads.

The alerts are `PeSnapshotExpiredNotSwept` (warning, 75 minutes, which allows for the fact lagging the sweep by one agent run), `PeSnapshotEndpointUnreachable` (warning, 1 hour) and `PeSnapshotOlderThanAWeek` (info). The Snapshots board is in its own Snapshots folder.

A change to the board or rules takes two agent runs on the primary, then one on the dashboard node. The primary carries them to the dashboard node in its `pobs_plugins` fact, and facts are collected at the start of a run, before that run updates the plugin files. So the first primary run places the new files, the second publishes them, and the dashboard run provisions them.

Check a change to the plugin before shipping it, with Puppet Observability's own checker:

```sh
/opt/puppetlabs/puppet/bin/ruby <observability module>/files/pobs_ctl.rb plugin check files/pobs --name pe_snapshot
```

## Secrets

pe_snapshot holds no secret machinery of its own. It takes credentials from Hiera (plain, eyaml or `Deferred`), from a root-only file an external agent writes, or from the plans' `credentials` parameter, and the proxy is the trust boundary.

Where a hypervisor credential exists:

| Copy | Notes |
| --- | --- |
| Hiera | eyaml ciphertext, or nothing at all with `Deferred` |
| Compiled catalog and the proxy's cached catalog | The decrypted value, as Sensitive, unless it is `Deferred`. Anyone who can read the proxy's catalog or PuppetDB's catalog store can read it |
| `/etc/puppetlabs/pe_snapshot/endpoints/<endpoint>.creds.json` | root `0600`, `backup => false`. This matters: the clientbucket stores a Sensitive file's old content in plain text on change |
| `/etc/puppetlabs/pe_snapshot/credentials.d/<endpoint>.json` | Only if an external agent writes it |
| Backups and VM snapshots of the proxy | Including snapshots pe_snapshot itself takes, if the proxy is a target |
| PE support bundle | File names only. The bundle lists `/etc/puppetlabs` but doesn't copy this directory |
| Orchestrator job records | Never. `credentials` is typed `Sensitive`, so the orchestrator lists it under `options.sensitive` and stores no value |

The token can only snapshot what its hypervisor ACL lets it see, so scope it to the VMs you patch (see the Proxmox section). An unreadable credentials file is reported in the `pe_snapshot_proxy` fact by name and error class only, never with its content.

PE infrastructure is not restorable by default. `pe_snapshot::restorable` defaults to false on any node with the `pe_server_version` fact, and the restore plan refuses a node whose fact does not say `restorable: true`. Rolling back a primary or compiler revives revoked certificates, old tokens and old Hiera data, and loses everything the CA and PuppetDB recorded since. Set `pe_snapshot::restorable: true` in that node's Hiera to override.

To rotate a credential, update Hiera (or let the external agent rewrite its file) and the next proxy agent run uses it. If one leaks, revoke it on the hypervisor first (`pveum user token remove`, or `gcloud iam service-accounts keys delete`), then issue a new one. [docs/operations.md](docs/operations.md#rotating-a-credential) has the steps. To watch who reads the files:

```sh
auditctl -w /etc/puppetlabs/pe_snapshot/endpoints -p r -k pe_snapshot_creds
auditctl -w /etc/puppetlabs/pe_snapshot/credentials.d -p r -k pe_snapshot_creds
```

## Limits

- A VM id that matches more than one VM is refused with `pe_snapshot/ambiguous_vm`. Clones can keep their source's BIOS UUID (vCenter asks whether to keep it), and guessing could snapshot or restore the wrong machine. Set `pe_snapshot::vm_id` for those nodes.
- The proxy must be Linux.
- `restore` keeps the snapshot. The target's own marker file is rolled back with its disk, so its `pe_snapshot` fact won't list the snapshot afterwards. The proxy's fact still does.
- The plans run their tasks on the proxy, so the user running a plan needs PE permission to run tasks on the proxy as well as on the targets.

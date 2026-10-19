# pe_snapshot design

A Puppet Enterprise module that takes hypervisor and cloud snapshots of managed nodes, deletes them on command or when they expire, restores one on request, and reports what exists through facts and a POBS collector plugin. Agreed with Tony 2026-10-19, with input from the pe_patch session.

## Constraints

- Runs under the PE orchestrator. No Bolt-only plan functions (`parallelize`, `background`, `wait_until_available`, `file::write`, inventory vars, remote transports). Validated on the lab primary, not with Bolt.
- Composable. Each plan is usable on its own and as a step in another plan or a `pe_patch::runbook`, and returns a ResultSet with one Result per target.
- Extensible. A provider is one Ruby file implementing four methods. Adding a hypervisor touches no plan, task or class.
- No POBS changes. Reporting goes through the collector plugin contract (version 2), which is as much a test of that contract as it is a feature.

## Providers

| Provider | Detected from | VM identity | Lab test |
| --- | --- | --- | --- |
| `proxmox` | `virtual = kvm` (default for kvm, overridable) | `dmi.product.uuid` matched to the VM's `smbios1` uuid, or an explicit `vmid` | Yes, the lab VMs |
| `gce` | `virtual = gce` | `gce.instance.name` and zone | Yes, the counterweight nodes |
| `vsphere` | `virtual = vmware` | `dmi.product.uuid` (BIOS uuid search in vCenter) | No lab vCenter, specs only |
| `libvirt` | Hiera only, since kvm means Proxmox here | domain uuid = `dmi.product.uuid` | Specs only unless a libvirt host appears |
| `aws` | `ec2_metadata` present | instance id; snapshots every attached EBS volume | Specs only |
| `azure` | `az_metadata` present | VM resource id; snapshots each managed disk | Specs only |

Cloud providers snapshot disks, not VMs. A "snapshot" there is the set of disk snapshots sharing one name and tag, and restore is out of scope for them in v1 (it means replacing disks, not reverting). The plan says so instead of attempting it.

Every provider uses Ruby stdlib only (`net/http`, `openssl`, `json`). AWS SigV4 and the GCE service-account JWT are signed by hand. libvirt shells out to `virsh -c qemu+ssh://` from the proxy.

## Mapping a node to its snapshot path

The `pe_snapshot` class goes on every node that can be snapshotted. It resolves four values, Hiera first and auto-detection second, so they can be set per node, per location or per network zone:

- `provider`, from Hiera or the `virtual` fact through `pe_snapshot::virtual_map`
- `proxy`, the certname of the node that talks to the hypervisor API for this node
- `endpoint`, the name of a configured endpoint on that proxy (a Proxmox cluster, a vCenter, a GCE project)
- `vm_id`, from Hiera or detected per provider as in the table above

`endpoint` can be a list, for VMs that move between hosts or clusters with separate APIs (standalone ESXi, libvirt, cross-vCenter vMotion). The task looks the VM up on each endpoint and needs exactly one hit. A guest can't reliably see which host it runs on (VMware hides it, Proxmox and KVM don't expose it, only Hyper-V's KVP does), so the lookup happens at call time instead. A cluster-level endpoint follows migrations without a list.

A VM id matching more than one VM, on one endpoint or across a list, is refused. Clones can keep their source's BIOS UUID, and acting on the first match could restore the wrong machine.

The class writes these to `/etc/puppetlabs/pe_snapshot/target.json`, and the `pe_snapshot` fact publishes them. Plans read the fact from PuppetDB with `puppetdb_query` and group targets by proxy and endpoint, so a caller only passes target nodes. A node with no resolvable mapping is reported as unmapped, never silently skipped.

The proxy does not need the node list. Its expiry sweep lists every snapshot named with the module's prefix on the endpoints it holds, and each snapshot carries its own certname and expiry in its metadata.

## Snapshot identity

- Name: `pes-<12 hex>`, derived from tag, certname and time. Short and plain enough for every provider (Proxmox allows 40 characters from `[A-Za-z0-9_-]` starting with a letter).
- Metadata, in the description, labels or tags depending on provider: `{"pe_snapshot":1,"certname":...,"tag":...,"created":epoch,"expires":epoch,"by":...}`.
- Only snapshots whose name starts `pes-` and whose metadata parses are managed. Hand-made snapshots are never listed, swept or deleted.

## Credentials

Endpoints are configured on the proxy with `pe_snapshot::proxy::endpoints`:

```yaml
pe_snapshot::proxy::endpoints:
  - name: lab_pve
    provider: proxmox
    url: https://pve.lab.albatrossflavour.com:8006
    verify_tls: true
    credentials: >
      ENC[PKCS7,...]
```

`credentials` is `Sensitive` or `Deferred`. A `Deferred` (Vault, a cloud KMS, anything with a deferred function) resolves on the proxy at agent run time, so the secret is never in the compiled catalog. The class writes one root-owned `0600` JSON file per endpoint under `/etc/puppetlabs/pe_snapshot/endpoints/`. Tasks check the file's owner and mode before reading it.

A plan can also pass `credentials`, typed exactly `Sensitive[Hash]` with a `Sensitive({})` default. The exact type matters: the orchestrator only wraps JSON input in Sensitive, and only keeps the value out of the plan job record, for a parameter of that exact type. `Optional[Sensitive[Hash]]` was refused from the CLI and still stored in plain text in the job record (lab, plan job 2372, 2026-10-19). The value is unwrapped only at the `run_task` call and sent to a task parameter marked `sensitive`.

An external agent (Vault Agent, CyberArk) can write `credentials.d/<endpoint>.json` instead. Puppet creates that directory and never purges it. The path is fixed, so a caller can't point a task at another file. A key supplied by more than one source is an error, the rule pe_patch is adopting. An unreadable credentials file is reported by name and error class only: a JSON parser error quotes the text around the fault, which can be the secret, and the message reaches PuppetDB through the proxy fact.

PE infrastructure (any node with `pe_server_version`) is not restorable by default, and the restore plan fails closed on a node whose fact doesn't say `restorable: true`. The stronger control is the hypervisor ACL: the token is granted per VM, so infrastructure VMs are invisible to it.

These came out of a secrets review on 2026-10-19 (`pe_patch-private/docs/superpowers/planning/2026-10-19-secrets-review.md`).

## Retention

`retention_hours` defaults to 24 and is refused above 168. Both are Hiera settings on the proxy (`pe_snapshot::proxy::default_retention_hours`, `pe_snapshot::proxy::max_retention_hours`), written into each endpoint's config. The task on the proxy applies them, so the plans don't need Hiera access (PE plans only see `plan_hierarchy`) and a direct task call can't get past the ceiling. Retention `0` means "until deleted", allowed only if `pe_snapshot::proxy::allow_no_expiry` is true (default false).

## Interface

### Tasks (run on the proxy)

All four are generic. They take `provider`, `endpoint`, `vms` (an array of `{certname, vm_id}`), and return one result per certname. Dispatch happens inside the task through `lib/pe_snapshot/providers/<name>.rb`, shipped through task metadata `files`.

| Task | Inputs besides the common ones | Notes |
| --- | --- | --- |
| `pe_snapshot::create` | `tag`, `retention_hours`, `memory` (false), `quiesce` (false), `concurrency` (5) | Waits for each snapshot to finish. Returns name, created, expires |
| `pe_snapshot::delete` | `tag` or `name` (one required) | Deletes only managed snapshots matching it |
| `pe_snapshot::list` | `tag` (optional) | Read only |
| `pe_snapshot::restore` | `name` or `tag` (required), `start` (true) | One VM per call |

Errors follow pe_patch's shape: `{"_error": {"kind": "pe_snapshot/<thing>", "msg": ..., "details": {...}}}` with a non-zero exit. A partial batch succeeds overall and reports a per-certname failure, so a plan can drop the nodes that failed and carry on.

This departs from pe_patch's single-file task convention. Six providers sharing transport, retry and metadata code is a case for multi-file tasks (agent 6.6 or later, which every supported PE agent is).

### Marker task (run on the target)

`pe_snapshot::marker` adds or removes an entry in `/etc/puppetlabs/pe_snapshot/active.json` (Windows: `C:\ProgramData\PuppetLabs\pe_snapshot\active.json`). It's one Ruby file running under the agent's Ruby, so the same task covers Linux and Windows. A marker failure is reported but doesn't fail the snapshot.

### Plans

| Plan | Parameters | Result value per target |
| --- | --- | --- |
| `pe_snapshot::create` | `targets`, `tag` or `pe_patch_context`, `retention_hours`, `memory`, `quiesce`, `credentials` | `{name, expires, pe_patch_report}` |
| `pe_snapshot::delete` | `targets`, `tag` or `pe_patch_context` or `snapshot_name` | `{deleted, pe_patch_report}` |
| `pe_snapshot::list` | `targets`, `tag` | `{snapshots}` |
| `pe_snapshot::restore` | `targets` (exactly one), `tag` (required), `snapshot_name`, `start` | `{name, pe_patch_report}` |

Plans take `snapshot_name` where the tasks take `name`, because `$name` is reserved in the Puppet language.

Every plan returns `ResultSet(targets.map |t| { Result.new(t, value) })`, with exactly one Result per target. A failed node's value is `{'_error' => {kind, msg, details}}`. That is how a `pe_patch::runbook` step judges each node, so its `drop` and `stop` handling sees a failed snapshot. A plain Hash would pass every target. The plans never call `fail_plan` for a per-node failure, because that fails every target. They do call it for bad input such as a retention over the ceiling.

`pe_patch_report` is a small Hash (`{name, expires}`) that pe_patch keeps per node under `reports.<step name>` and carries into its notifications. Other keys in an ok value are dropped by the runbook runner but are still there for a plain plan caller.

Runbook integration rules, from pe_patch's step contract:

- `targets` is `TargetSpec`, because the runner passes an Array of certnames under that name.
- `pe_patch_context` is `Optional[Hash]` and is what a step receives with `context: true` (`run_id`, `runbook`, `batch`, `failed`, `incomplete`, `step`). When `tag` is absent the plans use its `run_id`.
- Each name exists as both a plan and a task. Runbook steps should say `type: plan`.
- A runbook is plain JSON, so a step can't carry a `Sensitive` value. Through a runbook only the credentials file on the proxy works. `credentials` is `Optional` so a step that omits it passes preflight.

```yaml
- name: snapshot
  run: pe_snapshot::create
  type: plan
  context: true
  params:
    retention_hours: 48
  on_failure: drop
```

The plans resolve proxies themselves, so pe_patch doesn't need its planned step-level `via` to call them.

Restore is never meant to be a runbook step. It refuses more than one target and refuses without a tag.

### Sweep (agent run on the proxy)

The `pe_snapshot_proxy` fact lists managed snapshots on every endpoint the proxy holds, with a per-endpoint timeout. When the fact shows expired snapshots, `pe_snapshot::proxy` declares one `exec` that deletes exactly those by name. The run report shows a change only when something was deleted, and an endpoint that can't be reached shows in the fact, not as a failed run.

## Facts

On the target, `pe_snapshot`:

```json
{
  "provider": "proxmox", "proxy": "puppet.lab.albatrossflavour.com", "endpoint": "lab_pve", "vm_id": "...",
  "active": true, "count": 1, "oldest_created": 1760832000, "age_bucket": "1h_24h", "state": "active",
  "snapshots": [{"name": "pes-...", "tag": "...", "created": 1760832000, "expires": 1760918400}]
}
```

On the proxy, `pe_snapshot_proxy`:

```json
{
  "endpoints": [{"name": "lab_pve", "provider": "proxmox", "status": "ok", "error": null}],
  "snapshots": [{"certname": "...", "vm_id": "...", "name": "pes-...", "tag": "...",
                 "created": 1760832000, "expires": 1760918400, "state": "active", "age_bucket": "1h_24h"}]
}
```

`state` is `active` or `expired` (past expiry and still present). An `orphaned` state, for a snapshot whose node is no longer active, was considered and left out: the proxy can't see which nodes are active without a PuppetDB query from a fact. `age_bucket` is `lt_1h`, `1h_24h`, `1d_7d` or `gt_7d`. These are computed when the fact runs, because the POBS fleet query only does equality counts. Arrays are used in place of name-keyed hashes because fleet query paths can't address keys containing hyphens or dots.

The proxy fact is authoritative. The target marker can go stale when a snapshot is removed outside the module, and its own agent run cross-checks nothing, so treat it as a convenience for per-node queries.

## POBS collector plugin

`pe_snapshot::pobs`, declared on the primary, ships `files/pobs` through `observability::plugin`. It needs `enable_collector_plugins` on, and makes no change to POBS.

The collector is declarative (`collector.yaml`, contract version 2), so POBS counts the facts with its own code and no pe_snapshot code runs in the daemon. The fleet query only does equality counts, so the facts carry colon-joined fields that one `count_values` each splits into labels:

| Family | Labels | Fact field |
| --- | --- | --- |
| `pe_snapshot_snapshots` | `endpoint`, `state`, `age_bucket` | `pe_snapshot_proxy.snapshots.*.summary` |
| `pe_snapshot_endpoints` | `endpoint`, `status` | `pe_snapshot_proxy.endpoints.*.health` |
| `pe_snapshot_nodes` | `provider`, `mapping` | `pe_snapshot.coverage` |
| `pe_snapshot_nodes_with_snapshot` | | `count('pe_snapshot.active' => true)` |

Bounded label sets, no per-node series. Alert rules: `PeSnapshotExpiredNotSwept` (75 minutes, since the proxy fact lags the sweep by one agent run), `PeSnapshotEndpointUnreachable` and `PeSnapshotOlderThanAWeek`. One board, in its own Snapshots folder.

Proven on the lab 2026-10-19: the collector loaded and polled clean, the rules loaded in Prometheus, the board was provisioned, and every panel query returned the lab's real numbers. The board has not been checked visually.

## Build order

1. Skeleton, the `pe_snapshot` class and fact, proxy class with credential files, the provider interface, the Proxmox provider, tasks, plans, sweep. Proven on the lab Proxmox VMs end to end.
2. GCE provider, proven on the counterweight nodes.
3. POBS plugin, boards and rules, proven on the lab dashboard (done 2026-10-19).
4. vSphere, libvirt, AWS and Azure providers, covered by specs against recorded API responses and flagged as not lab-tested until somebody has an endpoint.

## Validation

- rspec-puppet for classes, BoltSpec plan specs, task specs that run the task as a process against a stubbed HTTP server, provider specs per API.
- PDK validate and RuboCop clean, markdownlint clean on every doc.
- Lab: deploy through `puppet-code deploy`, two agent runs on the proxy and a target (second run clean), then each plan run through `puppet plan run` on the primary: create, list, fact shows it, delete, fact clears, create with 1h retention and watch the sweep remove it, restore on a throwaway VM.

## Out of scope for v1

- Restore on cloud providers.
- Backup products as providers (a create that starts and polls a backup job fits the interface, so this is a later provider, not a redesign).
- Pushing events to the POBS events API.

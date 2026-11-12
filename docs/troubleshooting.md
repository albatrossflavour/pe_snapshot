# Troubleshooting

Start with the error's `kind`. Every failure pe_snapshot reports is a `pe_snapshot/<kind>` value on the target's Result, with a message and a `details` hash. The plans keep going for the other targets, so one bad node doesn't hide the rest.

## Where to look

| Question | Where |
| --- | --- |
| How does a node map to a proxy, endpoint and VM? | Its `pe_snapshot` fact: `sudo puppet query 'facts[value] { name = "pe_snapshot" and certname = "<node>" }'` on the primary |
| Which nodes are unmapped? | The Snapshots board's Unmapped Nodes table, or `pe_snapshot.coverage` ending `:unmapped` |
| Can the proxy reach its endpoints? | `sudo puppet facts show pe_snapshot_proxy` on the proxy. Each endpoint has a `status` and, when it's `error`, the reason |
| What snapshots exist? | The same fact's `snapshots`, which comes from the hypervisor. A target's own fact is only its marker file |
| Did the sweep delete anything? | The proxy's agent run output. Each deletion logs `<endpoint> <vm_id> <name>: deleted, expired <time>` |
| What did a task do? | The plan's job in the PE console, then the task job on the proxy under it |

## Errors by kind

| Kind | Cause | Fix |
| --- | --- | --- |
| `unmapped` | The node's `pe_snapshot` fact lacks a provider, proxy, endpoint or VM id | See [A node is unmapped](#a-node-is-unmapped) |
| `missing_parameter` | `create` was given no `tag` and no `pe_patch_context`, or `delete` was given no `tag` or `snapshot_name` | Pass one |
| `too_many_targets` | `restore` was given more than one target | Restore one node at a time |
| `not_restorable` | The node's fact doesn't say `restorable: true`. PE infrastructure defaults to false | Set `pe_snapshot::restorable: true` in that node's Hiera if you mean it. See [Secrets](secrets.md) first |
| `unknown_endpoint` | The node's endpoint isn't configured on its proxy, or the proxy hasn't had an agent run since it was added | Check `pe_snapshot::proxy::endpoints` and the node's `pe_snapshot::endpoint`, then run the agent on the proxy |
| `bad_endpoint` | An endpoint name isn't lower case letters, digits and underscores, a GCE endpoint has no `project`, or an AWS endpoint has no `region` | Fix the Hiera |
| `unknown_provider` | The provider name doesn't match a file under `lib/pe_snapshot/providers/` | Check `pe_snapshot::provider` and `pe_snapshot::virtual_map`. `proxmox`, `gce`, `vsphere` and `aws` exist so far |
| `provider_mismatch` | The node's provider isn't the endpoint's provider | Point the node at the right endpoint, or fix its `pe_snapshot::provider` |
| `missing_credentials` | The merged credentials lack a key the provider needs (Proxmox `token_id` and `token_secret`, GCE `client_email` and `private_key`, or `client_id`, `client_secret`, and `refresh_token` for an `authorized_user` file, vSphere `username` and `password`, AWS `access_key_id` and `secret_access_key`) | Check `pe_snapshot::proxy::credentials` has an entry under the endpoint's name, and that the proxy has run since |
| `credentials_conflict` | A credential key came from more than one source: the Puppet file, the external file and the plan's `credentials` | Supply each key from one place. The message names the second source |
| `insecure_credentials` | An external credentials file isn't owned by root or is readable by group or others | `chown root:root` and `chmod 0600` it |
| `unreadable_credentials` | A credentials file isn't JSON, or isn't a JSON object | Fix whatever wrote it. The error gives the path, never the content |
| `auth_failed` | GCE: the token endpoint returned no token, or the private key couldn't be read. vSphere: vCenter refused the login (`InvalidLogin`), or the session ended mid-task (`NotAuthenticated`) | GCE: check the key file is the JSON as Google issued it. vSphere: check the user and password, and that the account isn't locked. AWS: `details.code` says why (`AuthFailure`, `ExpiredToken`, `SignatureDoesNotMatch`). An expired token needs new STS credentials, and a signature mismatch usually means the proxy's clock is wrong |
| `api_error` | The hypervisor API answered with an HTTP error. `details.status` has the code | See [API errors](#api-errors) |
| `api_unreachable` | No HTTP answer: DNS, routing, firewall or TLS | See [API errors](#api-errors) |
| `vm_not_found` | No VM on the endpoint matches the node's VM id | See [A VM can't be found](#a-vm-cant-be-found) |
| `ambiguous_vm` | More than one VM matches, or the VM was found on more than one endpoint in the node's list | Set `pe_snapshot::vm_id` for the node, or narrow its endpoint list |
| `snapshot_not_found` | `restore` found no managed snapshot with that tag on the VM | Check the tag with `pe_snapshot::list`. It may have expired and been swept |
| `ambiguous_snapshot` | More than one snapshot has the tag | Pass `snapshot_name`. `details.names` lists them |
| `bad_retention` | `retention_hours` is negative, over the proxy's maximum, or 0 where `allow_no_expiry` is false | Ask for less, or change the proxy's limits |
| `provider_task_failed` | The hypervisor accepted the request and the job failed | Proxmox: open the task by its `upid` in the Proxmox UI. A common cause is a disk on storage that can't snapshot, such as plain LVM. GCE: the message carries the operation's error. vSphere: `details.fault` has the fault type, such as `ToolsUnavailable` for a quiesce without VMware Tools |
| `provider_timeout` | The hypervisor job was still running after `task_timeout` seconds (default 900) | The job may still finish. Check the hypervisor before retrying, then raise `task_timeout` in the endpoint's `options` if it's normal for that VM |
| `unsupported_option` | `memory` or `quiesce` was asked of a provider that can't do it (AWS) | Take the snapshot without it |
| `bad_description` | The snapshot's metadata is longer than EC2's 255-character description limit, usually from a very long certname or tag | Use a shorter tag |
| `restore_unsupported` | The provider can't restore (GCE, AWS) | Restore by hand: create disks from the labelled snapshots, stop the instance, swap the disks, start it |
| `marker_error` on a successful result | The snapshot was taken, but the marker task on the target failed. The result is still ok | The snapshot exists and the sweep will still expire it. Only the target's own fact will be missing it |
| `no_result` | The proxy's task returned nothing for a target | Look at the task job on the proxy in the console |
| `bad_action` | A direct task call named an action other than create, delete, list or restore | Use one of those |
| `unexpected` | An exception pe_snapshot didn't anticipate | A bug. Raise an issue with the message and the provider |

## A node is unmapped

The `pe_snapshot` fact's `coverage` is `<provider>:unmapped` and the plans refuse it. Look at the fact to see which value is missing:

| Missing | Cause and fix |
|---|---|
| Everything is missing | The class isn't declared, or the node has only had one agent run since it was. Facts are collected before the run writes `target.json`, so the fact first appears on the second run. |
| `proxy` or `endpoint` is missing | Nothing in Hiera sets `pe_snapshot::proxy` or `pe_snapshot::endpoint` for the node. These usually live at the location or network zone level. |
| `provider` is missing | The `virtual` fact isn't in `pe_snapshot::virtual_map`. Facter reports `physical` for some guests (Rocky 9 and 10 images without `virt-what`, Windows on Proxmox), and the class falls back to the `hypervisors` fact and then the DMI manufacturer. If neither names the hypervisor, set `pe_snapshot::provider`. |
| `vm_id` is missing | Proxmox and vSphere use `dmi.product.uuid`, GCE uses the `gce` fact and AWS uses `ec2_metadata`. If the fact isn't there, set `pe_snapshot::vm_id`: the Proxmox vmid, the vSphere managed object id (`vm-1234`), `<zone>/<instance>` for GCE, or the instance id for AWS. |

## A VM can't be found

`vm_not_found` means the endpoint answered but no VM matched.

| Where | Check |
|---|---|
| Proxmox | The token only sees VMs it has an ACL on, so a new VM needs `pveum acl modify /vms/<vmid> ...` before it can be snapshotted. Otherwise, compare the node's `dmi.product.uuid` with the VM's `smbios1` uuid (`qm config <vmid> \| grep smbios1`). A VM restored from a backup or rebuilt by hand can have a new uuid. Set `pe_snapshot::vm_id` to the vmid if they can't be made to match. |
| GCE | The VM id is `<zone>/<instance>`. A 404 for that instance means it was deleted, moved zone, or lives in a different project from the endpoint's. |
| vSphere | The account only sees VMs in folders its role is granted on. Otherwise compare the node's `dmi.product.uuid` with the VM's BIOS uuid (`govc vm.info -json <vm>`, `config.uuid`). pe_snapshot also tries the byte-swapped form older hardware shows the guest. Set `pe_snapshot::vm_id` to the managed object id (`vm-1234`) if neither matches. |
| AWS | The VM id is the instance id, and it belongs to one region, so the node's endpoint has to be that region's. A terminated instance is not found. |
| An endpoint list | The VM wasn't on any of them. If one endpoint couldn't be asked, the error is that endpoint's error and not `vm_not_found`, because the VM might be there. |

## API errors

`api_error` carries the HTTP status in `details.status` and the start of the response body in the message.

| Status | Proxmox | GCE |
| --- | --- | --- |
| 400 from `/token` with `invalid_grant` | | The `authorized_user` refresh token was revoked or expired by session policy. Log in again, or move to a service account key |
| 401 | The token id or secret is wrong, or the token was removed | The access token was refused. Check the key hasn't been deleted from the service account |
| 403 | The token's role or ACL doesn't cover this action on this VM. The body names the missing privilege | The service account lacks a permission. The body names it. Compare with the role in [providers](providers.md) |
| 404 | The VM or node path doesn't exist, often a VM migrated mid-call. Retry | The instance, disk or snapshot doesn't exist |
| 5xx | The cluster returned a server error. Check the Proxmox UI | A Google-side fault. Retry |

vSphere reports errors as SOAP faults, so its `api_error` carries the fault type in `details.fault` as well as the HTTP status. `NoPermission` means the role is missing a privilege, which the message names. `ManagedObjectNotFound` means the VM or snapshot was deleted while pe_snapshot was working on it.

AWS errors carry the EC2 error code in `details.code`. `UnauthorizedOperation` means the IAM policy is missing an action or a condition doesn't match, and the message has an encoded authorisation failure that `aws sts decode-authorization-message` explains. A delete refused because the snapshot is still `pending` needs retrying once it completes. The sweep retries expired ones on its own.

`api_unreachable` means there was no HTTP answer at all. Test from the proxy with `curl -sv <url>`. A TLS failure against an internal CA needs `ca_file` on the endpoint. Leave `verify_tls` on.

## The sweep isn't deleting expired snapshots

The `PeSnapshotExpiredNotSwept` alert fires after 75 minutes, which allows for the proxy's fact lagging its sweep by one run.

| Cause | Detail |
|---|---|
| The proxy isn't running Puppet | The sweep runs only during the proxy's agent runs. |
| `pe_snapshot::proxy::sweep` is false | Set it to true, unless the sweep is off on purpose |
| The endpoint is in error | If the proxy can't list an endpoint, it has nothing to sweep there. Check `pe_snapshot_proxy.endpoints`. |
| The endpoint was removed from Hiera | Its config and credentials are purged, so its snapshots are no longer listed or swept. They stay on the hypervisor until someone deletes them. |
| A deletion failed | The sweep's exec fails the proxy's agent run with the error kind and message, and it tries again next run. |

## Plans fail with a permission error

The plans run their tasks on the proxy. The user running a plan needs PE permission to run the `pe_snapshot` tasks on the proxy as well as on the targets, and the `pe_snapshot::marker` task on the targets.

## The board

| Symptom | Cause |
| --- | --- |
| A board or rule change doesn't appear | It takes two agent runs on the primary, then one on the dashboard node. [Puppet Observability](observability.md) explains why |
| The board doesn't appear at all, and the primary run says the plugin's board was refused | The board asks for the `patches` annotation layer, which needs observability R1136 or later. The collector and rules still load |
| Snapshots By Node and Unmapped Nodes are empty while the stats show snapshots | `observability::enable_custom_metrics` is off on the primary, or `pe_snapshot::pobs::node_tables` is false |
| Endpoints shows `error` | Same as the proxy fact. The fact holds the reason |
| A node is missing from the node counts | It hasn't had two agent runs with the class yet, so its fact hasn't reached PuppetDB |

## Alerts

Each alert's entry on Puppet Observability's Runbook board carries the same steps as this table, from the rule's description in `files/pobs/rules.yaml`.

| Alert | Severity | Start with |
| --- | --- | --- |
| `PeSnapshotExpiredNotSwept` | warning, after 75 minutes | [The sweep isn't deleting expired snapshots](#the-sweep-isnt-deleting-expired-snapshots) |
| `PeSnapshotEndpointUnreachable` | warning, after 1 hour | The endpoint's `error` in the proxy's `pe_snapshot_proxy` fact, then [API errors](#api-errors) |
| `PeSnapshotOlderThanAWeek` | info, after 1 hour | Snapshots By Node on the board. They exist because `allow_no_expiry` is on or `max_retention_hours` is over 168. Delete the ones nobody needs |

## A restored node doesn't list its snapshot

`restore` rolls the target's disk back, and the marker file goes back with it. The snapshot still exists, and the proxy's fact and `pe_snapshot::list` still show it, so delete it by tag when you're done.

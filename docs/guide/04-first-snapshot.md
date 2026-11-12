# 4. Take a first snapshot

## Why

A mapped fact doesn't prove the account can snapshot the VM, so take one on a node you don't mind, then delete it.

## Before you start

- Step 3 done, with the node mapped
- A PE user who can run tasks on both the node and the proxy, since the plans run their tasks on the proxy

## Do it

On the primary, with a one-hour expiry so it cleans itself up if you stop here:

```sh
puppet plan run pe_snapshot::create targets=web1.example.com tag=first-check retention_hours=1
puppet plan run pe_snapshot::list targets=web1.example.com
puppet plan run pe_snapshot::delete targets=web1.example.com tag=first-check
```

[Plans and facts](../plans.md#plans) describes each plan, and restore.

## Done when

`create` reports `"status": "success"` with the snapshot's name:

```json
"value": { "tag": "first-check", "name": "pes-91f54c92-1794457717", "endpoint": "lab_pve", ... }
```

`list` shows it with `"state": "active"`, and the snapshot is visible in the hypervisor's own UI. `delete` reports it under `"deleted"`, and a second `list` shows `"snapshots": []`.

## If it fails

A failed node's result carries an `_error` with a kind such as `pe_snapshot/vm_not_found`. [Errors by kind](../troubleshooting.md#errors-by-kind) has each one. The usual ones on a first snapshot:

| Kind | Do |
|---|---|
| `unmapped` | Back to step 3 |
| `vm_not_found` | The account can't see that VM. Check its grant, see [A VM can't be found](../troubleshooting.md#a-vm-cant-be-found) |
| `provider_task_failed` | The hypervisor refused the snapshot. On Proxmox, a disk on storage that can't snapshot, such as plain LVM, is the common cause |
| A PE permission error | See [Plans fail with a permission error](../troubleshooting.md#plans-fail-with-a-permission-error) |

## Next

[Snapshot around a change](05-change.md), or [watch it in Puppet Observability](06-observability.md).

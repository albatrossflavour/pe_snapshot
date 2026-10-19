# Changelog

## Unreleased

**Features**

- AWS provider, through the EC2 Query API with SigV4 signed on the proxy. One crash-consistent `CreateSnapshots` per instance, tagged so the volume snapshots group back together. No restore. Tested against moto only so far.
- vSphere provider, through vCenter's SOAP API, with memory and quiesce snapshots, restore, and VM lookup by BIOS uuid or managed object id. Tested against vcsim only so far.
- GCE provider, by service account key or an `authorized_user` file. Snapshots every attached disk under one label. No restore.
- `pe_snapshot::endpoint` can be a list, for VMs that move between hosts or clusters with separate APIs.
- Puppet Observability plugin (`pe_snapshot::pobs`): collector, alert rules, and a Snapshots board with per-node tables and the Patch windows annotation layer. The board needs observability R1136 or later.
- External credentials files under `/etc/puppetlabs/pe_snapshot/credentials.d`, for a secrets agent to write.
- `pe_snapshot::restorable`, false by default on PE infrastructure. The restore plan refuses a node that isn't restorable.

**Fixes**

- A VM id matching more than one VM, such as a clone that kept its BIOS UUID, is refused as `pe_snapshot/ambiguous_vm` instead of using the first match.
- Guests that Facter reports as `physical` (Rocky 9 and 10 without `virt-what`, Windows on Proxmox) are detected from the `hypervisors` fact or the DMI manufacturer.
- The proxy class no longer redeclares the config directory when the node also has `pe_snapshot`.
- An unreadable credentials file is reported by path only, never with its content.
- Credentials files are written with `backup => false`, so the clientbucket keeps no copy.
- The plans' `credentials` parameter is typed `Sensitive[Hash]`, so the orchestrator stores no value for it.

**Docs**

- Operations, troubleshooting, contributing and security docs, and the Apache 2.0 licence.
- The alert rules carry full runbook entries for the Runbook board.

## 0.1.0

First release. Proxmox VE provider, the create, list, delete and restore plans and tasks, the `pe_snapshot` and `pe_snapshot_proxy` facts, and expiry sweeps on the proxy's agent runs.

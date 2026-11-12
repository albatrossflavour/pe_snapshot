# Changelog

## 0.1.1

- The README links to the docs on GitHub, so they work on the Forge

## 0.1.0

First release. Snapshots nodes on Proxmox VE, GCE, vSphere, and AWS from Puppet Enterprise plans, and expires them on the proxy's agent runs.

- Proxmox VE provider, tested on a Proxmox 9.2 cluster, with restore
- GCE provider, by service account key or an `authorized_user` file. Snapshots every attached disk under one label. No restore
- vSphere provider, through vCenter's SOAP API, with memory and quiesce snapshots, restore, and VM lookup by BIOS uuid or managed object id. Tested against vcsim only so far
- AWS provider, through the EC2 Query API with SigV4 signed on the proxy. One crash-consistent `CreateSnapshots` per instance, tagged so the volume snapshots group back together. No restore. Tested against moto only so far
- The create, list, delete, and restore plans and tasks, usable from `puppet plan run` and from other plans
- The `pe_snapshot` and `pe_snapshot_proxy` facts, and expiry sweeps on the proxy's agent runs
- `pe_snapshot::endpoint` can be a list, for VMs that move between hosts or clusters with separate APIs. A VM id matching more than one VM is refused as `pe_snapshot/ambiguous_vm`
- Guests that Facter reports as `physical` (Rocky 9 and 10 without `virt-what`, Windows on Proxmox) are detected from the `hypervisors` fact or the DMI manufacturer
- Credentials from Hiera, a `Deferred`, or an external file under `/etc/puppetlabs/pe_snapshot/credentials.d` for a secrets agent to write. Files are written with `backup => false`, an unreadable one is reported by path only, and the plans' `credentials` parameter is `Sensitive`, so the orchestrator stores no value
- `pe_snapshot::restorable`, false by default on PE infrastructure. The restore plan refuses a node that isn't restorable
- An install guide in `docs/guide/`, with a check for each step, and reference pages for providers, configuration, plans and facts, secrets, operations, and troubleshooting

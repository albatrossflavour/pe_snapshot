# pe_snapshot

Hypervisor and cloud snapshots for Puppet Enterprise. Before risky work such as patching, a plan snapshots the nodes involved, and afterwards deletes the snapshots or lets them expire, so nobody has to remember to clean up. It runs from the PE orchestrator, with `puppet plan run`, or as steps in your own plans.

It only ever lists, sweeps, or deletes snapshots it created itself. Each one is named `pes-<8 hex>-<epoch>` and carries its tag and expiry in its description.

| Provider | Status |
| --- | --- |
| Proxmox VE | Tested on a Proxmox 9.2 cluster |
| GCE | Tested on GCE instances. No restore |
| vSphere | Tested against vcsim (govmomi's vCenter simulator), not yet a real vCenter |
| AWS (EC2) | Tested against moto (a mock AWS server), not yet a real account. No restore |
| libvirt, Azure | Planned |

## How it works

- Every node that can be snapshotted gets the `pe_snapshot` class. It works out the node's provider, proxy, endpoint, and VM id, and publishes them in the `pe_snapshot` fact.
- A proxy node gets `pe_snapshot::proxy`. It holds the hypervisor API endpoints and their credentials, and the tasks run there. It can be the primary, or any Linux node that can reach the hypervisor API.
- The plans look up each target's fact in PuppetDB, group the targets by proxy, and run one task per proxy.
- On every agent run, the proxy lists the managed snapshots on its endpoints in its `pe_snapshot_proxy` fact, and deletes the ones that have expired.

## Requirements

- Puppet Enterprise, with Puppet 8, PuppetDB, and the orchestrator
- A Linux proxy with HTTPS to each hypervisor or cloud API, and an account there that can snapshot the VMs you want covered
- Nodes on RHEL 9 or 10, AlmaLinux, Rocky, or Oracle Linux 8 to 10, Debian 12, Ubuntu 22.04 or 24.04, or Windows Server 2022 or 2025

## Getting started

Follow [the install guide](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/guide/README.md). It goes from choosing a proxy to a first snapshot taken and deleted, with a check at the end of each step, and on to wrapping a change in your own plan.

## Reference

- Each provider's least-privilege account and settings: [providers](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/providers.md)
- Proxies, endpoints, credentials, and retention: [configuration](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/configuration.md)
- The plans, using them around a change in your own plan, and the facts: [plans and facts](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/plans.md)
- Where credentials live and how to rotate them: [secrets](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/secrets.md)
- Running it day to day, upgrading, and uninstalling: [operations](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/operations.md)
- Every error and what to do about it: [troubleshooting](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/troubleshooting.md)
- Why it's built the way it is: [design](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/design.md)
- Every class, plan, task, and parameter: [REFERENCE.md](https://github.com/albatrossflavour/pe_snapshot/blob/main/REFERENCE.md)
- What changed in each release: [CHANGELOG.md](https://github.com/albatrossflavour/pe_snapshot/blob/main/CHANGELOG.md)
- Developing it and adding a provider: [CONTRIBUTING.md](https://github.com/albatrossflavour/pe_snapshot/blob/main/CONTRIBUTING.md). Reporting a vulnerability: [SECURITY.md](https://github.com/albatrossflavour/pe_snapshot/blob/main/SECURITY.md)

## Limits

- A VM id that matches more than one VM is refused with `pe_snapshot/ambiguous_vm`. Clones can keep their source's BIOS UUID (vCenter asks whether to keep it), and guessing could snapshot or restore the wrong machine. Set `pe_snapshot::vm_id` for those nodes.
- PE infrastructure can't be restored unless you set `pe_snapshot::restorable` for it. See [secrets](https://github.com/albatrossflavour/pe_snapshot/blob/main/docs/secrets.md) for why.
- `restore` keeps the snapshot. The target's own marker file is rolled back with its disk, so its `pe_snapshot` fact won't list the snapshot afterwards. The proxy's fact still does.
- The plans run their tasks on the proxy, so the user running a plan needs PE permission to run tasks on the proxy as well as on the targets.

## Licence

Apache-2.0.

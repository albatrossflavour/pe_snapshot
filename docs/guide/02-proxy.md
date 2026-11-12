# 2. Set up the proxy

## Why

The proxy is where snapshot calls run and where credentials live. It also lists every snapshot the module has made on its endpoints, and deletes the ones that have expired.

## Before you start

- Step 1 done
- The module and its dependency, `puppetlabs-stdlib`, in your Puppetfile, and deployed to the proxy's environment
- eyaml, or another way to keep credentials out of plain Hiera. See [secrets](../secrets.md)

## Do it

Create a least-privilege account on each hypervisor or cloud, as [providers](../providers.md) describes for [Proxmox](../providers.md#proxmox), [GCE](../providers.md#gce), [vSphere](../providers.md#vsphere), and [AWS](../providers.md#aws). Scope it to the VMs you'd patch, so a VM outside its reach fails as `pe_snapshot/vm_not_found` and can't be snapshotted or rolled back.

List the endpoints and their credentials in the proxy's Hiera, as [Proxies and endpoints](../configuration.md#proxies-and-endpoints) describes:

```yaml
pe_snapshot::proxy::endpoints:
  - name: lab_pve
    provider: proxmox
    url: https://pve1.example.com:8006
pe_snapshot::proxy::credentials:
  lab_pve: >
    ENC[PKCS7,...]
```

Add the class to the proxy's profile, and run the agent on the proxy:

```puppet
include pe_snapshot::proxy
```

## Done when

On the proxy:

```sh
sudo puppet facts show pe_snapshot_proxy
```

Each endpoint is listed with `"status": "ok"` and an empty `error`, such as:

```json
{ "name": "lab_pve", "provider": "proxmox", "status": "ok", "error": "", "count": 0, "health": "lab_pve:ok" }
```

## If it fails

A failing endpoint has `"status": "error"`, and its `error` holds the message, cut to 300 characters. [Errors by kind](../troubleshooting.md#errors-by-kind) explains each cause. The usual ones on a new install:

| The message is about | Do |
|---|---|
| Missing credentials | Check `pe_snapshot::proxy::credentials` has an entry under the endpoint's exact name, and the proxy has run since |
| A refused login, a 401, or a 403 | Check the account and its role against [providers](../providers.md) |
| No answer from the API | Back to step 1 |
| A bad endpoint name, or no GCE `project` or AWS `region` | Fix the Hiera |

## Next

[Map the nodes](03-nodes.md).

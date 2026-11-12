# Configuring pe_snapshot

## Proxies and endpoints

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

`verify_tls` defaults to true. Setting it to false sends the token to whatever answers at that address, so use `ca_file` for an internal CA, and turn `verify_tls` off only in a lab.

## Retention

Snapshots expire after 24 hours by default, and a request for more than 168 hours is refused. Both limits are proxy settings:

```yaml
pe_snapshot::proxy::default_retention_hours: 24
pe_snapshot::proxy::max_retention_hours: 168
pe_snapshot::proxy::allow_no_expiry: false
```

The proxy enforces them, so a direct task call can't get round them. Expired snapshots are deleted on the proxy's next agent run.

# Secrets

pe_snapshot holds no secret machinery of its own. It takes credentials from Hiera (plain, eyaml or `Deferred`), from a root-only file an external agent writes, or from the plans' `credentials` parameter, and the proxy is the trust boundary.

Where a hypervisor credential exists:

| Copy | Notes |
| --- | --- |
| Hiera | eyaml ciphertext, or nothing at all with `Deferred` |
| Compiled catalog and the proxy's cached catalog | The decrypted value, as Sensitive, unless it is `Deferred`. Anyone who can read the proxy's catalog or PuppetDB's catalog store can read it |
| `/etc/puppetlabs/pe_snapshot/endpoints/<endpoint>.creds.json` | root `0600`, `backup => false`, because the clientbucket otherwise keeps a Sensitive file's old content in plain text on change |
| `/etc/puppetlabs/pe_snapshot/credentials.d/<endpoint>.json` | Only if an external agent writes it |
| Backups and VM snapshots of the proxy | Including snapshots pe_snapshot itself takes, if the proxy is a target |
| PE support bundle | File names only. The bundle lists `/etc/puppetlabs` but doesn't copy this directory |
| Orchestrator job records | Never. `credentials` is typed `Sensitive`, so the orchestrator lists it under `options.sensitive` and stores no value |

The token can only snapshot what its hypervisor ACL lets it see, so scope it to the VMs you patch (see [Proxmox](providers.md#proxmox)). An unreadable credentials file is reported in the `pe_snapshot_proxy` fact by name and error class only, never with its content.

PE infrastructure is not restorable by default. `pe_snapshot::restorable` defaults to false on any node with the `pe_server_version` fact, and the restore plan refuses a node whose fact does not say `restorable: true`. Rolling back a primary or compiler revives revoked certificates, old tokens and old Hiera data, and loses everything the CA and PuppetDB recorded since. Set `pe_snapshot::restorable: true` in that node's Hiera to override.

To rotate a credential, update Hiera (or let the external agent rewrite its file) and the next proxy agent run uses it. If one leaks, revoke it on the hypervisor first (`pveum user token remove`, `gcloud iam service-accounts keys delete`, `aws iam delete-access-key`, or changing the vCenter user's password), then issue a new one. [Operations](operations.md#rotating-a-credential) has the steps. To watch who reads the files:

```sh
auditctl -w /etc/puppetlabs/pe_snapshot/endpoints -p r -k pe_snapshot_creds
auditctl -w /etc/puppetlabs/pe_snapshot/credentials.d -p r -k pe_snapshot_creds
```

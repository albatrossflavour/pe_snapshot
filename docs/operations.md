# Operations

Running pe_snapshot once it's installed. Setup is in [the install guide](guide/README.md), and errors are in [troubleshooting](troubleshooting.md).

## Checking it's healthy

From the primary, the proxies' endpoints and snapshots, and any unmapped nodes:

```sh
sudo puppet query 'facts[certname, value] { name = "pe_snapshot_proxy" }'
sudo puppet query 'fact_contents[certname, value] { path ~> ["pe_snapshot", "coverage"] and value ~ ":unmapped$" }'
```

## Retention

Change the limits in the proxy's Hiera, as [Retention](configuration.md#retention) describes. They take effect on the proxy's next agent run and apply to new snapshots. A snapshot's expiry is written into its description when it's taken, so changing the limits doesn't extend or shorten existing ones. To keep a snapshot past its expiry, take a new one and delete the old.

## Adding an endpoint

1. Create the credential on the hypervisor, scoped as [providers](providers.md) describes for the provider.
2. Add the endpoint to `pe_snapshot::proxy::endpoints` and its credential to `pe_snapshot::proxy::credentials`, under the same name.
3. Run the agent on the proxy. `pe_snapshot_proxy.endpoints` should show the new endpoint as `ok` on the run after that.
4. Set `pe_snapshot::endpoint` for the nodes it serves. Each needs two agent runs before its fact is complete.

For Proxmox, every VM the token should snapshot needs its ACL, including VMs built later.

## Removing an endpoint

Delete its snapshots first. Removing the endpoint from Hiera purges its config and credentials from the proxy, and after that nothing lists or sweeps its snapshots.

```sh
puppet plan run pe_snapshot::list targets=<nodes on that endpoint>
puppet plan run pe_snapshot::delete targets=<nodes> tag=<tag>
```

Then remove it from Hiera, run the agent on the proxy, and revoke the credential on the hypervisor.

## Rotating a credential

Issue the new credential, put it in Hiera (or let the external agent rewrite its file), and run the agent on the proxy. Every task reads the credentials file when it starts, so the next call uses the new one. Then revoke the old one:

| Provider | Steps |
|---|---|
| Proxmox | `pveum user token add` a new token with `--privsep 1`, grant it the same ACLs, then `pveum user token remove` the old one. |
| GCE | `gcloud iam service-accounts keys create` a new key, then `gcloud iam service-accounts keys delete` the old key's id once the proxy has run. |
| AWS | `aws iam create-access-key` a new key (a user can hold two), put it in Hiera, run the proxy, then `aws iam delete-access-key` the old one. |
| vSphere | There's one password, so change it in vCenter and in Hiera together, and run the agent on the proxy straight after. Tasks started in between fail with `auth_failed`. |

If a credential leaks, revoke it on the hypervisor first and replace it second.

## Moving the proxy

1. Declare `pe_snapshot::proxy` on the new node with the same endpoint names and credentials, and run its agent twice. Check `pe_snapshot_proxy.endpoints` there.
2. Change `pe_snapshot::proxy` in the nodes' Hiera. Each node needs two agent runs before the plans use the new proxy.
3. Remove the proxy class from the old node. Puppet stops managing the files but doesn't delete them, so remove `/etc/puppetlabs/pe_snapshot/endpoints` and `/etc/puppetlabs/pe_snapshot/credentials.d` from it by hand.

Snapshots taken through the old proxy carry on as normal. The new proxy lists them from the hypervisor and sweeps them when they expire.

While both proxies have the class, both sweep. A snapshot can be deleted by either, and the second delete finds nothing to do.

## Upgrading

Change the module's version in the control repo's Puppetfile and deploy it as you would any other module change.

The tasks carry their library with them, so the next plan run uses the new code. The facts and the sweep pick it up on each node's next agent run. Read the [changelog](../CHANGELOG.md) before deploying for anything that needs Hiera changes.

## Uninstalling

1. List and delete every managed snapshot. `pe_snapshot_proxy.snapshots` on each proxy is the full list.
2. Remove `pe_snapshot::proxy` from the proxies and `pe_snapshot` from the nodes.
3. Delete `/etc/puppetlabs/pe_snapshot` on every node. On Windows it's `C:/ProgramData/PuppetLabs/pe_snapshot`.
4. Revoke the credentials. For Proxmox, remove the token, the user and the `PESnapshot` role. For GCE, delete the service account and the `peSnapshot` role. For AWS, delete the access keys, the policy and the user. For vSphere, remove the permissions, the `PESnapshot` role and the user.
5. Remove the module from the Puppetfile.

Snapshots left on a hypervisor after step 2 are ordinary snapshots. Any name starting `pes-` came from pe_snapshot, and its description holds the metadata, so they're easy to find by hand.

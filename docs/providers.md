# Providers

Each provider's least-privilege account, endpoint settings, and how it finds a node's VM.

## Proxmox

Use a privilege-separated API token, granted on the VMs it may snapshot and nothing else:

```sh
pveum role add PESnapshot --privs "VM.Audit,VM.Snapshot,VM.Snapshot.Rollback,VM.PowerMgmt"
pveum user add pe_snapshot@pve
pveum user token add pe_snapshot@pve pe_snapshot --privsep 1
for id in <vmid> ...; do
  pveum acl modify /vms/$id --users pe_snapshot@pve --tokens 'pe_snapshot@pve!pe_snapshot' --roles PESnapshot
done
```

`VM.PowerMgmt` is only for starting a VM after a restore. Nothing needs `Sys.Audit` or an ACL on `/nodes`, because a token can read the status of its own tasks. Granting per VM (or per pool, if your pools separate patchable VMs from infrastructure) keeps the PE primary, compilers and anything else you would never roll back out of the token's sight: a VM it can't see fails as `pe_snapshot/vm_not_found`. A new VM needs its ACL before it can be snapshotted.

The credentials are `{"token_id": "pe_snapshot@pve!pe_snapshot", "token_secret": "..."}`. The VM is found by matching its SMBIOS UUID (`dmi.product.uuid`) against each VM's `smbios1` setting, or by setting `pe_snapshot::vm_id` to the vmid. Proxmox has no quiesce option. It freezes the guest filesystem through the QEMU guest agent whenever the agent is enabled on the VM.

## GCE

A service account with a custom role holding only what pe_snapshot calls:

```sh
P=<project>
gcloud iam roles create peSnapshot --project $P --title "pe_snapshot" \
  --permissions compute.instances.get,compute.instances.list,compute.disks.get,compute.disks.createSnapshot,compute.snapshots.create,compute.snapshots.get,compute.snapshots.list,compute.snapshots.delete,compute.snapshots.setLabels,compute.zoneOperations.get,compute.globalOperations.get
gcloud iam service-accounts create pe-snapshot --project $P
gcloud projects add-iam-policy-binding $P --role projects/$P/roles/peSnapshot --member serviceAccount:pe-snapshot@$P.iam.gserviceaccount.com
gcloud iam service-accounts keys create key.json --iam-account pe-snapshot@$P.iam.gserviceaccount.com
```

The endpoint takes the project as an option, and the credentials are the key file's JSON as it comes:

```yaml
pe_snapshot::proxy::endpoints:
  - name: gce_prod
    provider: gce
    options:
      project: my-project
pe_snapshot::proxy::credentials:
  gce_prod: ENC[PKCS7,...]
```

The credentials can also be an `authorized_user` file from `gcloud auth application-default login`, which makes the proxy act as that person. That's for trying the provider before a service account is set up: the snapshots are logged as the person, the refresh token carries everything they can do, and an org's session policy can expire it. Swap it for a service account key by changing the Hiera value.

The proxy signs a JWT with the key and exchanges it for an hour-long token, so the key itself never leaves the proxy. It is still a long-lived credential: keep it out of any repository, rotate it with `gcloud iam service-accounts keys`, and prefer the external credentials file if a secrets agent can write it.

A node is identified as `<zone>/<instance>` from its `gce` fact, which works when the instance name differs from the certname. GCE snapshots disks, not VMs, so one pe_snapshot snapshot is one disk snapshot per attached disk, all labelled `pe_snapshot_name=<name>`. `quiesce: true` asks the guest to flush (`guestFlush`), and there is no memory state. Restore is refused with `pe_snapshot/restore_unsupported`: create disks from the labelled snapshots, stop the instance, swap the disks and start it.

## vSphere

pe_snapshot talks to vCenter's SOAP API, because the REST API has no VM snapshot calls. Create a vCenter user and a role with only the snapshot and power-on privileges, and grant it on the folders that hold VMs you'd patch:

```sh
govc sso.user.create -p '<password>' pe_snapshot
govc role.create PESnapshot VirtualMachine.State.CreateSnapshot VirtualMachine.State.RemoveSnapshot VirtualMachine.State.RevertToSnapshot VirtualMachine.Interact.PowerOn
govc permissions.set -principal pe_snapshot@vsphere.local -role PESnapshot -propagate=true /<datacenter>/vm/<folder>
```

`VirtualMachine.Interact.PowerOn` is only for starting a VM after a restore. A VM outside the granted folders is invisible to the account and fails as `pe_snapshot/vm_not_found`, so keep vCenter, the PE primary and compilers out of them.

```yaml
pe_snapshot::proxy::endpoints:
  - name: prod_vc
    provider: vsphere
    url: https://vcenter.example.com
    ca_file: /etc/pki/vcenter-ca.pem
pe_snapshot::proxy::credentials:
  prod_vc: ENC[PKCS7,...]
```

The credentials are `{"username": "pe_snapshot@vsphere.local", "password": "..."}`. The proxy logs in once per task or agent run and logs out when it ends. `options` can set `api_version` (the SOAP version sent, default `7.0`, which vCenter 7 and 8 accept) and `task_timeout`.

A VM is found by its BIOS uuid, which the guest reports as `dmi.product.uuid`. Older virtual hardware shows the guest the first three uuid fields in the other byte order, and pe_snapshot tries that form when the first finds nothing. A template sharing the uuid is ignored. Where a uuid matches two VMs, set `pe_snapshot::vm_id` to the VM's managed object id (`vm-1234`), which is also what the proxy fact reports.

`memory: true` saves the VM's memory and `quiesce: true` quiesces the guest through VMware Tools, and the snapshot fails if Tools isn't running. A restore reverts, then powers the VM on if `start` is true and the revert left it off. vSphere doesn't keep snapshot names unique, so `delete` removes every snapshot with the name.

## AWS

An IAM user (or role) with a policy that can only describe, snapshot, and delete snapshots pe_snapshot tagged:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ec2:DescribeInstances", "ec2:DescribeSnapshots"], "Resource": "*" },
    { "Effect": "Allow", "Action": "ec2:CreateSnapshots",
      "Resource": ["arn:aws:ec2:*:*:instance/*", "arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*::snapshot/*"] },
    { "Effect": "Allow", "Action": "ec2:CreateTags", "Resource": "arn:aws:ec2:*::snapshot/*",
      "Condition": { "StringEquals": { "ec2:CreateAction": "CreateSnapshots" } } },
    { "Effect": "Allow", "Action": "ec2:DeleteSnapshot", "Resource": "arn:aws:ec2:*::snapshot/*",
      "Condition": { "StringEquals": { "aws:ResourceTag/pe_snapshot": "1" } } }
  ]
}
```

To keep infrastructure out of reach, narrow the `instance/*` resource with an `ec2:ResourceTag` condition on a tag your patchable instances carry.

One endpoint per region, with the region as an option:

```yaml
pe_snapshot::proxy::endpoints:
  - name: aws_syd
    provider: aws
    options:
      region: ap-southeast-2
pe_snapshot::proxy::credentials:
  aws_syd: ENC[PKCS7,...]
```

The credentials are `{"access_key_id": "...", "secret_access_key": "..."}`, plus `session_token` for temporary STS credentials. Requests are signed with SigV4 on the proxy, so the secret key never leaves it. `url` overrides the EC2 endpoint, for a VPC endpoint or a GovCloud region.

A node is identified by its instance id from the `ec2_metadata` fact. EBS snapshots volumes, not instances, so one pe_snapshot snapshot is a single `CreateSnapshots` call: a crash-consistent snapshot of every attached volume, tagged `pe_snapshot_name=<name>` and `pe_snapshot_instance=<id>`. `create` returns once the snapshots have started, because they're consistent from that moment and copying to S3 can take a long time. There is no memory state and no quiesce, so `memory: true` and `quiesce: true` are refused with `pe_snapshot/unsupported_option`, and so is restore, with `pe_snapshot/restore_unsupported`: create volumes from the tagged snapshots, stop the instance, swap the volumes and start it.

EC2 limits a snapshot description to 255 characters, and pe_snapshot keeps its metadata there. A very long certname or tag can go over it, which fails as `pe_snapshot/bad_description` before anything is created.

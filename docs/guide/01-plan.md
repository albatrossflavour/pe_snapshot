# 1. Plan the proxy

## Why

Every snapshot call goes through a proxy, which holds the hypervisor credentials. Choosing it, and checking it can reach each API, comes before anything is installed, because a proxy that can't reach an endpoint only shows up when a plan fails.

## Before you start

- Puppet Enterprise with Puppet 8, PuppetDB, and the orchestrator
- The hypervisors or clouds your nodes run on. [Providers](../providers.md) lists what each needs

## Do it

Pick a Linux node to be the proxy. The primary works, or any node with network access to the hypervisor APIs. Where nodes sit in separate network zones, plan one proxy per zone.

Decide each endpoint's name. An endpoint is one API: a Proxmox cluster, a vCenter, a GCE project, or an AWS region. Names are lower case letters, digits, and underscores, such as `lab_pve` or `aws_syd`.

Decide which nodes must never be rolled back. The PE primary and compilers are protected by default, and the hypervisor account in step 2 is the place to keep anything else out of reach.

## Done when

From the proxy, each API answers over HTTPS. For Proxmox:

```sh
curl -sk -o /dev/null -w '%{http_code}\n' --max-time 10 https://pve1.example.com:8006/api2/json/version
```

Any HTTP status means the API is reachable, such as `401` here, since no token was sent. `000` means it isn't. For GCE, use `https://compute.googleapis.com/`, for AWS `https://ec2.<region>.amazonaws.com/`, and for vSphere your vCenter's address.

## If it fails

`000` is DNS, routing, a firewall, or a proxy server between the two. Fix that before going on, or choose a proxy closer to the API.

## Next

[Set up the proxy](02-proxy.md).

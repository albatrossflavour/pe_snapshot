# 3. Map the nodes

## Why

A plan can only snapshot a node whose `pe_snapshot` fact says which provider, proxy, endpoint, and VM it is. The class works that out on each node from its facts and Hiera.

## Before you start

- Step 2 done, with every endpoint `ok`
- A profile every node gets, to put the class in

## Do it

Tell nodes their proxy and endpoint in Hiera, usually per location or network zone:

```yaml
pe_snapshot::proxy: puppet.example.com
pe_snapshot::endpoint: lab_pve
```

Add the class to a profile every node gets:

```puppet
include pe_snapshot
```

The proxy gets this class too, since `pe_snapshot::proxy` includes it, so set its proxy and endpoint like any other node's, or it shows as unmapped. Don't confuse the `pe_snapshot::proxy` Hiera key, which names a node's proxy, with the `pe_snapshot::proxy` class.

Run the agent twice on each node, or wait for two scheduled runs. The fact reaches PuppetDB on the second run, because facts are collected before the first run writes what the fact reads.

The provider and VM id come from facts. Where that's wrong, or a VM can move between endpoints, see [Proxies and endpoints](../configuration.md#proxies-and-endpoints).

## Done when

On the primary:

```sh
sudo puppet query 'inventory[certname] { facts.pe_snapshot.mapped = false }'
```

returns `[]`, and

```sh
sudo puppet query 'inventory[count()] { facts.pe_snapshot.mapped = true }'
```

returns the number of nodes you gave the class. The first alone isn't enough, because it's also empty before any node has reported the fact. On a node, `sudo puppet facts show pe_snapshot` has `"mapped": true` and a `coverage` such as `"proxmox:mapped"`.

## If it fails

| You see | Do |
|---|---|
| A node in the query's answer | See [A node is unmapped](../troubleshooting.md#a-node-is-unmapped). Usually the proxy or endpoint isn't set for it in Hiera |
| A node missing from PuppetDB's answer entirely | It hasn't had two agent runs since the class was added |
| The wrong provider | Set `pe_snapshot::provider` for that node. On a `kvm` guest the default is Proxmox |

## Next

[Take a first snapshot](04-first-snapshot.md).

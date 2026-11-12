# Installing pe_snapshot

This guide takes you from choosing a proxy to a first snapshot taken and deleted, then on to wrapping a change in your own plan. The steps link to [the module's reference pages](../../README.md#reference) for each setting's detail.

## Which steps you need

| You want | Steps |
|---|---|
| Snapshots from your own plans or `puppet plan run` | 1 to 4 |
| Snapshots around changes your own plans make | 1 to 5 |
| Another hypervisor or cloud on an existing install | 1 and 2 for the new endpoint, then 3 for its nodes |

## The steps

1. [Plan the proxy](01-plan.md)
2. [Set up the proxy](02-proxy.md)
3. [Map the nodes](03-nodes.md)
4. [Take a first snapshot](04-first-snapshot.md)
5. [Snapshot around a change](05-change.md)

## Upgrading

A module upgrade is a Puppetfile change like any other. [Operations](../operations.md#upgrading) says what to check afterwards.

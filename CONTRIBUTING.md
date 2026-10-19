# Contributing

Read [docs/design.md](docs/design.md) first. It has the constraints every change has to keep: orchestrator-only plan functions, plans that return a ResultSet, stdlib-only Ruby, and no changes to Puppet Observability.

## Dev loop

You need the PDK. From the module root:

```sh
pdk validate
pdk test unit
pdk bundle exec puppet strings generate --format markdown
markdownlint-cli2 '**/*.md' '#vendor' '#spec/fixtures'
```

`puppet strings` regenerates `REFERENCE.md`, which is committed, so run it whenever a parameter or its doc comment changes. The markdownlint config is `.markdownlint-cli2.yaml` in the module root. Fix a failing file; don't add rules to the config.

Specs live under `spec/`:

| Path | Covers |
| --- | --- |
| `spec/classes/` | `pe_snapshot` and `pe_snapshot::proxy`, including both on one node |
| `spec/functions/` | `pe_snapshot::creds_json` |
| `spec/unit/pe_snapshot/` | The actions layer, and each provider against stubbed API responses |

## Lab validation

Specs don't prove a change works against a hypervisor. Before a change is done, deploy it and exercise it:

1. Push the branch the control repo's Puppetfile tracks, then `puppet-code deploy` it.
2. Run the agent twice on the proxy and on a target. The second run must make no changes.
3. Run each affected plan from the primary with `puppet plan run`: create, list (check the facts), delete (check they clear), and a create with a one-hour retention that the sweep removes.
4. Restore only on a throwaway VM.
5. For a board or rule change, run the agent twice on the primary and once on the dashboard node, then look at the board in a browser.

Say in the commit or PR what was lab-tested and what only has specs.

## Adding a provider

A provider is one file, `lib/pe_snapshot/providers/<name>.rb`, defining `PeSnapshot::Providers::<Name>`. The provider name comes from the endpoint's `provider` key and must match `[a-z0-9_]+`. Nothing else has to change for the plans and tasks to use it.

It implements:

| Method | Returns |
| --- | --- |
| `initialize(endpoint, http: nil)` | Takes the merged endpoint config, credentials included. Raise `missing_credentials` or `bad_endpoint` here. `http:` lets specs stub the API |
| `vms` | Every VM on the endpoint as a handle hash with at least `vm_id`. The sweep uses it |
| `resolve(vm_id)` | One handle. Pass the candidates through `PeSnapshot.one_vm` so zero matches and several matches are refused the same way everywhere |
| `list(vm)` | Every snapshot on the VM as `name`, `description` and `created` (epoch). The actions layer keeps only the managed ones |
| `create(vm, name, description, memory:, quiesce:)` | Takes the snapshot and waits for it to finish |
| `delete(vm, name)` | Deletes it and waits. A snapshot that's already gone is success |
| `restore(vm, name, start:)` | Rolls back and waits, or raises `restore_unsupported` |

Rules a provider has to follow:

- Use `PeSnapshot::HTTP` and the stdlib. `request` is for JSON APIs. `raw` returns the response whatever its status, for XML or SOAP, and the vSphere and AWS providers show how to use it. No gems, because the tasks run under the agent's Ruby on whatever the proxy is.
- Raise `PeSnapshot::Error` with a kind from [troubleshooting](docs/troubleshooting.md) where one fits. Never put a credential in a message or `details`.
- Wait for the hypervisor's job to finish, honouring `task_timeout` from the endpoint (default 900 seconds), and raise `provider_timeout` past it.
- Store the description pe_snapshot passes in, unchanged. It holds the metadata that marks a snapshot as managed.
- Snapshot names are `pes-<8 hex>-<epoch>`. If the platform makes names global, add a suffix per disk or VM as the GCE provider does.

Then add the provider's `virtual` value to `pe_snapshot::virtual_map` in `data/common.yaml` if facts can detect it, and a spec under `spec/unit/pe_snapshot/providers/`. Add a README section with the least privilege the provider's credential needs, and add any new error causes to the troubleshooting doc.

## Commits

Conventional commit prefixes (`feat:`, `fix:`, `docs:`), with a scope where it helps (`fix(board):`). Add a line to `CHANGELOG.md` under Unreleased for anything a user would notice.

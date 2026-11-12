# Security

## Reporting a vulnerability

Email tgreen@albatrossflavour.com, or open a private security advisory on the GitHub repository. Don't open a public issue. Include the version or commit, the provider, and how to reproduce it.

## What counts

pe_snapshot holds credentials that can snapshot, delete snapshots of and roll back VMs. Anything that lets someone use those credentials beyond what the plans allow is in scope, for example:

- A credential appearing in a fact, a task or plan result, an error message, a log, the orchestrator's job record or the clientbucket.
- A way to make a task act on a VM other than the one the target maps to.
- Deleting or restoring a snapshot pe_snapshot didn't create.
- Getting past the retention limits or the restore guard on PE infrastructure.

A hypervisor credential that was granted more than the least-privilege setup in [providers](docs/providers.md) is a configuration problem, not a vulnerability in the module.

## The security model

[Secrets](docs/secrets.md) lists every place a credential exists and how to rotate one. In short:

- The proxy is the trust boundary. The credentials are root-only files on it, and the tasks run there.
- Use a credential scoped to the VMs you'd snapshot. PE infrastructure should be outside its reach, and restore refuses it by default anyway.
- Use `Deferred` or an external credentials file to keep the secret out of the catalog.
- The plans' `credentials` parameter is typed `Sensitive`, so the orchestrator doesn't store its value.

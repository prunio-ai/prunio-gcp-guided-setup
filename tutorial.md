# Prunio GCP keyless connection

## 1. Authenticate this temporary Cloud Shell

This repository opens in a temporary Cloud Shell that normally has no Google
credentials. Check the active identity:

```bash
gcloud auth list --filter='status:ACTIVE'
```

If no account is active, run `gcloud auth login`. Use the customer-authorized
setup identity. Do not use a service-account key.

## 2. Review the setup boundary

The guided setup creates or reconciles one project-scoped Workload Identity
Federation pool, one provider for this connection binding, one connector service
account, exact custom roles, and a project-filtered authorized billing view. It
does not create keys, grant Owner or Editor, change organization/folder IAM, or
create the Prunio agent identity.

The detailed Cloud Billing export must already be enabled through the Cloud
Billing console. If its table is still warming, the setup stops without
registering a connection.

## 3. Run the reviewed artifact

```bash
./setup.sh
```

The script verifies this repository, release branch, commit, and complete
artifact digest before any Google Cloud mutation. Enter the one-time setup code
from Prunio when prompted; input is hidden and never placed in the URL or
shell history.

Review every derived resource and type the exact target project ID only when the
scope is correct.

## 4. Wait for Prunio verification

Registration records untrusted coordinates only. It does not mark the
connection Ready. Prunio must still synchronize the identity binding,
exchange a fresh OIDC token through Google STS, prove impersonation, test the
exact positive and negative permissions, query the scoped billing view, and run
the first inventory scan.

Keep the cleanup commands printed by the script. Run them only after Prunio
shows cleanup-pending for that exact binding or support confirms an abandoned
setup. The tenant pool can be shared by replacement bindings and is intentionally
not deleted automatically.

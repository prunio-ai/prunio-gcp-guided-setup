# Prunio GCP keyless connection

## 1. Authenticate this temporary Cloud Shell

This repository opens in a temporary Cloud Shell that normally has no Google
credentials. Check the active identity:

```bash
gcloud auth list --filter='status:ACTIVE'
```

If no account is active, run `gcloud auth login`. Use the customer-authorized
setup identity. Do not use a service-account key.

## 2. Run the reviewed setup

```bash
./setup.sh
```

The script first verifies this repository, release branch, commit, and
complete artifact digest. Nothing in Google Cloud changes before that check
passes.

## 3. Paste the setup code

Paste the one-time setup code from Prunio when prompted. Input is hidden and is
never placed in a URL, a command line, or shell history.

## 4. Pick from the menus

The script looks up the IDs instead of asking you to type them:

- **Project**: a numbered list of the projects you can access that have billing
  enabled (the first 50 are checked). If there is only one, it is chosen for
  you. You can always type a project ID instead of a number.
- **Billing account**: read from the chosen project and shown for review.
- **Billing export**: press Enter to keep the connected project as the export
  project, or type another. The script then finds the dataset that holds the
  detailed billing export table and offers it as the default.
- **Billing query project**: press Enter to keep the connected project, or type
  another.

Prunio needs the Cloud Billing **Detailed usage cost** export. If it is
missing, the script stops before changing anything and prints the exact console
steps: Billing > Billing export > BigQuery export > Detailed usage cost. Google
fills the new table over a few hours; re-run `./setup.sh` once it appears.

The script then checks your permissions. If any are missing, it names the
predefined role that grants them and prints the exact grant command. If you can
already change a project's IAM policy, it offers to grant those roles to you.
That is a separate change, made only when you type `y`. The cleanup plan
prints the commands that revoke it.

## 5. Review and confirm

The guided setup creates or reconciles one project-scoped Workload Identity
Federation pool, one provider for this connection binding, one connector service
account, exact custom roles, and a project-filtered authorized billing view. It
does not create keys, grant Owner or Editor, change organization/folder IAM, or
create the Prunio agent identity. Its Google API calls are charged to the
connected project's quota as soon as the needed APIs are enabled there, not to
gcloud's shared quota, which is often rate-limited.

Review every derived resource and type the exact target project ID only when the
scope is correct.

## 6. Wait for Prunio verification

Registration records untrusted coordinates only. It does not mark the
connection Ready. Prunio must still synchronize the identity binding,
exchange a fresh OIDC token through Google STS, prove impersonation, test the
exact positive and negative permissions, query the scoped billing view, and run
the first inventory scan.

Keep the cleanup commands printed by the script. Run them only after Prunio
shows cleanup-pending for that exact binding or support confirms an abandoned
setup. The tenant pool can be shared by replacement bindings and is intentionally
not deleted automatically. Roles the script granted to you at your request are
listed separately and can be revoked as soon as setup has finished.

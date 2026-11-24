# Prunio GCP keyless connection

## Connect your project

Type this in the terminal below and press Enter:

```bash
./setup.sh
```

Then:

1. Paste the one-time code from Prunio (input is hidden).
2. Pick the project to connect.
3. Read the short summary and answer `y`.

The script finds your billing export by itself, checks your permissions, and
changes nothing until you answer `y`. Prunio moves on by itself once it is done.

## What it creates

One identity pool, one service account, Prunio custom roles and one
project-filtered billing view in
the connected project. No keys, no Owner or Editor grants, no organization-level
changes. Run `./setup.sh --details` to see every resource name before you
approve.

If something is missing (for example the Detailed usage cost billing export),
the script stops before changing anything and prints the exact steps to fix it.

## After setup

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

#!/usr/bin/env bash

# Turns missing operator permissions into the narrowest predefined roles, the
# exact commands to grant them and, only on an explicit "y", a self-grant on
# projects whose IAM policy the operator may already change. Every self-grant
# is recorded in OPERATOR_GRANTS and printed with its revoke command.

OPERATOR_GRANTS=()
OPERATOR_MEMBER=""

set_operator_member() {
  OPERATOR_MEMBER=""
  [[ "$ACTIVE_ACCOUNT" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || return 0
  case "$ACTIVE_ACCOUNT" in
    *.gserviceaccount.com) OPERATOR_MEMBER="serviceAccount:${ACTIVE_ACCOUNT}" ;;
    *) OPERATOR_MEMBER="user:${ACTIVE_ACCOUNT}" ;;
  esac
}

# Prints the narrowest predefined role that grants permission $1.
role_for_permission() {
  case "$1" in
    bigquery.*) printf 'roles/bigquery.dataOwner' ;;
    iam.workloadIdentityPools.* | iam.workloadIdentityPoolProviders.*)
      printf 'roles/iam.workloadIdentityPoolAdmin'
      ;;
    iam.serviceAccounts.*) printf 'roles/iam.serviceAccountAdmin' ;;
    iam.roles.*) printf 'roles/iam.roleAdmin' ;;
    resourcemanager.projects.getIamPolicy | resourcemanager.projects.setIamPolicy)
      printf 'roles/resourcemanager.projectIamAdmin'
      ;;
    resourcemanager.projects.get) printf 'roles/browser' ;;
    serviceusage.services.enable) printf 'roles/serviceusage.serviceUsageAdmin' ;;
    serviceusage.services.use) printf 'roles/serviceusage.serviceUsageConsumer' ;;
    billing.accounts.get) printf 'roles/billing.viewer' ;;
    *) return 1 ;;
  esac
}

# Prints the role that already contains every permission of role $1.
covering_role() {
  case "$1" in
    roles/browser) printf 'roles/resourcemanager.projectIamAdmin' ;;
    roles/serviceusage.serviceUsageConsumer)
      printf 'roles/serviceusage.serviceUsageAdmin'
      ;;
    *) return 1 ;;
  esac
}

resource_kind_label() {
  case "$1" in
    project) printf 'project' ;;
    *) printf 'billing account' ;;
  esac
}

# Writes "KIND RESOURCE ROLE" lines to ROLE_GRANTS_FILE, without a role that a
# listed role on the same resource already covers.
build_role_grants() {
  local kind resource permission role cover candidates
  ROLE_GRANTS_FILE="${RUNTIME_DIR}/role-grants.txt"
  candidates="$(
    while read -r kind resource permission; do
      role="$(role_for_permission "$permission")" || continue
      printf '%s %s %s\n' "$kind" "$resource" "$role"
    done < "$MISSING_PERMISSIONS_FILE" | sort -u
  )"
  : > "$ROLE_GRANTS_FILE"
  while read -r kind resource role; do
    [[ -n "$kind" ]] || continue
    if cover="$(covering_role "$role")" &&
      grep -Fqx -- "${kind} ${resource} ${cover}" <<< "$candidates"; then
      continue
    fi
    printf '%s %s %s\n' "$kind" "$resource" "$role" >> "$ROLE_GRANTS_FILE"
  done <<< "$candidates"
}

print_role_grant_command() {
  local kind="$1"
  local resource="$2"
  local role="$3"
  local member="${OPERATOR_MEMBER:-PRINCIPAL}"
  if [[ "$kind" == "project" ]]; then
    printf '  gcloud projects add-iam-policy-binding %q --member=%q --role=%q --condition=None\n' \
      "$resource" "$member" "$role"
  else
    printf '  gcloud billing accounts add-iam-policy-binding %q --member=%q --role=%q\n' \
      "$resource" "$member" "$role"
  fi
}

report_missing_permissions() {
  local kind resource permission role
  build_role_grants
  {
    printf '\n%s is missing permissions that this setup needs:\n' "$ACTIVE_ACCOUNT"
    sort -u "$MISSING_PERMISSIONS_FILE" |
      while read -r kind resource permission; do
        if role="$(role_for_permission "$permission")"; then
          printf '  missing: %s on %s %s (granted by %s)\n' "$permission" \
            "$(resource_kind_label "$kind")" "$resource" "$role"
        else
          printf '  missing: %s on %s %s\n' "$permission" \
            "$(resource_kind_label "$kind")" "$resource"
        fi
      done
    if [[ -s "$ROLE_GRANTS_FILE" ]]; then
      printf '\nAn administrator of each resource can grant these roles with:\n'
      while read -r kind resource role; do
        print_role_grant_command "$kind" "$resource" "$role"
      done < "$ROLE_GRANTS_FILE"
    fi
    printf '\nNothing has been changed yet. IAM changes can take a few minutes to apply.\n'
  } >&2
}

# Succeeds when every missing permission maps to a role on a project whose IAM
# policy the operator may change, so a self-grant would unblock the setup.
self_grant_possible() {
  local kind resource permission
  [[ -n "$OPERATOR_MEMBER" && -s "$MISSING_PERMISSIONS_FILE" ]] || return 1
  while read -r kind resource permission; do
    [[ "$kind" == "project" ]] || return 1
    role_for_permission "$permission" >/dev/null || return 1
    grep -Fqx -- "$resource" "$SELF_GRANT_PROJECTS_FILE" || return 1
  done < "$MISSING_PERMISSIONS_FILE"
}

offer_operator_self_grant() {
  local grants=() grant kind resource role
  self_grant_possible || return 1
  mapfile -t grants < "$ROLE_GRANTS_FILE"
  {
    printf '\n%s already holds resourcemanager.projects.setIamPolicy on every project\n' \
      "$ACTIVE_ACCOUNT"
    printf 'above, so this setup can grant those roles to %s now.\n' "$OPERATOR_MEMBER"
    printf 'This is a separate IAM change, made before the main approval. The cleanup\n'
    printf 'plan prints the commands that revoke it.\n'
  } >&2
  if ! confirm_default_no "Grant these roles to yourself now?"; then
    log "No roles were granted."
    return 1
  fi
  # Called as a condition, so errexit is off here: fail explicitly.
  for grant in "${grants[@]}"; do
    read -r kind resource role <<< "$grant"
    OPERATOR_GRANTS+=("${resource} ${role}")
    log "Granting ${role} on project ${resource} to ${OPERATOR_MEMBER}"
    gcloud_billed_to_target cloudresourcemanager.googleapis.com \
      projects add-iam-policy-binding "$resource" \
      --member="$OPERATOR_MEMBER" --role="$role" --condition=None --quiet \
      >/dev/null < /dev/null ||
      fail "Could not grant ${role} on project ${resource}"
  done
}

# Re-tests with bounded waits, because IAM changes take time to propagate.
wait_for_operator_permissions() {
  local delay
  for delay in 10 20 30 30 30; do
    log "Waiting ${delay}s for the new roles to take effect..."
    sleep "$delay"
    run_permission_preflight
    if [[ ! -s "$MISSING_PERMISSIONS_FILE" ]]; then
      log "The new roles are in effect."
      return
    fi
  done
  report_missing_permissions
  fail "The granted roles are not in effect yet; IAM can take up to 7 minutes. Re-run ./setup.sh shortly"
}

print_operator_grant_summary() {
  local grant
  [[ "${#OPERATOR_GRANTS[@]}" -gt 0 ]] || return 0
  printf '  roles granted to you earlier in this run:\n'
  for grant in "${OPERATOR_GRANTS[@]}"; do
    printf '    %s on project %s\n' "${grant#* }" "${grant%% *}"
  done
}

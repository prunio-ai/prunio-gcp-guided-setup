#!/usr/bin/env bash

ensure_gcloud_authentication() {
  ACTIVE_ACCOUNT="$(
    gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null |
      head -n 1
  )"
  if [[ -z "$ACTIVE_ACCOUNT" ]]; then
    local answer
    log "This temporary Cloud Shell has no active Google identity."
    printf 'Run gcloud auth login now? [y/N]: ' >&2
    IFS= read -r answer || fail "Authentication prompt was interrupted"
    [[ "$answer" =~ ^[Yy]$ ]] || fail "Google authentication is required"
    gcloud auth login --brief
    ACTIVE_ACCOUNT="$(
      gcloud auth list --filter='status:ACTIVE' --format='value(account)' |
        head -n 1
    )"
  fi
  [[ -n "$ACTIVE_ACCOUNT" ]] || fail "No active Google identity was found"
  log "Authenticated as ${ACTIVE_ACCOUNT}"
}

collect_customer_inputs() {
  select_target_project
  require_match "target project ID" "$TARGET_PROJECT_ID" "$PROJECT_ID_PATTERN"
  inspect_target_quota_project

  TARGET_PROJECT_NUMBER="$(
    gcloud_billed_to_target cloudresourcemanager.googleapis.com \
      projects describe "$TARGET_PROJECT_ID" --format='value(projectNumber)'
  )" || fail "Target project could not be read"
  require_match "target project number" "$TARGET_PROJECT_NUMBER" \
    '^[1-9][0-9]{5,19}$'
  derive_billing_account
  set_project_derived_names

  prompt_with_default BILLING_SOURCE_PROJECT_ID \
    "Project hosting the detailed billing export" "$TARGET_PROJECT_ID"
  require_match "billing source project ID" "$BILLING_SOURCE_PROJECT_ID" \
    "$PROJECT_ID_PATTERN"
  select_billing_export_dataset
  require_match "billing source dataset ID" "$BILLING_SOURCE_DATASET_ID" \
    "$DATASET_ID_PATTERN"
  [[ "${#BILLING_SOURCE_DATASET_ID}" -le 1024 ]] ||
    fail "Invalid billing source dataset ID"
  prompt_with_default BILLING_QUERY_PROJECT_ID \
    "Project used for Prunio billing queries" "$TARGET_PROJECT_ID"
  require_match "billing query project ID" "$BILLING_QUERY_PROJECT_ID" \
    "$PROJECT_ID_PATTERN"
}

# test_google_permissions ENDPOINT LABEL QUOTA_SERVICE GRANTED_FILE PERMISSION...
# Writes the permissions the operator holds to GRANTED_FILE.
test_google_permissions() {
  local endpoint="$1"
  local resource_label="$2"
  local quota_service="$3"
  local granted_file="$4"
  shift 4
  local request_file="${RUNTIME_DIR}/permission-request.json"
  local response_file="${RUNTIME_DIR}/permission-response.json"
  local http_status

  printf '%s\n' "$@" | jq -R . | jq -s '{permissions: unique}' > "$request_file"
  http_status="$(google_api_request POST "$endpoint" "$response_file" \
    "$(quota_project_for "$quota_service")" "$request_file")" ||
    fail "Could not test operator permissions on ${resource_label}"
  [[ "$http_status" == "200" ]] ||
    fail "Permission test was rejected for ${resource_label} (HTTP ${http_status}); check that ${ACTIVE_ACCOUNT} can open it"
  # Google omits an empty permissions list, so a missing key means none held.
  jq -e '(.permissions // []) | type == "array"' "$response_file" >/dev/null ||
    fail "Permission test returned an invalid response"
  # No blank line: as a grep -f pattern it would match every permission.
  jq -r '(.permissions // [])[] | strings | select(length > 0)' \
    "$response_file" > "$granted_file"
}

# check_project_permissions PROJECT PERMISSION...: records each permission the
# operator lacks, and whether the operator may change the project's IAM policy.
check_project_permissions() {
  local project_id="$1"
  shift
  local granted_file="${RUNTIME_DIR}/granted-${project_id}.txt"
  local missing permission
  test_google_permissions \
    "https://cloudresourcemanager.googleapis.com/v3/projects/${project_id}:testIamPermissions" \
    "project ${project_id}" cloudresourcemanager.googleapis.com \
    "$granted_file" resourcemanager.projects.setIamPolicy "$@"
  if grep -Fqx resourcemanager.projects.setIamPolicy "$granted_file"; then
    printf '%s\n' "$project_id" >> "$SELF_GRANT_PROJECTS_FILE"
  fi
  missing="$(printf '%s\n' "$@" | grep -vxF -f "$granted_file" || true)"
  while IFS= read -r permission; do
    [[ -z "$permission" ]] ||
      printf 'project %s %s\n' "$project_id" "$permission" >> "$MISSING_PERMISSIONS_FILE"
  done <<< "$missing"
}

check_billing_permissions() {
  local granted_file="${RUNTIME_DIR}/granted-billing.txt"
  test_google_permissions \
    "https://cloudbilling.googleapis.com/v1/billingAccounts/${BILLING_ACCOUNT_ID}:testIamPermissions" \
    "billing account ${BILLING_ACCOUNT_ID}" cloudbilling.googleapis.com \
    "$granted_file" billing.accounts.get
  grep -Fqx billing.accounts.get "$granted_file" ||
    printf 'billing %s %s\n' "$BILLING_ACCOUNT_ID" billing.accounts.get >> "$MISSING_PERMISSIONS_FILE"
}

run_permission_preflight() {
  local target_permissions=(
    resourcemanager.projects.get
    resourcemanager.projects.getIamPolicy
    resourcemanager.projects.setIamPolicy
    serviceusage.services.enable
    serviceusage.services.use
    iam.workloadIdentityPools.create
    iam.workloadIdentityPools.get
    iam.workloadIdentityPools.list
    iam.workloadIdentityPools.undelete
    iam.workloadIdentityPools.update
    iam.workloadIdentityPoolProviders.create
    iam.workloadIdentityPoolProviders.get
    iam.workloadIdentityPoolProviders.list
    iam.workloadIdentityPoolProviders.undelete
    iam.workloadIdentityPoolProviders.update
    iam.serviceAccounts.create
    iam.serviceAccounts.get
    iam.serviceAccounts.getIamPolicy
    iam.serviceAccounts.setIamPolicy
    iam.roles.create
    iam.roles.get
    iam.roles.list
    iam.roles.undelete
    iam.roles.update
  )
  local query_project_permissions=(
    resourcemanager.projects.get
    resourcemanager.projects.getIamPolicy
    resourcemanager.projects.setIamPolicy
    serviceusage.services.enable
    iam.roles.create
    iam.roles.get
    iam.roles.list
    iam.roles.undelete
    iam.roles.update
    bigquery.datasets.create
    bigquery.datasets.get
    bigquery.datasets.update
    bigquery.tables.create
    bigquery.tables.get
    bigquery.tables.getIamPolicy
    bigquery.tables.setIamPolicy
    bigquery.tables.update
  )
  local source_project_permissions=(
    resourcemanager.projects.get
    bigquery.datasets.get
    bigquery.datasets.getIamPolicy
    bigquery.datasets.setIamPolicy
    bigquery.datasets.update
    bigquery.tables.get
    bigquery.tables.getData
    bigquery.tables.getIamPolicy
    bigquery.tables.setIamPolicy
  )
  MISSING_PERMISSIONS_FILE="${RUNTIME_DIR}/missing-permissions.txt"
  SELF_GRANT_PROJECTS_FILE="${RUNTIME_DIR}/self-grant-projects.txt"
  : > "$MISSING_PERMISSIONS_FILE"
  : > "$SELF_GRANT_PROJECTS_FILE"
  load_access_token
  check_project_permissions "$TARGET_PROJECT_ID" "${target_permissions[@]}"
  check_project_permissions "$BILLING_QUERY_PROJECT_ID" \
    "${query_project_permissions[@]}"
  check_project_permissions "$BILLING_SOURCE_PROJECT_ID" \
    "${source_project_permissions[@]}"
  check_billing_permissions
  forget_access_token
}

verify_operator_prerequisites() {
  set_operator_member
  run_permission_preflight
  [[ -s "$MISSING_PERMISSIONS_FILE" ]] || return 0
  report_missing_permissions
  offer_operator_self_grant || fail "Operator prerequisites are incomplete"
  wait_for_operator_permissions
}

show_change_summary() {
  log "Review the exact target before approval:"
  printf '  project: %s (%s)\n' "$TARGET_PROJECT_ID" "$TARGET_PROJECT_NUMBER"
  printf '  billing account: %s\n' "$BILLING_ACCOUNT_ID"
  printf '  WIF pool: %s\n' "$WORKLOAD_IDENTITY_POOL_ID"
  printf '  WIF provider: %s\n' "$WORKLOAD_IDENTITY_PROVIDER_ID"
  printf '  connector service account: %s\n' "$CONNECTOR_SERVICE_ACCOUNT_EMAIL"
  printf '  exact federated principal: %s\n' "$WIF_PRINCIPAL"
  printf '  posture: %s\n' "$POSTURE"
  printf '  billing source: %s:%s.%s\n' \
    "$BILLING_SOURCE_PROJECT_ID" "$BILLING_SOURCE_DATASET_ID" \
    "$RAW_BILLING_EXPORT_TABLE_ID"
  printf '  scoped billing view: %s:%s.%s\n' \
    "$BILLING_QUERY_PROJECT_ID" "$BILLING_VIEW_DATASET_ID" \
    "$BILLING_SCOPED_VIEW_ID"
  print_operator_grant_summary
}

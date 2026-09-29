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
  local configured_project
  configured_project="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "$configured_project" != "(unset)" ]] || configured_project=""
  if [[ -n "$configured_project" ]]; then
    prompt_with_default TARGET_PROJECT_ID \
      "Connected GCP project ID" "$configured_project"
  else
    prompt_required TARGET_PROJECT_ID "Connected GCP project ID"
  fi
  require_match "target project ID" "$TARGET_PROJECT_ID" \
    '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'

  prompt_required BILLING_ACCOUNT_ID "Billing account ID (XXXXXX-XXXXXX-XXXXXX)"
  require_match "billing account ID" "$BILLING_ACCOUNT_ID" \
    '^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$'
  prompt_with_default BILLING_SOURCE_PROJECT_ID \
    "Project hosting the detailed billing export" "$TARGET_PROJECT_ID"
  require_match "billing source project ID" "$BILLING_SOURCE_PROJECT_ID" \
    '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'
  prompt_required BILLING_SOURCE_DATASET_ID \
    "Dataset containing the detailed billing export"
  require_match "billing source dataset ID" "$BILLING_SOURCE_DATASET_ID" \
    '^[A-Za-z_][A-Za-z0-9_]*$'
  [[ "${#BILLING_SOURCE_DATASET_ID}" -le 1024 ]] ||
    fail "Invalid billing source dataset ID"
  prompt_with_default BILLING_QUERY_PROJECT_ID \
    "Project used for Prunio billing queries" "$TARGET_PROJECT_ID"
  require_match "billing query project ID" "$BILLING_QUERY_PROJECT_ID" \
    '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'

  TARGET_PROJECT_NUMBER="$(
    gcloud projects describe "$TARGET_PROJECT_ID" \
      --format='value(projectNumber)'
  )" || fail "Target project could not be read"
  require_match "target project number" "$TARGET_PROJECT_NUMBER" \
    '^[1-9][0-9]{5,19}$'
  set_project_derived_names
}

test_project_operator_permissions() {
  local project_id="$1"
  shift
  test_google_permissions \
    "https://cloudresourcemanager.googleapis.com/v3/projects/${project_id}:testIamPermissions" \
    "project ${project_id}" "$@"
}

test_billing_operator_permissions() {
  test_google_permissions \
    "https://cloudbilling.googleapis.com/v1/billingAccounts/${BILLING_ACCOUNT_ID}:testIamPermissions" \
    "billing account ${BILLING_ACCOUNT_ID}" \
    billing.accounts.get
}

test_google_permissions() {
  local endpoint="$1"
  local resource_label="$2"
  shift 2
  local request_file="${RUNTIME_DIR}/permission-request.json"
  local response_file="${RUNTIME_DIR}/permission-response.json"
  local access_token http_status granted permission missing=0

  printf '%s\n' "$@" | jq -R . | jq -s '{permissions: .}' > "$request_file"
  access_token="$(gcloud auth print-access-token 2>/dev/null)" ||
    fail "Could not obtain a temporary operator access token"
  http_status="$({
    printf 'header = "Authorization: Bearer %s"\n' "$access_token"
    printf 'header = "Content-Type: application/json"\n'
  } | curl --config - --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 5 --max-time 20 --max-filesize 65536 \
    --request POST --data-binary "@${request_file}" \
    --output "$response_file" --write-out '%{http_code}' "$endpoint")" ||
    fail "Could not test operator permissions on ${resource_label}"
  unset access_token
  [[ "$http_status" == "200" ]] ||
    fail "Permission test was rejected for ${resource_label}"
  jq -e '.permissions | type == "array"' "$response_file" >/dev/null ||
    fail "Permission test returned an invalid response"
  granted="$(jq -r '.permissions[]' "$response_file")"
  for permission in "$@"; do
    if ! grep -Fqx "$permission" <<< "$granted"; then
      printf '  missing: %s on %s\n' "$permission" "$resource_label" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || fail "Operator prerequisites are incomplete"
}

verify_operator_prerequisites() {
  local target_permissions=(
    resourcemanager.projects.get
    resourcemanager.projects.getIamPolicy
    resourcemanager.projects.setIamPolicy
    serviceusage.services.enable
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
  test_project_operator_permissions "$TARGET_PROJECT_ID" \
    "${target_permissions[@]}"
  test_project_operator_permissions "$BILLING_QUERY_PROJECT_ID" \
    "${query_project_permissions[@]}"
  test_project_operator_permissions "$BILLING_SOURCE_PROJECT_ID" \
    "${source_project_permissions[@]}"
  test_billing_operator_permissions
}

show_change_summary() {
  log "Review the exact target before approval:"
  printf '  project: %s (%s)\n' "$TARGET_PROJECT_ID" "$TARGET_PROJECT_NUMBER"
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
}

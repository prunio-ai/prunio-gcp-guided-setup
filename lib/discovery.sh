#!/usr/bin/env bash

# Read-only discovery that replaces typing IDs. Every discovered value passes
# the same validation as a typed one before it is used.

PROJECT_ID_PATTERN='^[a-z][a-z0-9-]{4,28}[a-z0-9]$'
BILLING_ACCOUNT_ID_PATTERN='^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$'
DATASET_ID_PATTERN='^[A-Za-z_][A-Za-z0-9_]*$'
DISCOVERY_LIMIT=50
DISCOVERED_PROJECTS=()
DISCOVERED_ACCOUNTS=()
DISCOVERY_TRUNCATED=0
DISCOVERY_SCANNED=0

configured_gcloud_project() {
  local project
  project="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "$project" != "(unset)" ]] || project=""
  printf '%s' "$project"
}

# Prints the billing account linked to project $1. Returns 1 when billing is
# disabled on the project and 2 when its billing info cannot be read.
project_billing_account() {
  local project_id="$1"
  local response="${RUNTIME_DIR}/billing-info.json"
  local http_status account
  http_status="$(google_api_request GET \
    "https://cloudbilling.googleapis.com/v1/projects/${project_id}/billingInfo" \
    "$response")" || return 2
  [[ "$http_status" == "200" ]] || return 2
  jq -e 'type == "object"' "$response" >/dev/null 2>&1 || return 2
  jq -e '.billingEnabled == true' "$response" >/dev/null || return 1
  account="$(jq -r '.billingAccountName // ""' "$response")"
  account="${account#billingAccounts/}"
  [[ "$account" =~ $BILLING_ACCOUNT_ID_PATTERN ]] || return 2
  printf '%s' "$account"
}

# Lists up to DISCOVERY_LIMIT projects the operator can see and keeps those
# with billing enabled. Returns 1 when the projects cannot be listed.
discover_billing_projects() {
  local listed project_id account
  DISCOVERED_PROJECTS=()
  DISCOVERED_ACCOUNTS=()
  DISCOVERY_TRUNCATED=0
  DISCOVERY_SCANNED=0
  listed="$(gcloud projects list --limit="$((DISCOVERY_LIMIT + 1))" \
    --format='value(projectId)' 2>/dev/null)" || return 1
  log "Checking which of your projects have billing enabled..."
  load_access_token
  while IFS= read -r project_id; do
    [[ -n "$project_id" ]] || continue
    if ((DISCOVERY_SCANNED == DISCOVERY_LIMIT)); then
      DISCOVERY_TRUNCATED=1
      break
    fi
    DISCOVERY_SCANNED=$((DISCOVERY_SCANNED + 1))
    [[ "$project_id" =~ $PROJECT_ID_PATTERN ]] || continue
    if account="$(project_billing_account "$project_id")"; then
      DISCOVERED_PROJECTS+=("$project_id")
      DISCOVERED_ACCOUNTS+=("$account")
    fi
  done <<< "$listed"
  forget_access_token
}

prompt_target_project_id() {
  local configured_project="$1"
  if [[ -n "$configured_project" ]]; then
    prompt_with_default TARGET_PROJECT_ID \
      "Connected GCP project ID" "$configured_project"
  else
    prompt_required TARGET_PROJECT_ID "Connected GCP project ID"
  fi
}

select_target_project() {
  local configured_project default_index="" index
  configured_project="$(configured_gcloud_project)"
  if ! discover_billing_projects; then
    log "Your projects could not be listed; type the project ID instead."
    prompt_target_project_id "$configured_project"
    return
  fi
  if [[ "${#DISCOVERED_PROJECTS[@]}" -eq 0 ]]; then
    log "None of the ${DISCOVERY_SCANNED} projects ${ACTIVE_ACCOUNT} can see has billing enabled."
    prompt_target_project_id "$configured_project"
    return
  fi
  if [[ "${#DISCOVERED_PROJECTS[@]}" -eq 1 && "$DISCOVERY_TRUNCATED" -eq 0 ]]; then
    TARGET_PROJECT_ID="${DISCOVERED_PROJECTS[0]}"
    log "Using ${TARGET_PROJECT_ID}, the only project with billing enabled that ${ACTIVE_ACCOUNT} can see."
    return
  fi
  for index in "${!DISCOVERED_PROJECTS[@]}"; do
    [[ "${DISCOVERED_PROJECTS[$index]}" != "$configured_project" ]] ||
      default_index=$((index + 1))
  done
  log "Projects with billing enabled that ${ACTIVE_ACCOUNT} can see:"
  [[ "$DISCOVERY_TRUNCATED" -eq 0 ]] ||
    log "(Only the first ${DISCOVERY_LIMIT} projects were checked; you can type any other project ID.)"
  prompt_choice TARGET_PROJECT_ID "Project to connect (number or project ID)" \
    "$default_index" "$PROJECT_ID_PATTERN" "${DISCOVERED_PROJECTS[@]}"
}

derive_billing_account() {
  local index status=0
  BILLING_ACCOUNT_ID=""
  for index in "${!DISCOVERED_PROJECTS[@]}"; do
    [[ "${DISCOVERED_PROJECTS[$index]}" != "$TARGET_PROJECT_ID" ]] ||
      BILLING_ACCOUNT_ID="${DISCOVERED_ACCOUNTS[$index]}"
  done
  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    load_access_token
    BILLING_ACCOUNT_ID="$(project_billing_account "$TARGET_PROJECT_ID")" ||
      status=$?
    forget_access_token
  fi
  case "$status" in
    0)
      log "Billing account linked to ${TARGET_PROJECT_ID}: ${BILLING_ACCOUNT_ID}"
      ;;
    1)
      {
        printf '\nBilling is not enabled on project %s. Nothing has been changed.\n' \
          "$TARGET_PROJECT_ID"
        printf 'Link a billing account at\n'
        printf '  https://console.cloud.google.com/billing/linkedaccount?project=%s\n' \
          "$TARGET_PROJECT_ID"
        printf 'then re-run ./setup.sh.\n'
      } >&2
      fail "Billing is not enabled on the target project"
      ;;
    *)
      log "The billing account of ${TARGET_PROJECT_ID} could not be read; type it instead."
      prompt_required BILLING_ACCOUNT_ID \
        "Billing account ID (XXXXXX-XXXXXX-XXXXXX)"
      ;;
  esac
  require_match "billing account ID" "$BILLING_ACCOUNT_ID" \
    "$BILLING_ACCOUNT_ID_PATTERN"
}

# print_billing_export_guidance REASON [DATASET]: DATASET defaults to the name
# suggested for a new export dataset.
print_billing_export_guidance() {
  local reason="$1"
  local dataset="${2:-billing_export}"
  local project="$BILLING_SOURCE_PROJECT_ID"
  {
    printf '\n%s\n' "$reason"
    printf 'Prunio reads the Cloud Billing "Detailed usage cost" export of billing account %s,\n' \
      "$BILLING_ACCOUNT_ID"
    printf 'table %s in a dataset of project %s.\n' \
      "$RAW_BILLING_EXPORT_TABLE_ID" "$project"
    printf 'Nothing has been changed in your Google Cloud projects. To fix this:\n'
    printf '  1. Create a dataset for the export, unless you already have one:\n'
    printf '       bq mk --dataset --location=US %s:%s\n' "$project" "$dataset"
    printf '     (A US or EU multi-region dataset also receives recent history.)\n'
    printf '  2. Open https://console.cloud.google.com/billing/%s/export\n' \
      "$BILLING_ACCOUNT_ID"
    printf '     (Billing > Billing export > BigQuery export > Detailed usage cost),\n'
    printf '     choose Edit settings, select project %s and that dataset, then Save.\n' \
      "$project"
    printf '     This needs the Billing Account Administrator or Billing Account Costs\n'
    printf '     Manager role on the billing account. The "Standard usage cost" export\n'
    printf '     (gcp_billing_export_v1_...) is not enough.\n'
    printf '  3. Google creates and fills the table over the next few hours. Re-run\n'
    printf '     ./setup.sh once %s appears in:\n' "$RAW_BILLING_EXPORT_TABLE_ID"
    printf '       bq ls %s:%s\n' "$project" "$dataset"
  } >&2
}

# Prints present, absent or unknown for the export table in one dataset.
billing_export_table_state() {
  local project="$1"
  local dataset="$2"
  local quota_project="$3"
  local table="$RAW_BILLING_EXPORT_TABLE_ID"
  local table_file="${RUNTIME_DIR}/candidate-table.json"
  local http_status
  http_status="$(google_api_request GET \
    "https://bigquery.googleapis.com/bigquery/v2/projects/${project}/datasets/${dataset}/tables/${table}?fields=type,tableReference" \
    "$table_file" "$quota_project")" || {
    printf 'unknown'
    return
  }
  case "$http_status" in
    200)
      if jq -e --arg project "$project" --arg dataset "$dataset" \
        --arg table "$table" '
          .tableReference.projectId == $project and
          .tableReference.datasetId == $dataset and
          .tableReference.tableId == $table and
          (.type == "TABLE" or .type == "EXTERNAL")
        ' "$table_file" >/dev/null 2>&1; then
        printf 'present'
      else
        printf 'absent'
      fi
      ;;
    404) printf 'absent' ;;
    *) printf 'unknown' ;;
  esac
}

# Finds the dataset of BILLING_SOURCE_PROJECT_ID holding the detailed export.
# Stops before any change when every dataset was checked and none has it.
select_billing_export_dataset() {
  local project="$BILLING_SOURCE_PROJECT_ID"
  local list_file="${RUNTIME_DIR}/datasets.json"
  local quota_project http_status dataset
  local datasets=() found=()
  local inconclusive=0
  quota_project="$(quota_project_for bigquery.googleapis.com)"
  log "Looking for ${RAW_BILLING_EXPORT_TABLE_ID} in the datasets of ${project}..."
  load_access_token
  http_status="$(google_api_request GET \
    "https://bigquery.googleapis.com/bigquery/v2/projects/${project}/datasets?maxResults=${DISCOVERY_LIMIT}" \
    "$list_file" "$quota_project")" || http_status=""
  if [[ "$http_status" != "200" ]] ||
    ! jq -e '(.datasets // []) | type == "array"' "$list_file" >/dev/null 2>&1; then
    forget_access_token
    log "The datasets of ${project} could not be listed; type the dataset ID instead."
    prompt_required BILLING_SOURCE_DATASET_ID \
      "Dataset containing the detailed billing export"
    return
  fi
  if jq -e 'has("nextPageToken")' "$list_file" >/dev/null; then
    inconclusive=1
  fi
  mapfile -t datasets < <(
    jq -r '(.datasets // [])[].datasetReference.datasetId // empty' "$list_file"
  )
  for dataset in ${datasets[@]+"${datasets[@]}"}; do
    [[ "$dataset" =~ $DATASET_ID_PATTERN ]] || continue
    case "$(billing_export_table_state "$project" "$dataset" "$quota_project")" in
      present) found+=("$dataset") ;;
      absent) ;;
      *) inconclusive=1 ;;
    esac
  done
  forget_access_token

  case "${#found[@]}" in
    0)
      if [[ "$inconclusive" -eq 1 ]]; then
        log "Not every dataset of ${project} could be checked; type the dataset ID instead."
        prompt_required BILLING_SOURCE_DATASET_ID \
          "Dataset containing the detailed billing export"
        return
      fi
      print_billing_export_guidance \
        "No dataset in project ${project} contains the detailed billing export yet."
      fail "Detailed billing export table was not found"
      ;;
    1)
      log "Found the detailed billing export in ${project}:${found[0]}."
      prompt_with_default BILLING_SOURCE_DATASET_ID \
        "Dataset containing the detailed billing export" "${found[0]}"
      ;;
    *)
      log "Several datasets of ${project} contain ${RAW_BILLING_EXPORT_TABLE_ID}:"
      prompt_choice BILLING_SOURCE_DATASET_ID \
        "Dataset containing the detailed billing export (number or dataset ID)" \
        "" "$DATASET_ID_PATTERN" "${found[@]}"
      ;;
  esac
}

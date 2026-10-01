#!/usr/bin/env bash

inspect_billing_export() {
  local dataset_file="${RUNTIME_DIR}/source-dataset.json"
  local table_file="${RUNTIME_DIR}/source-table.json"
  if ! bq show --format=prettyjson --dataset_view=METADATA \
    "${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}" \
    > "$dataset_file" 2>/dev/null; then
    print_billing_export_guidance \
      "Dataset ${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID} does not exist or cannot be read." \
      "$BILLING_SOURCE_DATASET_ID"
    fail "Detailed billing export dataset is unavailable"
  fi
  BILLING_DATASET_LOCATION="$(jq -r '.location // empty' "$dataset_file")"
  [[ -n "$BILLING_DATASET_LOCATION" ]] ||
    fail "Billing export dataset has no location"
  if ! bq show --format=prettyjson \
    "${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}.${RAW_BILLING_EXPORT_TABLE_ID}" \
    > "$table_file" 2>/dev/null; then
    print_billing_export_guidance \
      "Dataset ${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID} has no ${RAW_BILLING_EXPORT_TABLE_ID} table yet." \
      "$BILLING_SOURCE_DATASET_ID"
    fail "Detailed resource-level billing export is not available or is still warming"
  fi
  jq -e --arg project "$BILLING_SOURCE_PROJECT_ID" \
    --arg dataset "$BILLING_SOURCE_DATASET_ID" \
    --arg table "$RAW_BILLING_EXPORT_TABLE_ID" '
      .tableReference.projectId == $project and
      .tableReference.datasetId == $dataset and
      .tableReference.tableId == $table and
      (.type == "TABLE" or .type == "EXTERNAL")
    ' "$table_file" >/dev/null || fail "Billing export table metadata is invalid"
}

ensure_billing_view_dataset() {
  local dataset_ref="${BILLING_QUERY_PROJECT_ID}:${BILLING_VIEW_DATASET_ID}"
  local dataset_file="${RUNTIME_DIR}/view-dataset.json"
  if ! bq show --format=prettyjson --dataset_view=METADATA "$dataset_ref" \
    > "$dataset_file" 2>/dev/null; then
    bq mk --dataset --location="$BILLING_DATASET_LOCATION" \
      --description="Prunio project-isolated billing views; binding ${CONNECTION_BINDING_ID}" \
      "$dataset_ref" >/dev/null
    bq show --format=prettyjson --dataset_view=METADATA "$dataset_ref" \
      > "$dataset_file"
  fi
  [[ "$(jq -r '.location // empty' "$dataset_file")" == \
    "$BILLING_DATASET_LOCATION" ]] ||
    fail "Billing view dataset location differs from the export dataset"
}

build_billing_view_query() {
  cat <<SQL
SELECT
  billing_account_id,
  service,
  sku,
  usage_start_time,
  usage_end_time,
  export_time,
  project,
  resource,
  cost,
  currency,
  currency_conversion_rate,
  usage,
  credits,
  invoice,
  cost_type,
  adjustment_info,
  labels,
  system_labels,
  tags
FROM \`${BILLING_SOURCE_PROJECT_ID}.${BILLING_SOURCE_DATASET_ID}.${RAW_BILLING_EXPORT_TABLE_ID}\`
WHERE project.id = '${TARGET_PROJECT_ID}'
SQL
}

ensure_scoped_billing_view() {
  local view_ref=
  local view_file="${RUNTIME_DIR}/existing-scoped-view.json"
  view_ref="${BILLING_QUERY_PROJECT_ID}:${BILLING_VIEW_DATASET_ID}.${BILLING_SCOPED_VIEW_ID}"
  BILLING_VIEW_QUERY="$(build_billing_view_query)"
  BILLING_VIEW_CHANGED=0
  if bq show --format=prettyjson "$view_ref" > "$view_file" 2>/dev/null; then
    jq -e '.type == "VIEW"' "$view_file" >/dev/null ||
      fail "The reserved scoped billing view name is occupied by a non-view resource"
    if jq -e --arg query "$BILLING_VIEW_QUERY" \
      --arg location "$BILLING_DATASET_LOCATION" '
        .view.useLegacySql == false and
        .view.query == $query and
        .location == $location
      ' "$view_file" >/dev/null; then
      return
    fi
    bq update --use_legacy_sql=false --view="$BILLING_VIEW_QUERY" \
      "$view_ref" >/dev/null
  else
    bq mk --use_legacy_sql=false --view="$BILLING_VIEW_QUERY" \
      "$view_ref" >/dev/null
  fi
  BILLING_VIEW_CHANGED=1
}

authorize_scoped_billing_view() {
  local source_ref="${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}"
  local source_file="${RUNTIME_DIR}/source-dataset-full.json"
  local updated_file="${RUNTIME_DIR}/source-dataset-authorized.json"
  bq show --format=prettyjson --dataset_view=FULL "$source_ref" > "$source_file"
  jq --arg project "$BILLING_QUERY_PROJECT_ID" \
    --arg dataset "$BILLING_VIEW_DATASET_ID" \
    --arg table "$BILLING_SCOPED_VIEW_ID" '
      .access = (.access // []) |
      if any(.access[]?;
        .view.projectId == $project and
        .view.datasetId == $dataset and
        .view.tableId == $table)
      then .
      else .access += [{view: {
        projectId: $project,
        datasetId: $dataset,
        tableId: $table
      }}]
      end
    ' "$source_file" > "$updated_file"
  if [[ "$BILLING_VIEW_CHANGED" -eq 1 ]] ||
    ! cmp -s "$source_file" "$updated_file"; then
    bq update --update_mode=UPDATE_FULL --source "$updated_file" \
      "$source_ref" >/dev/null
  fi
}

grant_billing_resource_access() {
  local member="serviceAccount:${CONNECTOR_SERVICE_ACCOUNT_EMAIL}"
  local source_table=
  local scoped_view=
  source_table="${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}.${RAW_BILLING_EXPORT_TABLE_ID}"
  scoped_view="${BILLING_QUERY_PROJECT_ID}:${BILLING_VIEW_DATASET_ID}.${BILLING_SCOPED_VIEW_ID}"
  bq add-iam-policy-binding --table=true --member="$member" \
    --role=roles/bigquery.metadataViewer "$source_table" >/dev/null
  bq add-iam-policy-binding --table=true --member="$member" \
    --role=roles/bigquery.dataViewer "$scoped_view" >/dev/null
}

verify_scoped_billing_view() {
  local view_file="${RUNTIME_DIR}/scoped-view.json"
  local view_ref=
  view_ref="${BILLING_QUERY_PROJECT_ID}:${BILLING_VIEW_DATASET_ID}.${BILLING_SCOPED_VIEW_ID}"
  bq show --format=prettyjson "$view_ref" > "$view_file"
  jq -e --arg query "$BILLING_VIEW_QUERY" \
    --arg location "$BILLING_DATASET_LOCATION" '
      .type == "VIEW" and .view.useLegacySql == false and
      .view.query == $query and .location == $location
    ' "$view_file" >/dev/null || fail "Scoped billing view drifted"
}

provision_billing_surface() {
  ensure_billing_view_dataset
  ensure_scoped_billing_view
  authorize_scoped_billing_view
  grant_billing_resource_access
  verify_scoped_billing_view
}

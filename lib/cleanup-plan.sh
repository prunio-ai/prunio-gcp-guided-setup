#!/usr/bin/env bash

print_cleanup_plan() {
  local member="serviceAccount:${CONNECTOR_SERVICE_ACCOUNT_EMAIL}"
  local source_table=
  local scoped_view=
  source_table="${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}.${RAW_BILLING_EXPORT_TABLE_ID}"
  scoped_view="${BILLING_QUERY_PROJECT_ID}:${BILLING_VIEW_DATASET_ID}.${BILLING_SCOPED_VIEW_ID}"

  printf '\nCleanup plan (DO NOT RUN while this connection is active):\n'
  printf 'Wait until Prunio shows cleanup-pending for this exact binding.\n'
  printf 'Then review and run each command manually:\n\n'
  printf 'gcloud iam service-accounts remove-iam-policy-binding %q --project=%q --member=%q --role=%q --condition=None\n' \
    "$CONNECTOR_SERVICE_ACCOUNT_EMAIL" "$TARGET_PROJECT_ID" "$WIF_PRINCIPAL" \
    roles/iam.workloadIdentityUser
  printf 'gcloud iam workload-identity-pools providers delete %q --workload-identity-pool=%q --location=global --project=%q\n' \
    "$WORKLOAD_IDENTITY_PROVIDER_ID" "$WORKLOAD_IDENTITY_POOL_ID" \
    "$TARGET_PROJECT_ID"
  printf 'bq remove-iam-policy-binding --table=true --member=%q --role=roles/bigquery.metadataViewer %q\n' \
    "$member" "$source_table"
  printf 'bq remove-iam-policy-binding --table=true --member=%q --role=roles/bigquery.dataViewer %q\n' \
    "$member" "$scoped_view"
  printf 'PRUNIO_SOURCE_DATASET_FILE="$(mktemp)"\n'
  printf 'PRUNIO_UPDATED_DATASET_FILE="$(mktemp)"\n'
  printf 'bq show --format=prettyjson --dataset_view=FULL %q > "$PRUNIO_SOURCE_DATASET_FILE"\n' \
    "${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}"
  printf 'jq --arg project %q --arg dataset %q --arg table %q '\''.access = [(.access // [])[] | select((.view.projectId == $project and .view.datasetId == $dataset and .view.tableId == $table) | not)]'\'' "$PRUNIO_SOURCE_DATASET_FILE" > "$PRUNIO_UPDATED_DATASET_FILE"\n' \
    "$BILLING_QUERY_PROJECT_ID" "$BILLING_VIEW_DATASET_ID" \
    "$BILLING_SCOPED_VIEW_ID"
  printf 'if ! cmp -s "$PRUNIO_SOURCE_DATASET_FILE" "$PRUNIO_UPDATED_DATASET_FILE"; then bq update --update_mode=UPDATE_FULL --source "$PRUNIO_UPDATED_DATASET_FILE" %q; fi\n' \
    "${BILLING_SOURCE_PROJECT_ID}:${BILLING_SOURCE_DATASET_ID}"
  printf 'rm -f "$PRUNIO_SOURCE_DATASET_FILE" "$PRUNIO_UPDATED_DATASET_FILE"\n'
  printf 'bq rm --table --force %q\n' "$scoped_view"
  printf 'gcloud projects remove-iam-policy-binding %q --member=%q --role=%q --condition=None\n' \
    "$TARGET_PROJECT_ID" "$member" \
    "projects/${TARGET_PROJECT_ID}/roles/${CONNECTOR_READ_ROLE_ID}"
  if [[ "$POSTURE" == "read_scoped_optimize" ]]; then
    printf 'gcloud projects remove-iam-policy-binding %q --member=%q --role=%q --condition=None\n' \
      "$TARGET_PROJECT_ID" "$member" \
      "projects/${TARGET_PROJECT_ID}/roles/${CONNECTOR_OPTIMIZE_ROLE_ID}"
  fi
  printf 'gcloud projects remove-iam-policy-binding %q --member=%q --role=%q --condition=None\n' \
    "$BILLING_QUERY_PROJECT_ID" "$member" \
    "projects/${BILLING_QUERY_PROJECT_ID}/roles/${BILLING_QUERY_ROLE_ID}"
  printf 'gcloud iam service-accounts delete %q --project=%q\n' \
    "$CONNECTOR_SERVICE_ACCOUNT_EMAIL" "$TARGET_PROJECT_ID"
  printf '\nThe tenant pool is shared by this tenant inside the project and is not included.\n'
  print_operator_grant_cleanup
}

# Roles the operator granted to themselves during this run. They are separate
# from the connector and can be revoked as soon as setup has finished.
print_operator_grant_cleanup() {
  local grant
  [[ "${#OPERATOR_GRANTS[@]}" -gt 0 ]] || return 0
  printf '\nRoles this setup granted to you (%s) at your request.\n' \
    "$OPERATOR_MEMBER"
  printf 'The Prunio connection does not use them. Revoke them once you no longer need them:\n\n'
  for grant in "${OPERATOR_GRANTS[@]}"; do
    printf 'gcloud projects remove-iam-policy-binding %q --member=%q --role=%q --condition=None\n' \
      "${grant%% *}" "$OPERATOR_MEMBER" "${grant#* }"
  done
}

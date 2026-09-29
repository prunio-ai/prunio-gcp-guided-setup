#!/usr/bin/env bash

derive_resource_names() {
  local tenant_digest
  local binding_compact="${CONNECTION_BINDING_ID//-/}"

  tenant_digest="$(printf '%s' "$PUBLIC_TENANT_ID" | hash_stream)"
  require_match "tenant digest" "$tenant_digest" '^[0-9a-f]{64}$'
  WORKLOAD_IDENTITY_POOL_ID="prunio-${tenant_digest:0:20}"
  WORKLOAD_IDENTITY_PROVIDER_ID="prunio-${binding_compact:0:24}"
  CONNECTOR_SERVICE_ACCOUNT_ID="prunio-${binding_compact:0:20}"
  CONNECTOR_READ_ROLE_ID="prunioRead_${binding_compact:0:16}"
  CONNECTOR_OPTIMIZE_ROLE_ID="prunioOptimize_${binding_compact:0:16}"
  BILLING_QUERY_ROLE_ID="prunioBilling_${binding_compact:0:16}"
  BILLING_VIEW_DATASET_ID="prunio_billing_${binding_compact:0:16}"
  BILLING_SCOPED_VIEW_ID="project_costs"
  GCP_SUBJECT="prunio-gcp-${CONNECTION_BINDING_ID}"
}

set_project_derived_names() {
  CONNECTOR_SERVICE_ACCOUNT_EMAIL=
  CONNECTOR_SERVICE_ACCOUNT_EMAIL="${CONNECTOR_SERVICE_ACCOUNT_ID}@${TARGET_PROJECT_ID}.iam.gserviceaccount.com"
  WORKLOAD_IDENTITY_PROVIDER_RESOURCE=
  WORKLOAD_IDENTITY_PROVIDER_RESOURCE="projects/${TARGET_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WORKLOAD_IDENTITY_POOL_ID}/providers/${WORKLOAD_IDENTITY_PROVIDER_ID}"
  PROVIDER_AUDIENCE="https://iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER_RESOURCE}"
  WIF_PRINCIPAL=
  WIF_PRINCIPAL="principal://iam.googleapis.com/projects/${TARGET_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WORKLOAD_IDENTITY_POOL_ID}/subject/${GCP_SUBJECT}"
  RAW_BILLING_EXPORT_TABLE_ID=
  RAW_BILLING_EXPORT_TABLE_ID="gcp_billing_export_resource_v1_${BILLING_ACCOUNT_ID//-/_}"
}

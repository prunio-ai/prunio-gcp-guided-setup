#!/usr/bin/env bash

enable_required_services() {
  local services=() service
  while IFS= read -r service; do
    [[ -z "$service" ]] || services+=("$service")
  done < "${ROOT}/permissions/required-services.txt"
  # The Service Usage API is on by default, so the target can usually carry
  # this call's quota instead of gcloud's shared, rate-limited client project.
  if target_quota_ready serviceusage.googleapis.com; then
    bill_quota_to_target_project
  fi
  gcloud_with_rate_limit_retry services enable "${services[@]}" \
    --project="$TARGET_PROJECT_ID" --quiet
  # Every API this run calls is now enabled on the target project.
  bill_quota_to_target_project
  log "Google API quota for the rest of this run is charged to ${TARGET_PROJECT_ID}."
  if [[ "$BILLING_QUERY_PROJECT_ID" != "$TARGET_PROJECT_ID" ]]; then
    gcloud_with_rate_limit_retry services enable bigquery.googleapis.com \
      --project="$BILLING_QUERY_PROJECT_ID" --quiet
  fi
}

pool_state() {
  gcloud iam workload-identity-pools list --location=global \
    --project="$TARGET_PROJECT_ID" --show-deleted --format=json |
    jq -r --arg suffix "/${WORKLOAD_IDENTITY_POOL_ID}" \
      '.[] | select(.name | endswith($suffix)) | .state' | head -n 1
}

ensure_workload_identity_pool() {
  local state
  state="$(pool_state)"
  case "$state" in
    DELETED)
      gcloud iam workload-identity-pools undelete \
        "$WORKLOAD_IDENTITY_POOL_ID" --location=global \
        --project="$TARGET_PROJECT_ID" --quiet
      ;;
    ACTIVE) ;;
    "")
      gcloud iam workload-identity-pools create \
        "$WORKLOAD_IDENTITY_POOL_ID" --location=global \
        --project="$TARGET_PROJECT_ID" \
        --display-name="Prunio tenant pool" \
        --description="Prunio tenant ${PUBLIC_TENANT_ID}" --quiet
      ;;
    *) fail "WIF pool is in unsupported state: ${state}" ;;
  esac
  gcloud iam workload-identity-pools update "$WORKLOAD_IDENTITY_POOL_ID" \
    --location=global --project="$TARGET_PROJECT_ID" --no-disabled \
    --display-name="Prunio tenant pool" \
    --description="Prunio tenant ${PUBLIC_TENANT_ID}" --quiet
}

provider_state() {
  gcloud iam workload-identity-pools providers list \
    --workload-identity-pool="$WORKLOAD_IDENTITY_POOL_ID" \
    --location=global --project="$TARGET_PROJECT_ID" --show-deleted \
    --format=json |
    jq -r --arg suffix "/${WORKLOAD_IDENTITY_PROVIDER_ID}" \
      '.[] | select(.name | endswith($suffix)) | .state' | head -n 1
}

provider_flags() {
  ATTRIBUTE_MAPPING=
  ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.tenant_id=assertion.tenant_id,attribute.connection_id=assertion.connection_id,attribute.provider=assertion.provider"
  ATTRIBUTE_CONDITION=
  ATTRIBUTE_CONDITION="assertion.provider == 'gcp' && assertion.tenant_id == '${PUBLIC_TENANT_ID}' && assertion.connection_id == '${CONNECTION_BINDING_ID}'"
}

ensure_workload_identity_provider() {
  local state
  provider_flags
  state="$(provider_state)"
  if [[ "$state" == "DELETED" ]]; then
    gcloud iam workload-identity-pools providers undelete \
      "$WORKLOAD_IDENTITY_PROVIDER_ID" \
      --workload-identity-pool="$WORKLOAD_IDENTITY_POOL_ID" \
      --location=global --project="$TARGET_PROJECT_ID" --quiet
  elif [[ -n "$state" && "$state" != "ACTIVE" ]]; then
    fail "WIF provider is in unsupported state: ${state}"
  fi

  if [[ -z "$state" ]]; then
    gcloud iam workload-identity-pools providers create-oidc \
      "$WORKLOAD_IDENTITY_PROVIDER_ID" \
      --workload-identity-pool="$WORKLOAD_IDENTITY_POOL_ID" \
      --location=global --project="$TARGET_PROJECT_ID" \
      --issuer-uri="$ISSUER" --allowed-audiences="$PROVIDER_AUDIENCE" \
      --attribute-mapping="$ATTRIBUTE_MAPPING" \
      --attribute-condition="$ATTRIBUTE_CONDITION" \
      --display-name="Prunio connection" \
      --description="Binding ${CONNECTION_BINDING_ID}" --quiet
  else
    gcloud iam workload-identity-pools providers update-oidc \
      "$WORKLOAD_IDENTITY_PROVIDER_ID" \
      --workload-identity-pool="$WORKLOAD_IDENTITY_POOL_ID" \
      --location=global --project="$TARGET_PROJECT_ID" --no-disabled \
      --issuer-uri="$ISSUER" --allowed-audiences="$PROVIDER_AUDIENCE" \
      --attribute-mapping="$ATTRIBUTE_MAPPING" \
      --attribute-condition="$ATTRIBUTE_CONDITION" \
      --display-name="Prunio connection" \
      --description="Binding ${CONNECTION_BINDING_ID}" --quiet
  fi
}

ensure_connector_service_account() {
  if ! gcloud iam service-accounts describe \
    "$CONNECTOR_SERVICE_ACCOUNT_EMAIL" --project="$TARGET_PROJECT_ID" \
    --format='value(email)' >/dev/null 2>&1; then
    gcloud iam service-accounts create "$CONNECTOR_SERVICE_ACCOUNT_ID" \
      --project="$TARGET_PROJECT_ID" \
      --display-name="Prunio connector" \
      --description="Binding ${CONNECTION_BINDING_ID}; no user-managed keys" \
      --quiet
  fi
}

ensure_custom_role() {
  local project_id="$1"
  local role_id="$2"
  local definition="$3"
  local deleted
  if gcloud iam roles describe "$role_id" --project="$project_id" \
    --format='value(name)' >/dev/null 2>&1; then
    gcloud iam roles update "$role_id" --project="$project_id" \
      --file="$definition" --quiet
    return
  fi
  deleted="$(gcloud iam roles list --project="$project_id" --show-deleted \
    --format=json | jq -r --arg suffix "/${role_id}" \
    '.[] | select(.name | endswith($suffix) and .deleted == true) | .name' |
    head -n 1)"
  if [[ -n "$deleted" ]]; then
    gcloud iam roles undelete "$role_id" --project="$project_id" --quiet
    gcloud iam roles update "$role_id" --project="$project_id" \
      --file="$definition" --quiet
  else
    gcloud iam roles create "$role_id" --project="$project_id" \
      --file="$definition" --quiet
  fi
}

bind_project_role() {
  local project_id="$1"
  local role_id="$2"
  gcloud projects add-iam-policy-binding "$project_id" \
    --member="serviceAccount:${CONNECTOR_SERVICE_ACCOUNT_EMAIL}" \
    --role="projects/${project_id}/roles/${role_id}" \
    --condition=None --quiet >/dev/null
}

ensure_connector_project_roles() {
  ensure_custom_role "$TARGET_PROJECT_ID" "$CONNECTOR_READ_ROLE_ID" \
    "${ROOT}/permissions/connector-read.yaml"
  bind_project_role "$TARGET_PROJECT_ID" "$CONNECTOR_READ_ROLE_ID"
  if [[ "$POSTURE" == "read_scoped_optimize" ]]; then
    ensure_custom_role "$TARGET_PROJECT_ID" "$CONNECTOR_OPTIMIZE_ROLE_ID" \
      "${ROOT}/permissions/connector-optimize.yaml"
    bind_project_role "$TARGET_PROJECT_ID" "$CONNECTOR_OPTIMIZE_ROLE_ID"
  fi
  ensure_custom_role "$BILLING_QUERY_PROJECT_ID" "$BILLING_QUERY_ROLE_ID" \
    "${ROOT}/permissions/billing-query.yaml"
  bind_project_role "$BILLING_QUERY_PROJECT_ID" "$BILLING_QUERY_ROLE_ID"
}

ensure_exact_workload_identity_binding() {
  gcloud iam service-accounts add-iam-policy-binding \
    "$CONNECTOR_SERVICE_ACCOUNT_EMAIL" --project="$TARGET_PROJECT_ID" \
    --member="$WIF_PRINCIPAL" --role=roles/iam.workloadIdentityUser \
    --condition=None --quiet >/dev/null
}

verify_provider_contract() {
  local provider_file="${RUNTIME_DIR}/provider.json"
  gcloud iam workload-identity-pools providers describe \
    "$WORKLOAD_IDENTITY_PROVIDER_ID" \
    --workload-identity-pool="$WORKLOAD_IDENTITY_POOL_ID" \
    --location=global --project="$TARGET_PROJECT_ID" --format=json \
    > "$provider_file"
  jq -e --arg issuer "$ISSUER" --arg audience "$PROVIDER_AUDIENCE" \
    --arg condition "$ATTRIBUTE_CONDITION" '
      .state == "ACTIVE" and .disabled != true and
      .oidc.issuerUri == $issuer and
      .oidc.allowedAudiences == [$audience] and
      .attributeCondition == $condition and
      .attributeMapping == {
        "google.subject": "assertion.sub",
        "attribute.tenant_id": "assertion.tenant_id",
        "attribute.connection_id": "assertion.connection_id",
        "attribute.provider": "assertion.provider"
      }
    ' "$provider_file" >/dev/null || fail "WIF provider contract drifted"
}

provision_gcp_identity_resources() {
  ensure_workload_identity_pool
  ensure_workload_identity_provider
  ensure_connector_service_account
  ensure_connector_project_roles
  ensure_exact_workload_identity_binding
  verify_provider_contract
}

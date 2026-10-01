#!/usr/bin/env bash

registration_payload() {
  printf '{'
  printf '"setupCode":"%s",' "$SETUP_CODE"
  printf '"projectId":"%s",' "$TARGET_PROJECT_ID"
  printf '"projectNumber":"%s",' "$TARGET_PROJECT_NUMBER"
  printf '"workloadIdentityPoolId":"%s",' "$WORKLOAD_IDENTITY_POOL_ID"
  printf '"workloadIdentityProviderResourceName":"%s",' \
    "$WORKLOAD_IDENTITY_PROVIDER_RESOURCE"
  printf '"serviceAccountEmail":"%s",' "$CONNECTOR_SERVICE_ACCOUNT_EMAIL"
  printf '"billingAccountId":"%s",' "$BILLING_ACCOUNT_ID"
  printf '"billingProjectId":"%s",' "$BILLING_QUERY_PROJECT_ID"
  printf '"billingDatasetId":"%s",' "$BILLING_VIEW_DATASET_ID"
  printf '"billingScopedViewId":"%s",' "$BILLING_SCOPED_VIEW_ID"
  printf '"artifactVersion":"%s"' "$ARTIFACT_COMMIT"
  printf '}'
}

post_registration_once() {
  local response_file="$1"
  registration_payload | curl --silent --show-error --proto '=https' \
    --tlsv1.2 --connect-timeout 5 --max-time 20 --max-filesize 65536 \
    --request POST --header 'Content-Type: application/json' \
    --data-binary @- --output "$response_file" --write-out '%{http_code}' \
    "$REGISTRATION_ENDPOINT"
}

register_connection_coordinates() {
  local response_file="${RUNTIME_DIR}/registration-response.json"
  local http_status attempt
  for attempt in 1 2 3; do
    if http_status="$(post_registration_once "$response_file")"; then
      [[ "$http_status" == "202" ]] ||
        fail "Prunio rejected the GCP registration"
      jq -e '
        type == "object" and
        (keys | sort) == (["bindingVersion", "registrySyncStatus", "status"] | sort) and
        .status == "accepted" and
        (.bindingVersion | type == "number" and . >= 1 and floor == .) and
        (.registrySyncStatus == "pending" or
          .registrySyncStatus == "synced" or
          .registrySyncStatus == "failed")
      ' "$response_file" >/dev/null ||
        fail "Prunio returned an invalid registration response"
      unset SETUP_CODE
      log "Registration accepted; Prunio verification is now pending."
      return
    fi
    [[ "$attempt" -eq 3 ]] || sleep "$attempt"
  done
  fail "Registration response was unavailable after three idempotent attempts"
}

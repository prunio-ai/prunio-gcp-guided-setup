#!/usr/bin/env bash

hash_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

require_sha256_command() {
  if command -v sha256sum >/dev/null 2>&1 ||
    command -v shasum >/dev/null 2>&1; then
    return
  fi
  fail "Required SHA-256 command is unavailable: install sha256sum or shasum"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

load_artifact_config() {
  local config_file="${ROOT}/artifact-config.json"
  jq -e '
    type == "object" and
    (keys | sort) == (["issuerOrigin", "registrationOrigin", "repository",
      "schemaVersion", "setupContextEndpoint"] | sort) and
    .schemaVersion == 1 and
    (.repository | type == "string") and
    (.setupContextEndpoint | type == "string") and
    (.registrationOrigin | type == "string") and
    (.issuerOrigin | type == "string")
  ' "$config_file" >/dev/null || fail "Artifact configuration is invalid"

  ARTIFACT_REPOSITORY="$(jq -r '.repository' "$config_file")"
  SETUP_CONTEXT_ENDPOINT="$(jq -r '.setupContextEndpoint' "$config_file")"
  REGISTRATION_ORIGIN="$(jq -r '.registrationOrigin' "$config_file")"
  ISSUER_ORIGIN="$(jq -r '.issuerOrigin' "$config_file")"
  [[ "$ARTIFACT_REPOSITORY" == \
    "https://github.com/prunio-ai/prunio-gcp-guided-setup.git" ]] ||
    fail "Artifact repository is not approved"
  [[ "$SETUP_CONTEXT_ENDPOINT" == \
    "${REGISTRATION_ORIGIN}/api/v1/connections/gcp/setup-context" ]] ||
    fail "Setup-context endpoint is not approved"
  [[ "$REGISTRATION_ORIGIN" =~ ^https://[A-Za-z0-9.-]+$ ]] ||
    fail "Registration origin is invalid"
  [[ "$ISSUER_ORIGIN" =~ ^https://[A-Za-z0-9.-]+$ ]] ||
    fail "Issuer origin is invalid"
}

compute_artifact_digest() {
  local manifest="${ROOT}/artifact-manifest.txt"
  local relative_path
  {
    printf '%s  %s\n' "$(hash_file "$manifest")" "artifact-manifest.txt"
    while IFS= read -r relative_path; do
      [[ "$relative_path" =~ ^[A-Za-z0-9._/-]+$ ]] ||
        fail "Artifact manifest contains an invalid path"
      [[ "$relative_path" != /* && "$relative_path" != *".."* ]] ||
        fail "Artifact manifest path escapes the artifact"
      [[ -f "${ROOT}/${relative_path}" ]] ||
        fail "Artifact manifest file is missing: ${relative_path}"
      printf '%s  %s\n' "$(hash_file "${ROOT}/${relative_path}")" "$relative_path"
    done < "$manifest"
  } | hash_stream
}

verify_local_release() {
  local repository_root branch remote dirty
  repository_root="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" ||
    fail "Artifact is not in a Git checkout"
  [[ "$repository_root" == "$ROOT" ]] ||
    fail "Artifact must run from the dedicated repository root"

  ARTIFACT_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" ||
    fail "Artifact commit cannot be resolved"
  require_match "artifact commit" "$ARTIFACT_COMMIT" '^[0-9a-f]{40}$'
  branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
    fail "Artifact must run from its protected release branch"
  [[ "$branch" == "release-${ARTIFACT_COMMIT}" ]] ||
    fail "Release branch does not pin the checked-out artifact commit"
  remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" ||
    fail "Artifact origin cannot be resolved"
  [[ "$remote" == "$ARTIFACT_REPOSITORY" ]] ||
    fail "Artifact origin is not the approved Prunio repository"
  dirty="$(git -C "$ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$dirty" ]] || fail "Artifact checkout contains local changes"

  ARTIFACT_DIGEST="$(compute_artifact_digest)"
  require_match "artifact digest" "$ARTIFACT_DIGEST" '^[0-9a-f]{64}$'
}

fetch_setup_context() {
  local http_status
  prompt_setup_code
  SETUP_CONTEXT_FILE="${RUNTIME_DIR}/setup-context.json"
  http_status="$({
    printf '{"setupCode":"%s"}' "$SETUP_CODE"
  } | curl --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 5 --max-time 20 --max-filesize 65536 \
    --request POST --header 'Content-Type: application/json' \
    --data-binary @- --output "$SETUP_CONTEXT_FILE" \
    --write-out '%{http_code}' "$SETUP_CONTEXT_ENDPOINT")" ||
    fail "Prunio setup context could not be reached"
  [[ "$http_status" == "200" ]] || fail "Setup code was not accepted"
}

verify_setup_context() {
  jq -e '
    type == "object" and
    (keys | sort) == (["artifactDigest", "artifactVersion",
      "connectionBindingId", "environmentLabel", "intentId", "issuer",
      "posture", "publicTenantId", "registrationEndpoint", "schemaVersion"]
      | sort) and
    .schemaVersion == 1 and
    ([.intentId, .connectionBindingId, .publicTenantId, .issuer, .posture,
      .environmentLabel, .artifactVersion, .artifactDigest,
      .registrationEndpoint] | all(type == "string"))
  ' "$SETUP_CONTEXT_FILE" >/dev/null || fail "Setup context shape is invalid"

  INTENT_ID="$(jq -r '.intentId' "$SETUP_CONTEXT_FILE")"
  CONNECTION_BINDING_ID="$(jq -r '.connectionBindingId' "$SETUP_CONTEXT_FILE")"
  PUBLIC_TENANT_ID="$(jq -r '.publicTenantId' "$SETUP_CONTEXT_FILE")"
  ISSUER="$(jq -r '.issuer' "$SETUP_CONTEXT_FILE")"
  POSTURE="$(jq -r '.posture' "$SETUP_CONTEXT_FILE")"
  ENVIRONMENT_LABEL="$(jq -r '.environmentLabel' "$SETUP_CONTEXT_FILE")"
  REGISTRATION_ENDPOINT="$(jq -r '.registrationEndpoint' "$SETUP_CONTEXT_FILE")"

  local uuid_v4='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  require_match "intent ID" "$INTENT_ID" "$uuid_v4"
  require_match "connection binding ID" "$CONNECTION_BINDING_ID" "$uuid_v4"
  require_match "public tenant ID" "$PUBLIC_TENANT_ID" "$uuid_v4"
  [[ "$ISSUER" == "${ISSUER_ORIGIN}/oidc/gcp/tenants/${PUBLIC_TENANT_ID}" ]] ||
    fail "OIDC issuer does not match the tenant"
  [[ "$POSTURE" == "read_only" || "$POSTURE" == "read_scoped_optimize" ]] ||
    fail "GCP posture is unsupported"
  require_match "environment label" "$ENVIRONMENT_LABEL" \
    '^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$'
  [[ "$(jq -r '.artifactVersion' "$SETUP_CONTEXT_FILE")" == \
    "$ARTIFACT_COMMIT" ]] || fail "Artifact commit does not match the intent"
  [[ "$(jq -r '.artifactDigest' "$SETUP_CONTEXT_FILE")" == \
    "$ARTIFACT_DIGEST" ]] || fail "Artifact digest does not match the intent"
  [[ "$REGISTRATION_ENDPOINT" == \
    "${REGISTRATION_ORIGIN}/api/v1/connections/intents/${INTENT_ID}/gcp/register" ]] ||
    fail "Registration endpoint does not match the intent"
}

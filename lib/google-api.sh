#!/usr/bin/env bash

# Google API access for read-only discovery and permission tests, plus the
# quota project used for the run.
#
# Quota: by default gcloud's `services`, `projects` and `billing` command groups
# charge requests to gcloud's shared client project, whose rate limits every
# gcloud user shares (HTTP 429 RATE_LIMIT_EXCEEDED). CLOUDSDK_BILLING_QUOTA_PROJECT
# overrides that default, but Google then requires the called API to be enabled
# on the quota project. Before approval only the APIs already enabled on the
# target project are billed to it; after approval, once the required APIs are
# enabled, the whole run is.

TARGET_QUOTA_SERVICES=""

load_access_token() {
  GOOGLE_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null)" ||
    fail "Could not obtain a temporary operator access token"
  [[ -n "$GOOGLE_ACCESS_TOKEN" ]] ||
    fail "Could not obtain a temporary operator access token"
}

forget_access_token() {
  unset GOOGLE_ACCESS_TOKEN
}

google_api_request_once() {
  local method="$1"
  local url="$2"
  local output_file="$3"
  local quota_project="$4"
  local request_file="$5"
  local data_arguments=()
  [[ -z "$request_file" ]] || data_arguments=(--data-binary "@${request_file}")
  {
    printf 'header = "Authorization: Bearer %s"\n' "$GOOGLE_ACCESS_TOKEN"
    printf 'header = "Content-Type: application/json"\n'
    [[ -z "$quota_project" ]] ||
      printf 'header = "X-Goog-User-Project: %s"\n' "$quota_project"
  } | curl --config - --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
    --request "$method" ${data_arguments[@]+"${data_arguments[@]}"} \
    --output "$output_file" --write-out '%{http_code}' "$url"
}

# google_api_request METHOD URL OUTPUT_FILE [QUOTA_PROJECT] [REQUEST_FILE]
# Prints the HTTP status. The token from load_access_token reaches curl through
# a config on stdin, never argv. HTTP 429 is retried twice with backoff.
google_api_request() {
  local method="$1"
  local url="$2"
  local output_file="$3"
  local quota_project="${4:-}"
  local request_file="${5:-}"
  local http_status delay
  [[ -n "${GOOGLE_ACCESS_TOKEN:-}" ]] ||
    fail "No operator access token is loaded"
  for delay in 2 4 0; do
    http_status="$(google_api_request_once "$method" "$url" "$output_file" \
      "$quota_project" "$request_file")" || return 1
    if [[ "$http_status" != "429" || "$delay" -eq 0 ]]; then
      printf '%s' "$http_status"
      return
    fi
    log "Google API rate limit reached; retrying in ${delay}s" >&2
    sleep "$delay"
  done
}

# Records which APIs are enabled on the target project, read with the target
# as the quota project. Gcloud may not offer to enable an API meanwhile:
# suppress_api_enablement_prompts runs before this.
inspect_target_quota_project() {
  TARGET_QUOTA_SERVICES="$(
    CLOUDSDK_BILLING_QUOTA_PROJECT="$TARGET_PROJECT_ID" gcloud services list \
      --enabled --project="$TARGET_PROJECT_ID" --format='value(config.name)' \
      2>/dev/null
  )" || TARGET_QUOTA_SERVICES=""
}

target_quota_ready() {
  [[ -n "$TARGET_QUOTA_SERVICES" ]] &&
    grep -Fqx -- "$1" <<< "$TARGET_QUOTA_SERVICES"
}

# Prints the target project when it can carry the quota for SERVICE.
quota_project_for() {
  if target_quota_ready "$1"; then
    printf '%s' "$TARGET_PROJECT_ID"
  fi
}

# gcloud_billed_to_target SERVICE ARGS...: runs gcloud with the target project
# as quota project when SERVICE is already enabled there.
gcloud_billed_to_target() {
  local service="$1"
  shift
  if target_quota_ready "$service"; then
    CLOUDSDK_BILLING_QUOTA_PROJECT="$TARGET_PROJECT_ID" gcloud "$@"
  else
    gcloud "$@"
  fi
}

bill_quota_to_target_project() {
  export CLOUDSDK_BILLING_QUOTA_PROJECT="$TARGET_PROJECT_ID"
}

# Before approval, gcloud must not enable an API as a side effect of its own
# "API not enabled; enable and retry?" prompt.
suppress_api_enablement_prompts() {
  export CLOUDSDK_CORE_SHOULD_PROMPT_TO_ENABLE_API=false
}

restore_api_enablement_prompts() {
  unset CLOUDSDK_CORE_SHOULD_PROMPT_TO_ENABLE_API
}

# gcloud_with_rate_limit_retry ARGS...: retries an idempotent gcloud command up
# to five times with exponential backoff while Google answers HTTP 429.
gcloud_with_rate_limit_retry() {
  local error_file="${RUNTIME_DIR}/gcloud-error.txt"
  local attempt delay=5 max_attempts=5
  for ((attempt = 1; ; attempt += 1)); do
    if gcloud "$@" 2> "$error_file"; then
      cat "$error_file" >&2
      return
    fi
    if ! grep -Eq 'RATE_LIMIT_EXCEEDED|RESOURCE_EXHAUSTED|HTTPError 429|Quota exceeded' \
      "$error_file"; then
      cat "$error_file" >&2
      fail "gcloud $1 $2 failed"
    fi
    if ((attempt == max_attempts)); then
      cat "$error_file" >&2
      fail "Google kept rate-limiting gcloud $1 $2; wait a few minutes, then re-run ./setup.sh"
    fi
    log "Google rate-limited gcloud $1 $2; retrying in ${delay}s (attempt $((attempt + 1)) of ${max_attempts})" >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
}

#!/usr/bin/env bash

# Google API access for read-only discovery and permission tests, the quota
# project used for the run, and bounded retries for transient Google errors.
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

# The waits before each retry of a gcloud or bq command that Google refused for
# a transient reason. Each reason has its own budget, so a command that meets
# both waits at most the two budgets added together, never their product.
RATE_LIMIT_RETRY_DELAYS=(5 10 20 40)
NEW_SERVICE_ACCOUNT_RETRY_DELAYS=(5 10 20 30 30)

google_rate_limited() {
  grep -Eq 'RATE_LIMIT_EXCEEDED|RESOURCE_EXHAUSTED|HTTPError 429|Quota exceeded' \
    "$@"
}

# connector_service_account_not_visible FILE...: succeeds when Google refused
# the command only because IAM does not show the connector service account
# yet. A new account can take a minute or two to reach every IAM policy check.
# Whitespace is ignored because bq wraps its messages at 80 columns, also
# inside the account email. Matched forms:
# - gcloud projects / bq add-iam-policy-binding, the account as member:
#   "Service account EMAIL does not exist."
# - gcloud iam service-accounts add-iam-policy-binding, the account as
#   resource: "NOT_FOUND: Unknown service account", a .../serviceAccounts/EMAIL
#   "does not exist" message, or the PERMISSION_DENIED that Google documents
#   for a missing account: "Permission 'iam.serviceAccounts.getIamPolicy'
#   denied on resource (or it may not exist)." The permission preflight has
#   already confirmed that the operator holds that permission on the project.
connector_service_account_not_visible() {
  local text email="$CONNECTOR_SERVICE_ACCOUNT_EMAIL"
  text="$(cat "$@")"
  text="${text//[[:space:]]/}"
  case "$text" in
    *[Ss]"erviceaccount${email}doesnotexist"* | \
      *"/serviceAccounts/${email}doesnotexist"* | \
      *"NOT_FOUND:Unknownserviceaccount"* | \
      *"Permission"?"iam.serviceAccounts."[gs]"etIamPolicy"?"deniedonresource(oritmaynotexist)"*)
      return 0
      ;;
  esac
  return 1
}

# retry_google_command LABEL NEW_SERVICE_ACCOUNT COMMAND ARGS...: runs an
# idempotent gcloud or bq command. It retries while Google answers HTTP 429
# and, when NEW_SERVICE_ACCOUNT is 1, while IAM does not show the connector
# service account yet. Any other error fails at once. Both streams are held in
# the runtime directory until the command ends: stdout is passed on after a
# success, and both are replayed to stderr after the final failure (bq prints
# its errors to stdout).
retry_google_command() {
  local label="$1"
  local new_service_account="$2"
  shift 2
  local output_file="${RUNTIME_DIR}/google-command-stdout.txt"
  local error_file="${RUNTIME_DIR}/google-command-stderr.txt"
  local rate_limit_retries=0 service_account_retries=0 delay total
  while true; do
    if "$@" > "$output_file" 2> "$error_file"; then
      cat "$error_file" >&2
      cat "$output_file"
      return
    fi
    if google_rate_limited "$error_file" "$output_file"; then
      if ((rate_limit_retries == ${#RATE_LIMIT_RETRY_DELAYS[@]})); then
        cat "$error_file" "$output_file" >&2
        fail "Google kept rate-limiting ${label}; wait a few minutes, then re-run ./setup.sh"
      fi
      delay="${RATE_LIMIT_RETRY_DELAYS[rate_limit_retries]}"
      rate_limit_retries=$((rate_limit_retries + 1))
      log "Google rate-limited ${label}; retrying in ${delay}s (attempt $((rate_limit_retries + 1)) of $((${#RATE_LIMIT_RETRY_DELAYS[@]} + 1)))" >&2
    elif [[ "$new_service_account" == 1 ]] &&
      connector_service_account_not_visible "$error_file" "$output_file"; then
      if ((service_account_retries == ${#NEW_SERVICE_ACCOUNT_RETRY_DELAYS[@]})); then
        cat "$error_file" "$output_file" >&2
        total=0
        for delay in "${NEW_SERVICE_ACCOUNT_RETRY_DELAYS[@]}"; do
          total=$((total + delay))
        done
        fail "Google IAM still did not recognize the new service account ${CONNECTOR_SERVICE_ACCOUNT_EMAIL} after ${total}s; this can take a few minutes. Wait, then re-run ./setup.sh"
      fi
      delay="${NEW_SERVICE_ACCOUNT_RETRY_DELAYS[service_account_retries]}"
      service_account_retries=$((service_account_retries + 1))
      log "Waiting for the new service account to reach Google IAM; retrying in ${delay}s (attempt $((service_account_retries + 1)) of $((${#NEW_SERVICE_ACCOUNT_RETRY_DELAYS[@]} + 1)))" >&2
    else
      cat "$error_file" "$output_file" >&2
      fail "${label} failed"
    fi
    sleep "$delay"
  done
}

# gcloud_with_rate_limit_retry ARGS...: retries an idempotent gcloud command up
# to five times with exponential backoff while Google answers HTTP 429.
gcloud_with_rate_limit_retry() {
  retry_google_command "gcloud $1 $2" 0 gcloud "$@"
}

# iam_binding_with_retry COMMAND ARGS...: adds an IAM binding that names the
# connector service account, with gcloud or bq. Besides HTTP 429, it outlasts
# the minute or two in which IAM may still reject a just-created account as
# unknown: up to six attempts over 95 seconds.
iam_binding_with_retry() {
  local label="$1" argument
  for argument in "${@:2}"; do
    label+=" ${argument}"
    [[ "$argument" != add-iam-policy-binding ]] || break
  done
  retry_google_command "$label" 1 "$@"
}

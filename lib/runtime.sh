#!/usr/bin/env bash

log() {
  printf '[Prunio] %s\n' "$*"
}

fail() {
  printf '[Prunio] ERROR: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      fail "Required command is unavailable: ${command_name}"
  done
}

require_match() {
  local label="$1"
  local value="$2"
  local pattern="$3"
  [[ "$value" =~ $pattern ]] || fail "Invalid ${label}"
}

prompt_required() {
  local variable_name="$1"
  local label="$2"
  local value
  printf '%s: ' "$label" >&2
  IFS= read -r value || fail "Input ended before ${label} was provided"
  [[ -n "$value" ]] || fail "${label} is required"
  printf -v "$variable_name" '%s' "$value"
}

prompt_with_default() {
  local variable_name="$1"
  local label="$2"
  local default_value="$3"
  local value
  printf '%s [%s]: ' "$label" "$default_value" >&2
  IFS= read -r value || fail "Input ended before ${label} was provided"
  printf -v "$variable_name" '%s' "${value:-$default_value}"
}

prompt_setup_code() {
  printf 'Prunio one-time setup code: ' >&2
  IFS= read -r -s SETUP_CODE || fail "Setup code input was interrupted"
  printf '\n' >&2
  require_match "setup code" "$SETUP_CODE" '^[A-Za-z0-9_-]{43}$'
}

confirm_project_mutation() {
  local confirmation
  printf 'Type the target project ID (%s) to approve these changes: ' \
    "$TARGET_PROJECT_ID" >&2
  IFS= read -r confirmation || fail "Confirmation input was interrupted"
  [[ "$confirmation" == "$TARGET_PROJECT_ID" ]] ||
    fail "Project confirmation did not match"
}

make_runtime_directory() {
  umask 077
  RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prunio-gcp.XXXXXX")" ||
    fail "Could not create a private temporary directory"
}

cleanup_runtime_directory() {
  [[ -z "${SETUP_CODE:-}" ]] || unset SETUP_CODE
  [[ -z "${RUNTIME_DIR:-}" ]] || rm -rf "$RUNTIME_DIR"
}

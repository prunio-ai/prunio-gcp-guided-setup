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

# prompt_choice VARIABLE LABEL DEFAULT_INDEX TYPED_PATTERN OPTION...
# Lists the options as 1..n. Enter takes DEFAULT_INDEX (none when empty), a
# number takes that option, and any other answer must match TYPED_PATTERN and
# is taken verbatim, so an ID that is not listed can still be typed.
prompt_choice() {
  local variable_name="$1"
  local label="$2"
  local default_index="$3"
  local typed_pattern="$4"
  shift 4
  local options=("$@")
  local answer attempt index
  for index in "${!options[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
  done
  for attempt in 1 2 3; do
    if [[ -n "$default_index" ]]; then
      printf '%s [%s]: ' "$label" "$default_index" >&2
    else
      printf '%s: ' "$label" >&2
    fi
    IFS= read -r answer || fail "Input ended before ${label} was provided"
    answer="${answer:-$default_index}"
    if [[ "$answer" =~ ^[0-9]{1,4}$ ]] &&
      ((10#$answer >= 1 && 10#$answer <= ${#options[@]})); then
      printf -v "$variable_name" '%s' "${options[$((10#$answer - 1))]}"
      return
    fi
    if [[ -n "$answer" && ! "$answer" =~ ^[0-9]+$ &&
      "$answer" =~ $typed_pattern ]]; then
      printf -v "$variable_name" '%s' "$answer"
      return
    fi
    printf '  Enter a number from 1 to %d, or type an ID (attempt %d of 3).\n' \
      "${#options[@]}" "$attempt" >&2
  done
  fail "No valid ${label} was chosen"
}

# confirm_default_no QUESTION: succeeds only on an explicit y or Y.
confirm_default_no() {
  local answer
  printf '%s [y/N]: ' "$1" >&2
  IFS= read -r answer || fail "Input ended before the question was answered"
  [[ "$answer" =~ ^[Yy]$ ]]
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
  [[ -z "${GOOGLE_ACCESS_TOKEN:-}" ]] || unset GOOGLE_ACCESS_TOKEN
  [[ -z "${RUNTIME_DIR:-}" ]] || rm -rf "$RUNTIME_DIR"
}

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/runtime.sh
source "${ROOT}/lib/runtime.sh"
# shellcheck source=lib/integrity.sh
source "${ROOT}/lib/integrity.sh"
# shellcheck source=lib/naming.sh
source "${ROOT}/lib/naming.sh"
# shellcheck source=lib/google-api.sh
source "${ROOT}/lib/google-api.sh"
# shellcheck source=lib/discovery.sh
source "${ROOT}/lib/discovery.sh"
# shellcheck source=lib/operator-access.sh
source "${ROOT}/lib/operator-access.sh"
# shellcheck source=lib/operator-preflight.sh
source "${ROOT}/lib/operator-preflight.sh"
# shellcheck source=lib/gcp-resources.sh
source "${ROOT}/lib/gcp-resources.sh"
# shellcheck source=lib/billing-surface.sh
source "${ROOT}/lib/billing-surface.sh"
# shellcheck source=lib/registration.sh
source "${ROOT}/lib/registration.sh"
# shellcheck source=lib/cleanup-plan.sh
source "${ROOT}/lib/cleanup-plan.sh"

finish_setup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" -ne 0 && "${CLOUD_MUTATION_STARTED:-0}" -eq 1 ]]; then
    printf '\nSetup stopped after cloud mutation began.\n' >&2
    print_cleanup_plan >&2
  elif [[ "$status" -ne 0 && "${#OPERATOR_GRANTS[@]}" -gt 0 ]]; then
    printf '\nSetup stopped after granting roles to you.\n' >&2
    print_operator_grant_cleanup >&2
  fi
  cleanup_runtime_directory
  exit "$status"
}

main() {
  require_commands git jq curl gcloud bq cmp
  make_runtime_directory
  trap finish_setup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  load_artifact_config
  verify_local_release
  suppress_api_enablement_prompts
  ensure_gcloud_authentication
  fetch_setup_context
  verify_setup_context
  derive_resource_names
  collect_customer_inputs
  verify_operator_prerequisites
  inspect_billing_export
  show_change_summary
  confirm_project_mutation
  restore_api_enablement_prompts

  CLOUD_MUTATION_STARTED=1
  enable_required_services
  provision_gcp_identity_resources
  provision_billing_surface
  register_connection_coordinates
  print_cleanup_plan
  CLOUD_MUTATION_STARTED=0
}

main "$@"

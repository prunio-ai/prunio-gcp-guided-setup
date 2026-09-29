#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runtime.sh
source "${ROOT}/lib/runtime.sh"
# shellcheck source=lib/integrity.sh
source "${ROOT}/lib/integrity.sh"

require_commands git
require_sha256_command
compute_artifact_digest

#!/usr/bin/env bash
# covers: jido_signal.workflow.spec_check_entrypoint jido_signal.workflow.spec_check_ci
set -euo pipefail

ROOT="${SPEC_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT"

export MIX_ENV="${MIX_ENV:-test}"

mix spec.check "$@"

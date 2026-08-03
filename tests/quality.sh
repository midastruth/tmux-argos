#!/usr/bin/env bash
# Strict source quality metrics. Thresholds live in the human-owned Python
# falsifier so callers cannot weaken them with environment overrides.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'not ok - python3 is required for strict quality metrics\n' >&2
  exit 1
fi

python3 "$ROOT/tests/quality_metrics.py" "$ROOT"

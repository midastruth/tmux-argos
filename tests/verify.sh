#!/usr/bin/env bash
# Fast constitutional gate. Performance tests remain a separate, noisy-machine
# gate in tests/perf_smoke.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIME_BUDGET_SECONDS=30
STARTED_AT="$(date +%s)"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'not ok - required verification command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
}

run_gate() {
  local name="$1"
  shift
  printf '\n== %s ==\n' "$name"
  if ! "$@"; then
    printf 'not ok - %s\n' "$name" >&2
    exit 1
  fi
}

require_command cargo
require_command node
require_command python3
require_command shellcheck

run_gate 'L0 Pi constitution behavior' node "$ROOT/tests/test_constitution.mjs"
run_gate 'L0 Gherkin-to-acceptance bindings' python3 "$ROOT/tests/gherkin_contract.py"
run_gate 'L1 architecture contracts' bash "$ROOT/tests/architecture.sh"
run_gate 'L2 strict structural quality metrics' bash "$ROOT/tests/quality.sh"
run_gate 'L2 ShellCheck zero warnings' \
  shellcheck -x -P "$ROOT/scripts" "$ROOT/tmux-argos.tmux" \
  "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh
run_gate 'L2 Rust formatting' cargo fmt --manifest-path "$ROOT/daemon/Cargo.toml" -- --check
run_gate 'L2 Rust compilation' cargo check --manifest-path "$ROOT/daemon/Cargo.toml"
run_gate 'L2 Rust lint and cognitive complexity' \
  cargo clippy --manifest-path "$ROOT/daemon/Cargo.toml" --all-targets -- \
  -D warnings -W clippy::cognitive_complexity
run_gate 'L0 Rust behavior' cargo test --manifest-path "$ROOT/daemon/Cargo.toml"
run_gate 'L0 Bash behavior' bash "$ROOT/tests/run.sh"
run_gate 'L3 falsifier meta-tests' bash "$ROOT/tests/meta.sh"

FINISHED_AT="$(date +%s)"
ELAPSED_SECONDS=$((FINISHED_AT - STARTED_AT))
if [ "$ELAPSED_SECONDS" -gt "$TIME_BUDGET_SECONDS" ]; then
  printf 'not ok - fast verification took %ss (budget %ss)\n' \
    "$ELAPSED_SECONDS" "$TIME_BUDGET_SECONDS" >&2
  exit 1
fi
printf '\nok - constitutional verification completed in %ss (budget %ss)\n' \
  "$ELAPSED_SECONDS" "$TIME_BUDGET_SECONDS"

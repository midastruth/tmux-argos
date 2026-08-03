#!/usr/bin/env bash
# shellcheck disable=SC2016 # drift fixtures intentionally contain literal shell variables
# Tests for the architecture and quality falsifiers themselves.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-argos-meta-tests.$$"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
}

expect_rejection() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name"
  else
    pass "$name"
  fi
}

make_fixture() {
  local destination="$1"
  mkdir -p "$destination/daemon"
  cp "$ROOT/tmux-argos.tmux" "$destination/tmux-argos.tmux"
  cp -R "$ROOT/scripts" "$destination/scripts"
  cp -R "$ROOT/daemon/src" "$destination/daemon/src"
}

make_suite_fixture() {
  local destination="$1"
  make_fixture "$destination"
  mkdir -p "$destination/.github/workflows" "$destination/.pi/extensions"
  cp -R "$ROOT/tests" "$destination/tests"
  cp "$ROOT/AGENTS.md" "$destination/AGENTS.md"
  cp "$ROOT/.github/CODEOWNERS" "$destination/.github/CODEOWNERS"
  cp "$ROOT/.github/workflows/test.yml" "$destination/.github/workflows/test.yml"
  cp "$ROOT/.pi/extensions/test-constitution.ts" \
    "$destination/.pi/extensions/test-constitution.ts"
}

mutate_once() {
  local path="$1" old_text="$2" new_text="$3"
  python3 - "$path" "$old_text" "$new_text" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old_text = sys.argv[2]
new_text = sys.argv[3]
source = path.read_text()
if source.count(old_text) != 1:
    raise SystemExit(f"expected one mutation target in {path}, found {source.count(old_text)}")
path.write_text(source.replace(old_text, new_text))
PY
}

if bash "$ROOT/tests/architecture.sh" "$ROOT" >/dev/null; then
  pass 'architecture falsifier accepts the current dependency graph'
else
  fail 'architecture falsifier accepts the current dependency graph'
fi

if bash "$ROOT/tests/quality.sh" "$ROOT" >/dev/null; then
  pass 'quality falsifier accepts the current source budgets'
else
  fail 'quality falsifier accepts the current source budgets'
fi

if python3 "$ROOT/tests/suite_contract.py" "$ROOT" >/dev/null; then
  pass 'suite-contract falsifier accepts the reviewed gate capabilities'
else
  fail 'suite-contract falsifier accepts the reviewed gate capabilities'
fi

suite_base_fixture="$TMP_ROOT/suite-base"
make_suite_fixture "$suite_base_fixture"

behavior_wiring_fixture="$TMP_ROOT/behavior-wiring-drift"
cp -R "$suite_base_fixture" "$behavior_wiring_fixture"
mutate_once "$behavior_wiring_fixture/tests/verify.sh" \
  'bash "$ROOT/tests/run.sh"' 'true # Bash behavior gate disconnected'
expect_rejection 'suite-contract falsifier rejects a disconnected behavior suite' \
  python3 "$ROOT/tests/suite_contract.py" "$behavior_wiring_fixture"

fast_gate_fixture="$TMP_ROOT/fast-gate-drift"
cp -R "$suite_base_fixture" "$fast_gate_fixture"
mutate_once "$fast_gate_fixture/tests/verify.sh" \
  'TIME_BUDGET_SECONDS=30' 'TIME_BUDGET_SECONDS=300'
expect_rejection 'suite-contract falsifier rejects a relaxed fast-feedback budget' \
  python3 "$ROOT/tests/suite_contract.py" "$fast_gate_fixture"

performance_fixture="$TMP_ROOT/performance-drift"
cp -R "$suite_base_fixture" "$performance_fixture"
mutate_once "$performance_fixture/tests/perf_smoke.sh" \
  'max_picker_ms=200' 'max_picker_ms=2000'
expect_rejection 'suite-contract falsifier rejects a relaxed performance ceiling' \
  python3 "$ROOT/tests/suite_contract.py" "$performance_fixture"

stability_fixture="$TMP_ROOT/stability-drift"
cp -R "$suite_base_fixture" "$stability_fixture"
mutate_once "$stability_fixture/tests/flaky.sh" 'REPETITIONS=20' 'REPETITIONS=1'
expect_rejection 'suite-contract falsifier rejects reduced stability repetitions' \
  python3 "$ROOT/tests/suite_contract.py" "$stability_fixture"

mutation_gate_fixture="$TMP_ROOT/mutation-gate-drift"
cp -R "$suite_base_fixture" "$mutation_gate_fixture"
mutate_once "$mutation_gate_fixture/tests/mutation.sh" \
  "--file 'src/protocol.rs'" "--file 'src/model.rs'"
expect_rejection 'suite-contract falsifier rejects lost protocol mutation coverage' \
  python3 "$ROOT/tests/suite_contract.py" "$mutation_gate_fixture"

system_gate_fixture="$TMP_ROOT/system-gate-drift"
cp -R "$suite_base_fixture" "$system_gate_fixture"
mutate_once "$system_gate_fixture/tests/system.sh" 'seq 1 100' 'seq 1 10'
expect_rejection 'suite-contract falsifier rejects reduced concurrency pressure' \
  python3 "$ROOT/tests/suite_contract.py" "$system_gate_fixture"

security_gate_fixture="$TMP_ROOT/security-gate-drift"
cp -R "$suite_base_fixture" "$security_gate_fixture"
mutate_once "$security_gate_fixture/tests/security.sh" \
  'AKIA[0-9A-Z]{16}' 'AKIA[0-9A-Z]{8}'
expect_rejection 'suite-contract falsifier rejects weakened secret detection' \
  python3 "$ROOT/tests/suite_contract.py" "$security_gate_fixture"

ci_fixture="$TMP_ROOT/ci-drift"
cp -R "$suite_base_fixture" "$ci_fixture"
mutate_once "$ci_fixture/.github/workflows/test.yml" \
  'run: bash tests/system.sh' 'run: true'
expect_rejection 'suite-contract falsifier rejects a disconnected CI deep gate' \
  python3 "$ROOT/tests/suite_contract.py" "$ci_fixture"

protection_fixture="$TMP_ROOT/protection-drift"
cp -R "$suite_base_fixture" "$protection_fixture"
mutate_once "$protection_fixture/.github/CODEOWNERS" '/spec/' '/unowned-spec/'
expect_rejection 'suite-contract falsifier rejects a lost CODEOWNER boundary' \
  python3 "$ROOT/tests/suite_contract.py" "$protection_fixture"

bash_behavior_fixture="$TMP_ROOT/bash-behavior-drift"
cp -R "$suite_base_fixture" "$bash_behavior_fixture"
mutate_once "$bash_behavior_fixture/scripts/helpers.sh" 'cut -c1-8' 'cut -c1-7'
expect_rejection 'Bash behavior suite rejects a seeded production regression' \
  bash "$bash_behavior_fixture/tests/run.sh"

source_cycle_fixture="$TMP_ROOT/source-cycle"
make_fixture "$source_cycle_fixture"
# shellcheck disable=SC2016 # the mutation fixture must contain a literal $DIR
printf '\n. "$DIR/daemon.sh"\n' >>"$source_cycle_fixture/scripts/helpers.sh"
expect_rejection 'architecture falsifier rejects a Bash source cycle' \
  bash "$ROOT/tests/architecture.sh" "$source_cycle_fixture"

rust_direction_fixture="$TMP_ROOT/rust-direction"
make_fixture "$rust_direction_fixture"
printf '\nuse crate::model::Config;\n' >>"$rust_direction_fixture/daemon/src/protocol.rs"
expect_rejection 'architecture falsifier rejects an outward Rust dependency' \
  bash "$ROOT/tests/architecture.sh" "$rust_direction_fixture"

quality_fixture="$TMP_ROOT/quality-limit"
make_fixture "$quality_fixture"
for _line in $(seq 1 400); do
  printf '# forced quality-budget mutation\n' >>"$quality_fixture/scripts/daemon.sh"
done
expect_rejection 'quality falsifier rejects an oversized source file' \
  bash "$ROOT/tests/quality.sh" "$quality_fixture"

function_length_fixture="$TMP_ROOT/function-length"
make_fixture "$function_length_fixture"
{
  printf '\noversized_function() {\n'
  for _line in $(seq 1 59); do
    printf '  # seeded function-length fault\n'
  done
  printf '}\n'
} >>"$function_length_fixture/scripts/daemon.sh"
expect_rejection 'quality falsifier rejects a function longer than 60 lines' \
  bash "$ROOT/tests/quality.sh" "$function_length_fixture"

complexity_fixture="$TMP_ROOT/function-complexity"
make_fixture "$complexity_fixture"
{
  printf '\nseeded_complexity() {\n'
  for _line in $(seq 1 10); do
    printf '  if true; then printf x; fi\n'
  done
  printf '}\n'
} >>"$complexity_fixture/scripts/daemon.sh"
expect_rejection 'quality falsifier rejects cyclomatic complexity above 10' \
  bash "$ROOT/tests/quality.sh" "$complexity_fixture"

duplication_fixture="$TMP_ROOT/duplication"
make_fixture "$duplication_fixture"
for target in daemon.sh event.sh; do
  for _line in $(seq 1 50); do
    printf 'seeded_duplicate_%s=true\n' "$_line"
  done >>"$duplication_fixture/scripts/$target"
done
expect_rejection 'quality falsifier rejects duplicate code above one percent' \
  bash "$ROOT/tests/quality.sh" "$duplication_fixture"

gherkin_fixture="$TMP_ROOT/gherkin-binding"
make_fixture "$gherkin_fixture"
mkdir -p "$gherkin_fixture/spec/features" "$gherkin_fixture/tests"
cp "$ROOT/spec/acceptance-map.tsv" "$gherkin_fixture/spec/acceptance-map.tsv"
cp "$ROOT/spec/features/session_safety.feature" "$gherkin_fixture/spec/features/session_safety.feature"
cp "$ROOT/tests/run.sh" "$gherkin_fixture/tests/run.sh"
printf '\n  Scenario: Unbound executable requirement\n    Then no test can adjudicate it\n' \
  >>"$gherkin_fixture/spec/features/session_safety.feature"
expect_rejection 'Gherkin falsifier rejects a scenario without an executable test binding' \
  python3 "$ROOT/tests/gherkin_contract.py" "$gherkin_fixture"

rename_fixture="$TMP_ROOT/acceptance-rename"
make_fixture "$rename_fixture"
mkdir -p "$rename_fixture/spec/features" "$rename_fixture/tests"
cp "$ROOT/spec/acceptance-map.tsv" "$rename_fixture/spec/acceptance-map.tsv"
cp "$ROOT/spec/features/session_safety.feature" "$rename_fixture/spec/features/session_safety.feature"
cp "$ROOT/tests/run.sh" "$rename_fixture/tests/run.sh"
mutate_once "$rename_fixture/tests/run.sh" \
  'picker Enter cannot open a session ID injected through metadata' \
  'renamed immutable open adjudication'
mutate_once "$rename_fixture/daemon/src/model/tests_state.rs" \
  'fn idle_detection_on_unwatched_working_pane_becomes_done()' \
  'fn renamed_unseen_completion_adjudication()'
if python3 "$ROOT/tests/gherkin_contract.py" "$rename_fixture" >/dev/null; then
  pass 'acceptance bindings survive behavior-preserving test renames'
else
  fail 'acceptance bindings survive behavior-preserving test renames'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

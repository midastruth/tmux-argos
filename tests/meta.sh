#!/usr/bin/env bash
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# shellcheck disable=SC2016 # mutant replacements intentionally contain literal shell variables
# Capability-level mutation tests for the Bash/tmux boundary. Test source may be
# refactored, but it must continue rejecting every seeded production fault.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-argos-bash-mutants.$$"
BASE_FIXTURE="$TMP_ROOT/base"
MAX_PARALLEL=3
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_fixture() {
  local destination="$1"
  mkdir -p "$destination/tests"
  cp "$ROOT/tmux-argos.tmux" "$destination/tmux-argos.tmux"
  cp -R "$ROOT/scripts" "$destination/scripts"
  cp "$ROOT/tests/run.sh" "$destination/tests/run.sh"
  cp -R "$ROOT/tests/lib" "$destination/tests/lib"
}

replace_once() {
  local path="$1" old_text="$2" new_text="$3"
  python3 - "$path" "$old_text" "$new_text" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old_text = sys.argv[2]
new_text = sys.argv[3]
source = path.read_text()
count = source.count(old_text)
if count != 1:
    raise SystemExit(f"expected one mutation target in {path}, found {count}")
path.write_text(source.replace(old_text, new_text))
PY
}

apply_mutant() {
  local name="$1" fixture="$2"
  case "$name" in
  shortened-session-hash)
    replace_once "$fixture/scripts/helpers.sh" 'cut -c1-8' 'cut -c1-7'
    ;;
  stale-row-opens-reused-name)
    replace_once "$fixture/scripts/picker/actions.sh" \
      'session) open_session_target "$session_id" ;;' \
      'session) open_session_target "$target" ;;'
    ;;
  single-kill-targets-reused-name)
    replace_once "$fixture/scripts/picker/actions.sh" \
      'if ! tmux kill-session -t "$session_id" 2>/dev/null; then' \
      'if ! tmux kill-session -t "$target" 2>/dev/null; then'
    ;;
  daemon-blocked-state-is-unprotected)
    replace_once "$fixture/scripts/lib/join_protected_sessions.awk" \
      'if (daemon[4] == "working" || daemon[4] == "blocked") {' \
      'if (daemon[4] == "working") {'
    ;;
  malformed-daemon-state-is-accepted)
    replace_once "$fixture/scripts/lib/join_protected_sessions.awk" \
      'daemon[5] !~ /^[0-9]+$/' '0'
    ;;
  pi-history-loses-native-resume-flag)
    replace_once "$fixture/scripts/launch.sh" \
      'pi) cmd="$cmd --session $resume_ref_q" ;;' \
      'pi) cmd="$cmd $resume_ref_q" ;;'
    ;;
  popup-detaches-whole-session)
    replace_once "$fixture/scripts/list.sh" \
      'tmux detach-client -t "$invoking_client"' \
      'tmux detach-client -s "$my_session"'
    ;;
  status-close-detaches-whole-session)
    replace_once "$fixture/scripts/status_click.sh" \
      'exec tmux detach-client -t "$client"' \
      'exec tmux detach-client -s agent-session'
    ;;
  status-fragment-adds-a-fork)
    replace_once "$fixture/tmux-argos.tmux" \
      "tmux set-option -g @agent_summary_badge '#[range=user|agent_list]#{@agent_status_cache}#[norange]'" \
      "tmux set-option -g @agent_summary_badge '#(printf drifted)'"
    ;;
  batch-exit-reports-reusable-name)
    replace_once "$fixture/scripts/event.sh" \
      'request="{\"type\":\"Exited\",\"pane_id\":null,\"session_id\":$(json_string "$session_id")}"' \
      'request="{\"type\":\"Exited\",\"pane_id\":null,\"session_name\":$(json_string "$session_id")}"'
    ;;
  *)
    printf 'unknown mutant: %s\n' "$name" >&2
    return 2
    ;;
  esac
}

run_mutant() {
  local name="$1"
  local fixture="$TMP_ROOT/$name" log="$TMP_ROOT/$name.log"
  cp -R "$BASE_FIXTURE" "$fixture"
  if ! apply_mutant "$name" "$fixture"; then
    printf 'not ok - mutant could not be applied: %s\n' "$name" >&2
    return 2
  fi
  if bash "$fixture/tests/run.sh" >"$log" 2>&1; then
    printf 'not ok - surviving Bash mutant: %s\n' "$name" >&2
    return 1
  fi
  printf 'ok - Bash behavior tests killed mutant: %s\n' "$name"
}

make_fixture "$BASE_FIXTURE"
if ! bash "$BASE_FIXTURE/tests/run.sh" >/dev/null; then
  printf 'not ok - unmutated Bash baseline failed\n' >&2
  exit 1
fi
printf 'ok - unmutated Bash baseline passes\n'

mutants=(
  shortened-session-hash
  stale-row-opens-reused-name
  single-kill-targets-reused-name
  daemon-blocked-state-is-unprotected
  malformed-daemon-state-is-accepted
  pi-history-loses-native-resume-flag
  popup-detaches-whole-session
  status-close-detaches-whole-session
  status-fragment-adds-a-fork
  batch-exit-reports-reusable-name
)

pids=()
for mutant in "${mutants[@]}"; do
  run_mutant "$mutant" &
  pids+=("$!")
  if [ "${#pids[@]}" -eq "$MAX_PARALLEL" ]; then
    for index in "${!pids[@]}"; do
      if wait "${pids[$index]}"; then
        PASS=$((PASS + 1))
      else
        FAIL=$((FAIL + 1))
      fi
    done
    pids=()
  fi
done
for index in "${!pids[@]}"; do
  if wait "${pids[$index]}"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

printf '\n%d Bash mutants killed, %d survived or failed setup\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

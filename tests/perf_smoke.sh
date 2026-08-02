#!/usr/bin/env bash
# shellcheck disable=SC2034 # mock configuration variables are consumed by subprocesses
# shellcheck source-path=SCRIPTDIR
# Smoke performance checks for hot paths. Uses the shared tmux mock, so results
# are stable enough to catch large regressions without a live tmux server.
# Run with: bash tests/perf_smoke.sh
#
# Tunables (environment):
#   PERF_ITERATIONS      measured runs per case (default 7)
#   PERF_WARMUP          discarded warm-up runs per case (default 2)
#   PERF_MAX_PICKER_MS   absolute median threshold for picker.sh (0 disables)
#   PERF_MAX_GROWTH      max allowed median growth when n doubles 50->100
#                        (default 3.5; linear ~2x, quadratic ~4x; 0 disables)
#
# Medians (not means) are compared against thresholds so a single slow run on a
# noisy CI machine does not fail the build. The growth check is machine-speed
# independent and exists to catch algorithmic (per-item cost) regressions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-argos-perf.$$"
MOCK_BIN="$TMP_ROOT/bin"
mkdir -p "$MOCK_BIN"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# shellcheck source=lib/tmux_mock.sh
. "$ROOT/tests/lib/tmux_mock.sh"
install_tmux_mock "$MOCK_BIN"
cat >"$MOCK_BIN/state-daemon" <<'DAEMON_MOCK'
#!/usr/bin/env bash
case "${1:-}" in
snapshot) printf '{"ok":true,"data":{"records":[]}}\n' ;;
snapshot-picker) printf '%s' "${DAEMON_SNAPSHOT_ROWS:-}" ;;
esac
DAEMON_MOCK
chmod +x "$MOCK_BIN/state-daemon"

export PATH="$MOCK_BIN:$PATH"
export AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"
export AGENT_SESSION_PREFIX='agent-'
export AGENT_DETECT_COMMANDS='pi codex claude'
export AGENT_DETECT_WRAPPERS='node bun npx npm pnpm yarn'

# --- timing -------------------------------------------------------------
# Prefer $EPOCHREALTIME (bash >= 5, no subprocess, microsecond precision),
# then date +%s%N, then python3. Refuse to run with second-only precision:
# averaged sub-second measurements would be meaningless.
now_ns() {
  local t ns
  if [ -n "${EPOCHREALTIME:-}" ]; then
    t="${EPOCHREALTIME//[.,]/}" # sec.usec -> usec
    printf '%s000' "$t"
    return 0
  fi
  ns="$(date +%s%N 2>/dev/null || true)"
  if [[ "$ns" =~ ^[0-9]+$ ]]; then
    printf '%s' "$ns"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.time_ns())'
    return 0
  fi
  return 1
}

if ! now_ns >/dev/null; then
  printf 'SKIP - no sub-second clock available (bash5/date +%%N/python3)\n' >&2
  exit 0
fi

ms_from_ns() {
  awk -v ns="$1" 'BEGIN { printf "%.1f", ns / 1000000 }'
}

FAILURES=0

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'not ok - %s\n' "$1" >&2
}

# measure <label> <command> -> sets PERF_MEDIAN_MS; prints a summary line.
# Runs PERF_WARMUP discarded warm-up iterations (page cache, bash parse) then
# PERF_ITERATIONS measured ones, reporting min/median/max.
measure() {
  local label="$1" cmd="$2" i start end
  local -a samples=()

  for ((i = 0; i < warmup; i++)); do
    (cd "$ROOT" && bash -c "$cmd") >/dev/null
  done

  for ((i = 0; i < iterations; i++)); do
    start="$(now_ns)"
    (cd "$ROOT" && bash -c "$cmd") >/dev/null
    end="$(now_ns)"
    samples+=($((end - start)))
  done

  local -a sorted=()
  while IFS= read -r line; do sorted+=("$line"); done \
    < <(printf '%s\n' "${samples[@]}" | sort -n)
  local median_ns="${sorted[$((iterations / 2))]}"
  local min_ns="${sorted[0]}"
  local max_ns="${sorted[$((iterations - 1))]}"

  PERF_MEDIAN_MS="$(ms_from_ns "$median_ns")"
  printf '%-24s %2s+%s runs  min=%8sms  median=%8sms  max=%8sms\n' \
    "$label" "$warmup" "$iterations" \
    "$(ms_from_ns "$min_ns")" "$PERF_MEDIAN_MS" "$(ms_from_ns "$max_ns")"
}

build_case() {
  local n="$1" now sessions='' panes_status='' panes_picker='' opts='' daemon_rows=''
  local i state tool cmd path session_id pane manual_state manual_session_id
  now="$(date +%s)"
  for i in $(seq 1 "$n"); do
    case $((i % 4)) in
      0) state='blocked' ;;
      1) state='working' ;;
      2) state='done' ;;
      *) state='idle' ;;
    esac
    case $((i % 3)) in
      0) tool='claude'; cmd='claude' ;;
      1) tool='pi'; cmd='pi' ;;
      *) tool='codex'; cmd='codex' ;;
    esac
    path="/tmp/project-$i"
    session_id="\$$i"
    sessions+="agent-$tool-$i	$session_id	$state	$now	$path	$tool	$cmd"$'\n'
    daemon_rows+="agent-$tool-$i"$'\037'"$session_id"$'\037'"%m$i"$'\037'"$state"$'\037'"$now"$'\n'

    pane="%$i"
    manual_state="$state"
    panes_status+="work-$i	$pane"$'\n'
    panes_picker+="work-$i	$pane	$cmd	$((1000 + i))	/tmp/manual-$i"$'\n'
    opts+="$pane|@agent_state=$manual_state"$'\n'
    opts+="$pane|@agent_state_at=$now"$'\n'
    manual_session_id="\$$((n + i))"
    daemon_rows+="work-$i"$'\037'"$manual_session_id"$'\037'"$pane"$'\037'"$manual_state"$'\037'"$now"$'\n'
  done

  export TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_detect_commands=pi codex claude\n@agent_detect_wrappers=node bun npx npm pnpm yarn'
  export TMUX_MOCK_LIST_SESSIONS="${sessions%$'\n'}"
  export TMUX_MOCK_LIST_PANES_STATUS="${panes_status%$'\n'}"
  export TMUX_MOCK_LIST_PANES_PICKER="${panes_picker%$'\n'}"
  export TMUX_MOCK_TARGET_OPTIONS="${opts%$'\n'}"
  export DAEMON_SNAPSHOT_ROWS="${daemon_rows%$'\n'}"
}

check_threshold() {
  local label="$1" median="$2" max="$3"
  [ "$max" = 0 ] && return 0
  awk -v m="$median" -v max="$max" 'BEGIN { exit !(m <= max) }' ||
    fail "$label median ${median}ms exceeded threshold ${max}ms"
}

# check_growth <label> <median at n=50> <median at n=100>
# Machine-independent scaling check: when the input doubles, the median must
# not grow by more than PERF_MAX_GROWTH. Linear scaling gives <= ~2x (fixed
# startup cost pulls it below 2); quadratic gives ~4x.
check_growth() {
  local label="$1" small="$2" big="$3"
  [ "$max_growth" = 0 ] && return 0
  awk -v s="$small" -v b="$big" -v g="$max_growth" \
    'BEGIN { exit !(s <= 0 || b <= s * g) }' || {
    local ratio
    ratio="$(awk -v s="$small" -v b="$big" 'BEGIN { printf "%.2f", b / s }')"
    fail "$label grew ${ratio}x from n=50 to n=100 (max ${max_growth}x); possible per-item cost regression"
  }
}

iterations="${PERF_ITERATIONS:-7}"
warmup="${PERF_WARMUP:-2}"
max_picker_ms="${PERF_MAX_PICKER_MS:-5000}"
max_growth="${PERF_MAX_GROWTH:-3.5}"

printf 'Smoke performance test (mock tmux, %s warmup + %s measured runs/case)\n' "$warmup" "$iterations"
printf 'Thresholds: picker median<=%sms, 50->100 growth<=%sx (0 disables)\n\n' \
  "$max_picker_ms" "$max_growth"

declare -A medians=()

for n in 10 50 100; do
  printf 'case: %s managed sessions + %s manual panes\n' "$n" "$n"
  build_case "$n"
  measure "picker.sh --list n=$n" 'scripts/picker.sh --list'
  medians["picker|$n"]="$PERF_MEDIAN_MS"
  check_threshold "picker.sh --list n=$n" "$PERF_MEDIAN_MS" "$max_picker_ms"
  printf '\n'
done

check_growth 'picker.sh --list' "${medians[picker|50]}" "${medians[picker|100]}"

if [ "$FAILURES" -gt 0 ]; then
  printf 'not ok - performance smoke test: %s check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'ok - performance smoke test completed\n'

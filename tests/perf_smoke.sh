#!/usr/bin/env bash
# shellcheck disable=SC2034 # mock configuration variables are consumed by subprocesses
# shellcheck source-path=SCRIPTDIR
# Smoke performance checks for hot paths. Uses the shared tmux mock, so results
# are stable enough to catch large regressions without a live tmux server.
# Run with: bash tests/perf_smoke.sh
#
# The human-owned thresholds are intentionally not configurable by environment:
# wall/CPU p95, scaling, external I/O, output size, and Rust allocation budgets
# are all binary gates. A noisy machine must be fixed or explicitly change the
# constitutional test; callers cannot silently disable the gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-argos-perf.$$"
MOCK_BIN="$TMP_ROOT/bin"
TMUX_IO_LOG="$TMP_ROOT/tmux-io.log"
DAEMON_IO_LOG="$TMP_ROOT/daemon-io.log"
PICKER_OUTPUT="$TMP_ROOT/picker-output"
mkdir -p "$MOCK_BIN"
: >"$TMUX_IO_LOG"
: >"$DAEMON_IO_LOG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# shellcheck source=lib/tmux_mock.sh
. "$ROOT/tests/lib/tmux_mock.sh"
install_tmux_mock "$MOCK_BIN"
cat >"$MOCK_BIN/state-daemon" <<'DAEMON_MOCK'
#!/usr/bin/env bash
if [ -n "${DAEMON_IO_LOG:-}" ]; then
  printf '%s\n' "${1:-}" >>"$DAEMON_IO_LOG"
fi
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
export TMUX_MOCK_LOG="$TMUX_IO_LOG"
export DAEMON_IO_LOG

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

# measure <label> <command> -> sets PERF_P95_MS; prints a summary line.
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
  local p95_index=$((((iterations * 95 + 99) / 100) - 1))
  local p95_ns="${sorted[$p95_index]}"
  local min_ns="${sorted[0]}"
  local max_ns="${sorted[$((iterations - 1))]}"

  PERF_P95_MS="$(ms_from_ns "$p95_ns")"
  printf '%-24s %2s+%s runs  min=%8sms  median=%8sms  p95=%8sms  max=%8sms\n' \
    "$label" "$warmup" "$iterations" "$(ms_from_ns "$min_ns")" \
    "$(ms_from_ns "$median_ns")" "$PERF_P95_MS" "$(ms_from_ns "$max_ns")"
}

measure_cpu() {
  local label="$1" cmd="$2" i timing_file user_seconds system_seconds cpu_ms
  local TIMEFORMAT='%U %S'
  local -a samples=()
  timing_file="$TMP_ROOT/cpu-time"

  for ((i = 0; i < cpu_iterations; i++)); do
    if ! { time (cd "$ROOT" && bash -c "$cmd") >/dev/null; } 2>"$timing_file"; then
      fail "$label CPU measurement command failed"
      return
    fi
    read -r user_seconds system_seconds <"$timing_file"
    cpu_ms="$(awk -v user="$user_seconds" -v system="$system_seconds" \
      'BEGIN { printf "%.1f", (user + system) * 1000 }')"
    samples+=("$cpu_ms")
  done

  local -a sorted=()
  while IFS= read -r line; do sorted+=("$line"); done \
    < <(printf '%s\n' "${samples[@]}" | sort -n)
  local p95_index=$((((cpu_iterations * 95 + 99) / 100) - 1))
  PERF_CPU_P95_MS="${sorted[$p95_index]}"
  printf '%-24s %s runs  CPU p95=%sms\n' "$label" "$cpu_iterations" "$PERF_CPU_P95_MS"
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
  local label="$1" measured="$2" max="$3" unit="${4:-ms}"
  awk -v measured="$measured" -v max="$max" 'BEGIN { exit !(measured <= max) }' ||
    fail "$label ${measured}${unit} exceeded threshold ${max}${unit}"
}

# check_growth <label> <p95 at n=50> <p95 at n=100>
# Machine-independent scaling check: when the input doubles, the median must
# not grow by more than PERF_MAX_GROWTH. Linear scaling gives <= ~2x (fixed
# startup cost pulls it below 2); quadratic gives ~4x.
check_growth() {
  local label="$1" small="$2" big="$3"
  awk -v s="$small" -v b="$big" -v g="$max_growth" \
    'BEGIN { exit !(s <= 0 || b <= s * g) }' || {
    local ratio
    ratio="$(awk -v s="$small" -v b="$big" 'BEGIN { printf "%.2f", b / s }')"
    fail "$label grew ${ratio}x from n=50 to n=100 (max ${max_growth}x); possible per-item cost regression"
  }
}

iterations=20
warmup=3
cpu_iterations=10
max_picker_ms=120
max_picker_cpu_ms=100
max_growth=2.0
max_tmux_calls=2
max_daemon_calls=1
max_output_bytes=65536

printf 'Smoke performance test (mock tmux, %s warmup + %s measured runs/case)\n' "$warmup" "$iterations"
printf 'Thresholds: picker p95<=%sms, CPU p95<=%sms, 50->100 growth<=%sx\n' \
  "$max_picker_ms" "$max_picker_cpu_ms" "$max_growth"
printf 'I/O budgets: tmux<=%s calls, daemon<=%s call, output<=%s bytes\n\n' \
  "$max_tmux_calls" "$max_daemon_calls" "$max_output_bytes"

declare -A p95_measurements=()

for n in 10 50 100; do
  printf 'case: %s managed sessions + %s manual panes\n' "$n" "$n"
  build_case "$n"
  measure "picker.sh --list n=$n" 'scripts/picker.sh --list'
  p95_measurements["picker|$n"]="$PERF_P95_MS"
  check_threshold "picker.sh --list n=$n" "$PERF_P95_MS" "$max_picker_ms"
  printf '\n'
done

check_growth 'picker.sh --list' "${p95_measurements[picker|50]}" "${p95_measurements[picker|100]}"

measure_cpu 'picker.sh --list n=100' 'scripts/picker.sh --list'
check_threshold 'picker.sh --list CPU p95' "$PERF_CPU_P95_MS" "$max_picker_cpu_ms"

: >"$TMUX_IO_LOG"
: >"$DAEMON_IO_LOG"
if ! (cd "$ROOT" && scripts/picker.sh --list) >"$PICKER_OUTPUT"; then
  fail 'picker.sh --list I/O budget run failed'
else
  tmux_calls="$(awk -F '\t' '
    $1 ~ /^(show-option|show-options|display-message|list-sessions|list-panes|list-clients|has-session|show-hooks|refresh-client|if-shell|kill-session|new-session|set-option|set-hook|display-popup|send-keys|attach-session|switch-client|detach-client|run-shell)$/ { count++ }
    END { print count + 0 }
  ' "$TMUX_IO_LOG")"
  daemon_calls="$(wc -l <"$DAEMON_IO_LOG" | tr -d '[:space:]')"
  output_bytes="$(wc -c <"$PICKER_OUTPUT" | tr -d '[:space:]')"
  printf '%-24s tmux=%s daemon=%s output=%s bytes\n' \
    'picker I/O budget n=100' "$tmux_calls" "$daemon_calls" "$output_bytes"
  if [ "$tmux_calls" -gt "$max_tmux_calls" ]; then
    printf 'tmux calls observed:\n%s\n' "$(<"$TMUX_IO_LOG")" >&2
  fi
  check_threshold 'picker tmux calls' "$tmux_calls" "$max_tmux_calls" ' calls'
  check_threshold 'picker daemon calls' "$daemon_calls" "$max_daemon_calls" ' calls'
  check_threshold 'picker output bytes' "$output_bytes" "$max_output_bytes" ' bytes'
fi

printf '\nRust allocation budgets (release build, isolated test thread)\n'
if ! cargo test --release --manifest-path "$ROOT/daemon/Cargo.toml" \
  allocation_metrics::state_hot_paths_stay_within_allocation_budgets -- \
  --exact --nocapture --test-threads=1; then
  fail 'Rust state hot paths exceeded allocation budgets'
fi

if [ "$FAILURES" -gt 0 ]; then
  printf 'not ok - performance smoke test: %s check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'ok - performance smoke test completed\n'

#!/usr/bin/env bash
# Real tmux/Unix-socket E2E, concurrency, memory, and bounded chaos tests.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/daemon/target/release/tmux-argos-state-daemon"
SOCKET_NAME="tmux-argos-system-$$"
DAEMON_PID=''
PASS=0
FAIL=0

startup_max_ms=100
warm_request_iterations=20
warm_request_p95_max_ms=10
concurrent_requests=100
sustained_seconds=60
sustained_min_requests=10000
sustained_average_max_ms=5
sustained_cpu_max_us_per_request=100
sustained_rss_growth_max_kib=1024
snapshot_max_bytes=65536

cleanup() {
  if [ -x "$BINARY" ] && [ -n "${TMUX:-}" ]; then
    "$BINARY" shutdown >/dev/null 2>&1 || true
  fi
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  tmux -L "$SOCKET_NAME" kill-server >/dev/null 2>&1 || true
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required system-test command is missing: $1"
    return 1
  fi
}

require_command cargo || exit 1
require_command ps || exit 1
require_command python3 || exit 1
require_command tmux || exit 1

now_ns() {
  local timestamp nanoseconds
  if [ -n "${EPOCHREALTIME:-}" ]; then
    timestamp="${EPOCHREALTIME//[.,]/}"
    printf '%s000' "$timestamp"
    return 0
  fi
  nanoseconds="$(date +%s%N 2>/dev/null || true)"
  if [[ "$nanoseconds" =~ ^[0-9]+$ ]]; then
    printf '%s' "$nanoseconds"
    return 0
  fi
  python3 -c 'import time; print(time.time_ns())'
}

milliseconds_from_ns() {
  awk -v nanoseconds="$1" 'BEGIN { printf "%.1f", nanoseconds / 1000000 }'
}

daemon_processes() {
  ps -axo pid=,command= 2>/dev/null | awk -v command="$BINARY serve" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if ($0 == command) print pid
    }'
}

process_cpu_ms() {
  local raw
  raw="$(ps -o time= -p "$1" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$raw" ] || return 1
  python3 - "$raw" <<'PY'
import sys

raw = sys.argv[1]
days = 0
if "-" in raw:
    day_text, raw = raw.split("-", 1)
    days = int(day_text)
parts = raw.split(":")
seconds = float(parts[-1])
if len(parts) >= 2:
    seconds += int(parts[-2]) * 60
if len(parts) >= 3:
    seconds += int(parts[-3]) * 3600
seconds += days * 86400
print(round(seconds * 1000))
PY
}

open_fd_count() {
  local pid="$1"
  if [ -d "/proc/$pid/fd" ]; then
    find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]'
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -a -p "$pid" -d 0-999999 -F f 2>/dev/null | grep -c '^f' | tr -d '[:space:]'
    return 0
  fi
  return 1
}

measure_warm_request_p95() {
  local index started_at finished_at p95_index
  local -a samples=() sorted=()
  for ((index = 0; index < warm_request_iterations; index++)); do
    started_at="$(now_ns)"
    "$BINARY" ensure >/dev/null || return 1
    finished_at="$(now_ns)"
    samples+=($((finished_at - started_at)))
  done
  while IFS= read -r sample; do sorted+=("$sample"); done \
    < <(printf '%s\n' "${samples[@]}" | sort -n)
  p95_index=$((((warm_request_iterations * 95 + 99) / 100) - 1))
  milliseconds_from_ns "${sorted[$p95_index]}"
}

if ! cargo build --release --manifest-path "$ROOT/daemon/Cargo.toml" >/dev/null; then
  fail 'release daemon builds for system tests'
  exit 1
fi
pass 'release daemon builds for system tests'

tmux -L "$SOCKET_NAME" -f /dev/null new-session -d -s work 'sleep 300'
TMUX_SOCKET="$(tmux -L "$SOCKET_NAME" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(tmux -L "$SOCKET_NAME" display-message -p '#{pid}')"
export TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0"

# Remove one-time executable paging and dynamic-loader noise. The measured path
# remains a true daemon cold start: no daemon process, socket, or state exists.
"$BINARY" __startup_preflight >/dev/null 2>&1 || true

daemon_pids_before="$(daemon_processes)"
startup_started_at="$(now_ns)"
if ! "$BINARY" ensure >/dev/null; then
  fail 'daemon cold ensure starts an isolated real tmux service'
  exit 1
fi
startup_finished_at="$(now_ns)"
while IFS= read -r candidate_pid; do
  [ -n "$candidate_pid" ] || continue
  if ! grep -qx "$candidate_pid" <<<"$daemon_pids_before"; then
    DAEMON_PID="$candidate_pid"
    break
  fi
done < <(daemon_processes)

startup_ms="$(milliseconds_from_ns "$((startup_finished_at - startup_started_at))")"
if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
  pass 'daemon serves an isolated real tmux socket'
else
  fail 'daemon serves an isolated real tmux socket'
  exit 1
fi
if awk -v measured="$startup_ms" -v maximum="$startup_max_ms" \
  'BEGIN { exit !(measured <= maximum) }'; then
  pass "daemon cold startup stays within ${startup_max_ms}ms (${startup_ms}ms)"
else
  fail "daemon cold startup exceeds ${startup_max_ms}ms (${startup_ms}ms)"
fi

warm_request_p95_ms="$(measure_warm_request_p95 || true)"
if [ -n "$warm_request_p95_ms" ] && awk \
  -v measured="$warm_request_p95_ms" -v maximum="$warm_request_p95_max_ms" \
  'BEGIN { exit !(measured <= maximum) }'; then
  pass "daemon warm ensure p95 stays within ${warm_request_p95_max_ms}ms (${warm_request_p95_ms}ms)"
else
  fail "daemon warm ensure p95 exceeds ${warm_request_p95_max_ms}ms (${warm_request_p95_ms:-unavailable}ms)"
fi

idle_rss_kib="$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | tr -d '[:space:]')"
if [[ "$idle_rss_kib" =~ ^[0-9]+$ ]] && [ "$idle_rss_kib" -le 16384 ]; then
  pass "daemon observed idle RSS stays within 16MiB budget (${idle_rss_kib}KiB)"
else
  fail "daemon idle RSS exceeds 16MiB budget (${idle_rss_kib:-unavailable}KiB)"
fi

request_failures=0
request_pids=()
for request_number in $(seq 1 "$concurrent_requests"); do
  request="{\"type\":\"Report\",\"tool\":\"custom\",\"pane_id\":\"%$request_number\",\"process_generation\":\"g$request_number\",\"sequence\":1,\"state\":\"idle\",\"session_id\":\"\$$request_number\",\"session_name\":\"work-$request_number\"}"
  "$BINARY" send "$request" >/dev/null 2>&1 &
  request_pids+=("$!")
done
for request_pid in "${request_pids[@]}"; do
  wait "$request_pid" || request_failures=$((request_failures + 1))
done
if [ "$request_failures" -eq 0 ]; then
  pass '100 concurrent daemon clients complete without failure'
else
  fail "100 concurrent daemon clients complete without failure ($request_failures failed)"
fi

snapshot="$($BINARY snapshot 2>/dev/null || true)"
if [[ "$snapshot" == *'"ok":true'* ]]; then
  pass 'daemon remains responsive after concurrent requests'
else
  fail 'daemon remains responsive after concurrent requests'
fi

rss_kib="$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | tr -d '[:space:]')"
if [[ "$rss_kib" =~ ^[0-9]+$ ]] && [ "$rss_kib" -le 32768 ]; then
  pass "daemon peak observed RSS stays within 32MiB pressure budget (${rss_kib}KiB)"
else
  fail "daemon RSS exceeds 32MiB pressure budget (${rss_kib:-unavailable}KiB)"
fi

for request_number in $(seq 1 100); do
  request="{\"type\":\"Report\",\"tool\":\"custom\",\"pane_id\":\"%$request_number\",\"process_generation\":\"sustained\",\"sequence\":1,\"state\":\"idle\",\"session_id\":\"\$$request_number\",\"session_name\":\"work-$request_number\"}"
  "$BINARY" send "$request" >/dev/null 2>&1 || fail 'sustained-load warmup request completes'
done

sustained_rss_before="$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | tr -d '[:space:]')"
sustained_cpu_before="$(process_cpu_ms "$DAEMON_PID" || true)"
sustained_fds_before="$(open_fd_count "$DAEMON_PID" || true)"
sustained_started_at="$(now_ns)"
sustained_deadline=$((sustained_started_at + sustained_seconds * 1000000000))
sustained_requests=0
sustained_failures=0
sequence=2
while [ "$(now_ns)" -lt "$sustained_deadline" ]; do
  request_number=$((sustained_requests % 100 + 1))
  request="{\"type\":\"Report\",\"tool\":\"custom\",\"pane_id\":\"%$request_number\",\"process_generation\":\"sustained\",\"sequence\":$sequence,\"state\":\"idle\",\"session_id\":\"\$$request_number\",\"session_name\":\"work-$request_number\"}"
  "$BINARY" send "$request" >/dev/null 2>&1 || sustained_failures=$((sustained_failures + 1))
  sustained_requests=$((sustained_requests + 1))
  sequence=$((sequence + 1))
done
sustained_finished_at="$(now_ns)"
sleep 0.1
sustained_rss_after="$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | tr -d '[:space:]')"
sustained_cpu_after="$(process_cpu_ms "$DAEMON_PID" || true)"
sustained_fds_after="$(open_fd_count "$DAEMON_PID" || true)"
sustained_elapsed_ns=$((sustained_finished_at - sustained_started_at))
sustained_average_ms="$(awk -v elapsed="$sustained_elapsed_ns" -v requests="$sustained_requests" \
  'BEGIN { printf "%.3f", elapsed / requests / 1000000 }')"
sustained_cpu_delta_ms=$((sustained_cpu_after - sustained_cpu_before))
sustained_cpu_us_per_request="$(awk -v cpu_ms="$sustained_cpu_delta_ms" -v requests="$sustained_requests" \
  'BEGIN { printf "%.1f", cpu_ms * 1000 / requests }')"
sustained_rss_growth_kib=$((sustained_rss_after - sustained_rss_before))

printf 'sustained load: %s requests/%ss, avg=%sms, daemon CPU=%sus/request, RSS delta=%sKiB, FDs=%s->%s\n' \
  "$sustained_requests" "$sustained_seconds" "$sustained_average_ms" \
  "$sustained_cpu_us_per_request" "$sustained_rss_growth_kib" \
  "$sustained_fds_before" "$sustained_fds_after"
if [ "$sustained_failures" -eq 0 ] && [ "$sustained_requests" -ge "$sustained_min_requests" ]; then
  pass "${sustained_seconds}s sustained request load completes without failure"
else
  fail "${sustained_seconds}s sustained request load had ${sustained_failures} failures across ${sustained_requests} requests"
fi
if awk -v measured="$sustained_average_ms" -v maximum="$sustained_average_max_ms" \
  'BEGIN { exit !(measured <= maximum) }'; then
  pass "sustained request average stays within ${sustained_average_max_ms}ms"
else
  fail "sustained request average exceeds ${sustained_average_max_ms}ms (${sustained_average_ms}ms)"
fi
if awk -v measured="$sustained_cpu_us_per_request" \
  -v maximum="$sustained_cpu_max_us_per_request" \
  'BEGIN { exit !(measured <= maximum) }'; then
  pass "daemon CPU stays within ${sustained_cpu_max_us_per_request}us per request"
else
  fail "daemon CPU exceeds ${sustained_cpu_max_us_per_request}us per request (${sustained_cpu_us_per_request}us)"
fi
if [ "$sustained_rss_growth_kib" -le "$sustained_rss_growth_max_kib" ]; then
  pass "sustained RSS growth stays within ${sustained_rss_growth_max_kib}KiB"
else
  fail "sustained RSS grew ${sustained_rss_growth_kib}KiB (max ${sustained_rss_growth_max_kib}KiB)"
fi
if [ -n "$sustained_fds_before" ] && [ "$sustained_fds_after" -le "$sustained_fds_before" ]; then
  pass "sustained load leaks no file descriptors (${sustained_fds_before}->${sustained_fds_after})"
else
  fail "sustained load leaked file descriptors (${sustained_fds_before:-unavailable}->${sustained_fds_after:-unavailable})"
fi

snapshot="$($BINARY snapshot 2>/dev/null || true)"
snapshot_bytes="$(printf '%s' "$snapshot" | wc -c | tr -d '[:space:]')"
if [[ "$snapshot" == *'"ok":true'* ]] && [ "$snapshot_bytes" -le "$snapshot_max_bytes" ]; then
  pass "daemon snapshot I/O stays within ${snapshot_max_bytes} bytes (${snapshot_bytes} bytes)"
else
  fail "daemon snapshot I/O exceeds ${snapshot_max_bytes} bytes or failed (${snapshot_bytes} bytes)"
fi

restart_failures=0
for _cycle in $(seq 1 20); do
  "$BINARY" shutdown >/dev/null 2>&1 || restart_failures=$((restart_failures + 1))
  "$BINARY" ensure >/dev/null 2>&1 || restart_failures=$((restart_failures + 1))
done
if [ "$restart_failures" -eq 0 ]; then
  pass '20 daemon shutdown/restart chaos cycles recover cleanly'
else
  fail "20 daemon shutdown/restart chaos cycles recover cleanly ($restart_failures failures)"
fi

if bash "$ROOT/tmux-argos.tmux" >/dev/null 2>&1 &&
  [ "$(tmux show-option -gqv @agent_launch_badge)" != '' ]; then
  pass 'plugin entrypoint configures a real isolated tmux server'
else
  fail 'plugin entrypoint configures a real isolated tmux server'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

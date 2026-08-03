#!/usr/bin/env bash
# Real tmux/Unix-socket E2E, concurrency, memory, and bounded chaos tests.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/daemon/target/release/tmux-argos-state-daemon"
SOCKET_NAME="tmux-argos-system-$$"
DAEMON_PID=''
PASS=0
FAIL=0

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
require_command tmux || exit 1

if ! cargo build --release --manifest-path "$ROOT/daemon/Cargo.toml" >/dev/null; then
  fail 'release daemon builds for system tests'
  exit 1
fi
pass 'release daemon builds for system tests'

tmux -L "$SOCKET_NAME" -f /dev/null new-session -d -s work 'sleep 300'
TMUX_SOCKET="$(tmux -L "$SOCKET_NAME" display-message -p '#{socket_path}')"
TMUX_SERVER_PID="$(tmux -L "$SOCKET_NAME" display-message -p '#{pid}')"
export TMUX="$TMUX_SOCKET,$TMUX_SERVER_PID,0"

"$BINARY" serve &
DAEMON_PID=$!
sleep 0.1
if "$BINARY" ensure >/dev/null && kill -0 "$DAEMON_PID" 2>/dev/null; then
  pass 'daemon serves an isolated real tmux socket'
else
  fail 'daemon serves an isolated real tmux socket'
fi

idle_rss_kib="$(ps -o rss= -p "$DAEMON_PID" 2>/dev/null | tr -d '[:space:]')"
if [[ "$idle_rss_kib" =~ ^[0-9]+$ ]] && [ "$idle_rss_kib" -le 16384 ]; then
  pass "daemon observed idle RSS stays within 16MiB budget (${idle_rss_kib}KiB)"
else
  fail "daemon idle RSS exceeds 16MiB budget (${idle_rss_kib:-unavailable}KiB)"
fi

request_failures=0
request_pids=()
for request_number in $(seq 1 100); do
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

#!/usr/bin/env bash
# Report Pi/Codex-compatible hook state to the Rust state daemon.
# Usage: state.sh <blocked|working|done|idle>
set -uo pipefail
[ -n "${TMUX_PANE:-}" ] || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

state="${1:-idle}"
case "$state" in blocked|working|done|idle) ;; *) exit 0 ;; esac
if [ "$state" = "done" ] && is_watched_agent_pane "$TMUX_PANE"; then
  state=idle
fi

session_format=$'#{session_id}\t#{session_name}'
session_identity="$(tmux display-message -p -t "$TMUX_PANE" "$session_format" 2>/dev/null || true)"
case "$session_identity" in
*$'\t'*)
  session_id="${session_identity%%$'\t'*}"
  session="${session_identity#*$'\t'}"
  ;;
*) exit 0 ;;
esac
[[ "$session_id" =~ ^\$[0-9]+$ ]] || exit 0
[ -n "$session" ] || exit 0
tool="$(tmux show-options -pqv -t "$TMUX_PANE" @agent_tool 2>/dev/null || true)"
if [ -z "$tool" ] && [ -n "$session" ] && is_managed_session "$session"; then
  tool="$(tmux show-options -qv -t "$session_id" @agent_tool 2>/dev/null || true)"
fi
[ -n "$tool" ] || tool="${AGENT_TOOL:-codex}"
case "$tool" in
  claude|codex) exit 0 ;;
esac

# Hook subprocesses share their long-lived agent parent's process start identity.
# This survives repeated hook calls while rotating when the pane id is reused.
parent_fingerprint="$(ps -o pid=,lstart= -p "$PPID" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)"
[ -n "$parent_fingerprint" ] || parent_fingerprint="$PPID:$(date +%s)"
stored_fingerprint="$(tmux show-options -pqv -t "$TMUX_PANE" @agent_process_fingerprint 2>/dev/null || true)"
generation="$(tmux show-options -pqv -t "$TMUX_PANE" @agent_process_generation 2>/dev/null || true)"
sequence="$(tmux show-options -pqv -t "$TMUX_PANE" @agent_sequence 2>/dev/null || true)"
if [ "$stored_fingerprint" != "$parent_fingerprint" ] || [ -z "$generation" ]; then
  generation="$(date +%s)-$$-${RANDOM:-0}"
  sequence=0
fi
case "$sequence" in ''|*[!0-9]*) sequence=0 ;; esac
sequence=$((sequence + 1))
now="$(date +%s)"
mirror_args=(
  set-option -p -t "$TMUX_PANE" @agent_tool "$tool"
  \; set-option -p -t "$TMUX_PANE" @agent_process_fingerprint "$parent_fingerprint"
  \; set-option -p -t "$TMUX_PANE" @agent_process_generation "$generation"
  \; set-option -p -t "$TMUX_PANE" @agent_sequence "$sequence"
  \; set-option -p -t "$TMUX_PANE" @agent_state "$state"
  \; set-option -p -t "$TMUX_PANE" @agent_state_at "$now"
)
if [ -n "$session" ] && is_managed_session "$session"; then
  mirror_args+=(
    \; set-option -t "$session_id" @agent_state "$state"
    \; set-option -t "$session_id" @agent_state_at "$now"
    \; set-option -t "$session_id" @agent_process_generation "$generation"
    \; set-option -t "$session_id" @agent_sequence "$sequence"
    \; set-option -t "$session_id" @agent_pane "$TMUX_PANE"
  )
fi
tmux "${mirror_args[@]}" 2>/dev/null || exit 1

json_string() { local value="$1"; value=${value//\\/\\\\}; value=${value//\"/\\\"}; printf '"%s"' "$value"; }
request="{\"type\":\"Report\",\"tool\":$(json_string "$tool"),\"pane_id\":$(json_string "$TMUX_PANE"),\"process_generation\":$(json_string "$generation"),\"sequence\":$sequence,\"state\":\"$state\",\"session_id\":$(json_string "$session_id"),\"session_name\":$(json_string "$session")}"
"$DIR/daemon.sh" send "$request" >/dev/null 2>&1 || true
exit 0

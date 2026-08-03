#!/usr/bin/env bash
# Shared helpers for tmux-argos.

# Absolute directory of this helpers file, used by lifecycle event helpers.
if [ -z "${STATUS_HELPERS_DIR:-}" ]; then
  __helpers_src="${BASH_SOURCE[0]}"
  __helpers_dir="${__helpers_src%/*}"
  [ "$__helpers_dir" = "$__helpers_src" ] && __helpers_dir=.
  STATUS_HELPERS_DIR="$(cd "$__helpers_dir" 2>/dev/null && pwd)"
  unset __helpers_src __helpers_dir
fi

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

agent_session_prefix() {
  if [ -n "${AGENT_SESSION_PREFIX:-}" ]; then
    printf '%s' "$AGENT_SESSION_PREFIX"
  else
    get_tmux_option @agent_session_prefix 'agent-'
  fi
}

is_managed_session() {
  local session="$1" prefix
  if [ -n "${AGENT_SESSION_PREFIX:-}" ]; then
    prefix="$AGENT_SESSION_PREFIX"
  else
    prefix="$(get_tmux_option @agent_session_prefix 'agent-')"
  fi
  [[ "$session" == "$prefix"* ]]
}

# is_pane_visible <pane>
# Succeeds when a client is currently looking at <pane>: its session is
# attached, its window is the active window, and it is the active pane there.
# tmux can only detect client attachment, not terminal focus, so an attached but
# unfocused terminal can still count as visible.
is_pane_visible() {
  local pane="$1" out attached win_active pane_active
  [ -n "$pane" ] || return 1
  out="$(tmux display-message -p -t "$pane" \
    '#{session_attached} #{window_active} #{pane_active}' 2>/dev/null)"
  [ -n "$out" ] || return 1
  read -r attached win_active pane_active <<EOF
$out
EOF
  [ "$attached" != 0 ] && [ "$win_active" = 1 ] && [ "$pane_active" = 1 ]
}

# is_watched_agent_pane <pane>
# Succeeds when tmux reports that <pane> is currently visible: its session is
# attached, its window is active, and it is the active pane. Used to skip a stale
# "done" badge when the user watched the turn finish in the current pane.
is_watched_agent_pane() {
  is_pane_visible "$1"
}

# mark_managed_session_seen_if_done <session>
# Opening a managed session that has reported session-scoped "done" marks that
# finished turn as seen. State reporters may write both session-scoped and
# pane-scoped @agent_state; tmux formats such as #{@agent_state} may prefer a
# pane option, so also clear pane-scoped "done" values. A stale pane-scoped
# "done" must not reset an authoritative session-level "working"/"blocked"
# state.
mark_managed_session_seen_if_done() {
  local session="$1" session_state pane pane_state now event_q
  session_state="$(tmux show-options -qv -t "$session" @agent_state 2>/dev/null || true)"
  now="$(date +%s)"
  if [ "$session_state" = "done" ]; then
    tmux set-option -t "$session" @agent_state idle \
      \; set-option -t "$session" @agent_state_at "$now" 2>/dev/null || true
  fi
  event_q="$(printf '%q' "$STATUS_HELPERS_DIR/event.sh")"
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    pane_state="$(tmux show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
    if [ "$pane_state" = "done" ]; then
      tmux set-option -p -t "$pane" @agent_state idle \
        \; set-option -p -t "$pane" @agent_state_at "$now" 2>/dev/null || true
    fi
    tmux run-shell -b "$event_q seen-pane $(printf '%q' "$pane")" 2>/dev/null || true
  done < <(tmux list-panes -s -t "$session" -F '#{pane_id}' 2>/dev/null)
}

# mark_pane_seen_if_done <pane>
mark_pane_seen_if_done() {
  local pane="$1" state now event_q
  state="$(tmux show-options -pqv -t "$pane" @agent_state 2>/dev/null || true)"
  if [ "$state" = "done" ]; then
    now="$(date +%s)"
    tmux set-option -p -t "$pane" @agent_state idle \
      \; set-option -p -t "$pane" @agent_state_at "$now" 2>/dev/null || true
  fi
  event_q="$(printf '%q' "$STATUS_HELPERS_DIR/event.sh")"
  tmux run-shell -b "$event_q seen-pane $(printf '%q' "$pane")" 2>/dev/null || true
}

# detect_commands
# Space-separated list of agent commands the picker/status line auto-detect when
# they are running directly in a tmux pane (manual, non-managed sessions).
# Override with: set -g @agent_detect_commands 'pi codex claude aider'
detect_commands() {
  if [ -n "${AGENT_DETECT_COMMANDS:-}" ]; then
    printf '%s' "$AGENT_DETECT_COMMANDS"
  else
    get_tmux_option @agent_detect_commands 'pi codex claude'
  fi
}

# wrapper_commands
# Space-separated list of command basenames whose descendants may contain a
# real agent process. Keeping this narrow avoids scanning every ordinary shell,
# editor, or build pane on each picker/status refresh. Override with:
#   set -g @agent_detect_wrappers 'node bun npx npm pnpm yarn my-wrapper'
wrapper_commands() {
  if [ -n "${AGENT_DETECT_WRAPPERS:-}" ]; then
    printf '%s' "$AGENT_DETECT_WRAPPERS"
  else
    get_tmux_option @agent_detect_wrappers 'node bun npx npm pnpm yarn'
  fi
}

# contains_word <word> <space-separated-list>
contains_word() {
  case " $2 " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# is_detected_command <command-basename>
# Succeeds when <command-basename> is in the detect_commands list.
is_detected_command() {
  local commands
  if [ -n "${AGENT_DETECT_COMMANDS:-}" ]; then
    commands="$AGENT_DETECT_COMMANDS"
  else
    commands="$(get_tmux_option @agent_detect_commands 'pi codex claude')"
  fi
  contains_word "$1" "$commands"
}

# is_wrapper_command <command-basename>
# Succeeds when <command-basename> is allowed to trigger process-subtree scans.
is_wrapper_command() {
  local commands
  if [ -n "${AGENT_DETECT_WRAPPERS:-}" ]; then
    commands="$AGENT_DETECT_WRAPPERS"
  else
    commands="$(get_tmux_option @agent_detect_wrappers 'node bun npx npm pnpm yarn')"
  fi
  contains_word "$1" "$commands"
}

# process_table_snapshot
# Portable full process table snapshot: "pid ppid comm". Picker callers can set
# AGENT_PS_TABLE once per invocation so wrapper detection does not spawn and
# rescan ps once per pane.
process_table_snapshot() {
  command -v ps >/dev/null 2>&1 || return 1
  ps -axo pid=,ppid=,comm= 2>/dev/null ||
    ps -eo pid=,ppid=,comm= 2>/dev/null
}

# resolve_pane_agent <pane-current-command> <pane-pid>
# Prints the detected agent name for a pane, or nothing if none matches.
#
# Some agents (e.g. codex) ship as a Node wrapper that spawns a native binary,
# so tmux's pane_current_command reports the wrapper ("node") rather than the
# agent. When the foreground command itself is not a known agent, walk the
# descendants of <pane-pid> and return the first child whose comm matches the
# detect list. This makes codex discoverable while keeping bare commands fast.
resolve_direct_agent() {
  local command_name="$1"
  if [ "$command_name" = claude.exe ] && is_detected_command claude; then
    printf '%s' claude
    return 0
  fi
  is_detected_command "$command_name" || return 1
  printf '%s' "$command_name"
}

agent_process_table() {
  local process_table="${AGENT_PS_TABLE:-}"
  if [ -z "$process_table" ] && [ "${AGENT_PS_TABLE_READY:-}" != 1 ]; then
    process_table="$(process_table_snapshot 2>/dev/null)" || return 1
  fi
  [ -n "$process_table" ] || return 1
  printf '%s' "$process_table"
}

resolve_pane_agent() {
  local command_name="$1" pane_pid="$2" process_table detected_commands resolved_agent
  resolved_agent="$(resolve_direct_agent "$command_name")" && {
    printf '%s' "$resolved_agent"
    return 0
  }
  [ -n "$pane_pid" ] || return 1
  is_wrapper_command "$command_name" || return 1
  process_table="$(agent_process_table)" || return 1
  detected_commands="${AGENT_DETECT_COMMANDS:-}"
  [ -n "$detected_commands" ] || detected_commands="$(detect_commands)"
  resolved_agent="$(printf '%s\n' "$process_table" |
    awk -v root="$pane_pid" -v detects="$detected_commands" \
      -f "$STATUS_HELPERS_DIR/lib/resolve_pane_agent.awk")" || return 1
  [ -n "$resolved_agent" ] || return 1
  printf '%s' "$resolved_agent"
}

# agents_config
# Newline-separated "name=command" registry of launchable agents. Pi, Codex,
# and Claude run directly because the daemon detects their state from the live
# tmux screen. Override the whole list with @agent_agents, or just pi's command
# with @agent_default_command.
#   set -g @agent_agents 'pi=pi\ncodex=codex\nclaude=claude --foo'
# <pi-default-command> is used for the pi entry's command when neither the
# registry nor @agent_default_command is set.
agents_config() {
  local pi_default="$1"
  local configured default_command
  configured="$(get_tmux_option @agent_agents '')"
  if [ -n "$configured" ]; then
    printf '%b' "$configured"
    return
  fi
  default_command="$(get_tmux_option @agent_default_command "$pi_default")"
  printf '%s\n' "pi=$default_command" "codex=codex" "claude=claude"
}

# agent_command <name> <pi-default-command>
# Prints the command line registered for <name>, or nothing if unknown.
agent_command() {
  local name="$1" pi_default="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
    "$name="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <<EOF
$(agents_config "$pi_default")
EOF
  return 1
}

# agent_names <pi-default-command>
# Prints the registered agent names, one per line.
agent_names() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "${line%%=*}"
  done <<EOF
$(agents_config "$1")
EOF
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  printf '%s' "${out%% *}" | cut -c1-8
}

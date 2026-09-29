#!/usr/bin/env bash
# Unified command-line interface for the tmux plugin's user actions.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT="$(cd "$DIR/.." && pwd)" || exit 1
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

usage() {
  printf '%s\n' \
    'Usage: tmux-argos <command> [arguments]' \
    '  agents                         List configured agents' \
    '  launch [--agent NAME] [--dir DIR]  Launch an agent (menu when unspecified)' \
    '  picker                         Open the interactive picker' \
    '  list                           List live agents (tab-separated picker rows)' \
    '  preview <SESSION-ID|PANE-ID>   Show the current pane screen' \
    '  open <SESSION-ID|PANE-ID>      Switch the current tmux client' \
    '  kill <SESSION-ID|PANE-ID>      Kill a managed session or interrupt a manual pane' \
    '  kill-matched <TEXT>            Confirm and kill matching eligible sessions' \
    '  kill-all                       Confirm and kill all eligible managed sessions' \
    '  history list                   List saved conversations' \
    '  history preview <AGENT> <SOURCE-FILE>' \
    '  history resume <AGENT> <SOURCE-FILE>' \
    '  status                         Show the cached status-line summary' \
    '  daemon <ensure|snapshot|inspect|reload|shutdown>'
}

fail() {
  printf 'tmux-argos: %s\n' "$1" >&2
  return 1
}

require_count() {
  local expected="$1" actual="$2"
  if [ "$actual" -ne "$expected" ]; then
    fail 'invalid number of arguments (see tmux-argos help)'
    return 1
  fi
}

current_window() {
  tmux display-message -p '#{window_id}' 2>/dev/null || true
}

require_configured_agent() {
  local agent="$1"
  if ! agent_command "$agent" pi >/dev/null; then
    fail "unknown configured agent: $agent"
    return 1
  fi
}

parse_launch_arguments() {
  launch_directory="$PWD"
  launch_agent_name=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --dir|--agent)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        fail "$1 requires a value"
        return 1
      fi
      if [ "$1" = --dir ]; then
        launch_directory="$2"
      else
        launch_agent_name="$2"
      fi
      shift 2
      ;;
    *) fail "unknown launch option: $1"; return 1 ;;
    esac
  done
}

launch_agent() {
  local launch_directory launch_agent_name window
  parse_launch_arguments "$@" || return 1
  if [ ! -d "$launch_directory" ]; then
    fail "directory does not exist: $launch_directory"
    return 1
  fi
  launch_directory="$(cd "$launch_directory" && pwd)" || return 1
  window="$(current_window)"
  if [ -n "$launch_agent_name" ]; then
    require_configured_agent "$launch_agent_name" || return 1
    "$DIR/launch.sh" "$launch_directory" "$window" "$launch_agent_name"
  else
    "$DIR/launch_menu.sh" "$launch_directory" "$window"
  fi
}

# Resolve only identities presented by the live picker, not reusable names or
# arbitrary tmux targets. tmux IDs do not get reassigned within a server.
find_live_target() {
  local target="$1" rows kind
  if ! [[ "$target" =~ ^(\$[0-9]+|%[0-9]+)$ ]]; then
    fail 'target must be an immutable tmux session ID or pane ID'
    return 1
  fi
  rows="$("$DIR/picker.sh" --list)" || return 1
  kind="$(printf '%s\n' "$rows" | awk -F '\t' -v target="$target" '
    $2 == "session" && $11 == target { print "session"; exit }
    $2 == "pane" && $3 == target { print "pane"; exit }
  ')" || return 1
  if [ -z "$kind" ]; then
    fail "agent target not found: $target"
    return 1
  fi
  printf '%s\n' "$kind"
}

live_action() {
  local action="$1" target="$2" kind
  kind="$(find_live_target "$target")" || return 1
  case "$action" in
  preview)
    tmux capture-pane -ept "$target"
    ;;
  open)
    if [ -z "${TMUX:-}" ]; then
      fail 'open requires a tmux client'
      return 1
    fi
    if [ "$kind" = session ]; then
      mark_managed_session_seen_if_done "$target"
    else
      mark_pane_seen_if_done "$target"
    fi
    tmux switch-client -t "$target"
    ;;
  kill)
    "$DIR/picker.sh" --kill "$kind" "$target" "$target"
    ;;
  esac
}

# Feed the existing fail-closed bulk-kill path exactly the picker row schema it
# expects. Its confirmation and fresh daemon rechecks remain authoritative.
bulk_kill() {
  local query="$1" matched_file rows row display result
  matched_file="$(mktemp)" || return 1
  rows="$("$DIR/picker.sh" --list)" || {
    rm -f "$matched_file"
    return 1
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    display="${row##*$'\t'}"
    if [ -z "$query" ] || [[ "$display" == *"$query"* ]]; then
      printf '%s\n' "$row" >>"$matched_file" || {
        rm -f "$matched_file"
        return 1
      }
    fi
  done <<< "$rows"
  "$DIR/picker.sh" --kill-matched "$matched_file"
  result=$?
  rm -f "$matched_file"
  return "$result"
}

history_binary() {
  local binary tilde='~'
  binary="$(get_tmux_option @agent_history_binary "$ROOT/daemon/target/release/tmux-argos-history")"
  case "$binary" in
  "$tilde") binary="$HOME" ;;
  "$tilde/"*) binary="$HOME/${binary#"$tilde/"}" ;;
  esac
  if [ ! -x "$binary" ]; then
    fail "history binary missing: $binary (build daemon/Cargo.toml)"
    return 1
  fi
  printf '%s\n' "$binary"
}

history_directory() {
  local option="$1" default="$2" directory tilde='~'
  directory="$(get_tmux_option "$option" "$default")"
  case "$directory" in
  "$tilde") directory="$HOME" ;;
  "$tilde/"*) directory="$HOME/${directory#"$tilde/"}" ;;
  esac
  printf '%s\n' "$directory"
}

history_list() {
  local binary pi_dir codex_dir claude_dir
  binary="$(history_binary)" || return 1
  pi_dir="$(history_directory @agent_history_pi_dir "$HOME/.pi/agent/sessions")"
  codex_dir="$(history_directory @agent_history_codex_dir "$HOME/.codex")"
  claude_dir="$(history_directory @agent_history_claude_dir "$HOME/.claude")"
  "$binary" list "$pi_dir" "$codex_dir" "$claude_dir"
}

history_resume() {
  local agent="$1" source="$2" rows record_agent record_source session_id directory
  local reference window
  case "$agent" in
  pi|codex|claude) ;;
  *) fail "unsupported history agent: $agent"; return 1 ;;
  esac
  rows="$(history_list)" || return 1
  while IFS=$'\t' read -r record_agent record_source session_id directory _; do
    if [ "$record_agent" != "$agent" ] || [ "$record_source" != "$source" ]; then
      continue
    fi
    if [ ! -d "$directory" ] || [ -z "$session_id" ]; then
      fail 'history project directory or resume ID is unavailable'
      return 1
    fi
    reference="$session_id"
    if [ "$agent" = pi ]; then
      reference="$source"
    fi
    window="$(current_window)"
    "$DIR/launch.sh" "$directory" "$window" "$agent" "$reference"
    return $?
  done <<< "$rows"
  fail "history record not found: $source"
}

history_command() {
  local subcommand="${1:-}" binary
  if [ "$#" -gt 0 ]; then
    shift
  fi
  case "$subcommand" in
  list)
    require_count 0 "$#" || return 1
    history_list
    ;;
  preview)
    require_count 2 "$#" || return 1
    binary="$(history_binary)" || return 1
    "$binary" preview "$1" "$2"
    ;;
  resume)
    require_count 2 "$#" || return 1
    history_resume "$1" "$2"
    ;;
  *) fail 'expected history list, preview, or resume'; return 1 ;;
  esac
}

daemon_command() {
  require_count 1 "$#" || return 1
  case "$1" in
  ensure|snapshot|inspect|reload|shutdown) "$DIR/daemon.sh" "$1" ;;
  *) fail "unknown daemon command: $1" ;;
  esac
}

read_command() {
  local command="$1"
  shift
  case "$command" in
  help|--help|-h|'') require_count 0 "$#" || return 1; usage ;;
  agents) require_count 0 "$#" || return 1; agent_names pi ;;
  list) require_count 0 "$#" || return 1; "$DIR/picker.sh" --list ;;
  history) history_command "$@" ;;
  status) require_count 0 "$#" || return 1; tmux show-option -gqv @agent_status_cache ;;
  daemon) daemon_command "$@" ;;
  *) fail "unknown command: $command" ;;
  esac
}

main() {
  local command="${1:-}"
  if [ "$#" -gt 0 ]; then
    shift
  fi
  case "$command" in
  launch) launch_agent "$@" ;;
  picker) require_count 0 "$#" || return 1; "$DIR/list.sh" ;;
  preview|open|kill) require_count 1 "$#" || return 1; live_action "$command" "$1" ;;
  kill-matched)
    require_count 1 "$#" || return 1
    if [ -z "$1" ] || [[ "$1" == *$'\n'* ]]; then
      fail 'kill-matched requires single-line nonempty text'
      return 1
    fi
    bulk_kill "$1"
    ;;
  kill-all) require_count 0 "$#" || return 1; bulk_kill '' ;;
  *) read_command "$command" "$@" ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# Interactive picker for live agent sessions and saved conversation history.
#
#   picker.sh           fzf picker; Tab switches between live and history rows.
#   picker.sh --list    print live rows only (used by tests and reload actions).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

expand_home_path() {
  local tilde='~'
  case "$1" in
  "$tilde") printf '%s' "$HOME" ;;
  "$tilde/"*) printf '%s/%s' "$HOME" "${1#"$tilde/"}" ;;
  *) printf '%s' "$1" ;;
  esac
}

picker_mode() {
  local mode_file="$1" mode
  if [ ! -r "$mode_file" ]; then
    printf 'live'
    return
  fi
  mode="$(<"$mode_file")"
  if [ "$mode" = history ]; then
    printf 'history'
  else
    printf 'live'
  fi
}

if [ -n "${AGENT_HISTORY_BINARY:-}" ]; then
  history_binary="$AGENT_HISTORY_BINARY"
else
  history_binary="$(expand_home_path "$(get_tmux_option @agent_history_binary "$ROOT/daemon/target/release/tmux-argos-history")")"
fi
export AGENT_HISTORY_BINARY="$history_binary"

# Preview subprocesses are started repeatedly as fzf selection changes. Handle
# them before loading live-picker configuration or daemon state.
[ "${1:-}" = '--preview' ] && {
  case "${2:-}" in
  session|pane) tmux capture-pane -ept "${3:-}" ;;
  history) "$history_binary" preview "${4:-}" "${3:-}" 2>&1 ;;
  history-error) printf '%s\n' 'Build the bundled history reader, then reload the plugin:' '' 'cargo build --release --manifest-path daemon/Cargo.toml' ;;
  esac
  exit 0
}

# Cache hot global options for this invocation. The picker enumerates every
# session/pane and should not shell out to tmux for static config per row.
AGENT_SESSION_PREFIX="$(agent_session_prefix)"
AGENT_DETECT_COMMANDS="$(detect_commands)"
AGENT_DETECT_WRAPPERS="$(wrapper_commands)"
export AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS

# One lazily-loaded daemon snapshot supplies every live row. History toggles
# and previews do not need daemon state and must stay cheap.
daemon_records=''

# lookup_daemon_state <session|pane> <target>
# On a match, sets daemon_state and daemon_at in the caller's scope and returns
# 0; returns 1 with both cleared when no record matches. Writing to caller
# variables instead of stdout avoids one command-substitution fork per picker
# row, which dominates rendering cost on large workspaces.
lookup_daemon_state() {
  local kind="$1" target="$2" record_session record_pane record_state record_changed
  daemon_state=''
  daemon_at=''
  while IFS=$'\037' read -r record_session record_pane record_state record_changed; do
    [ -n "$record_state" ] || continue
    if { [ "$kind" = session ] && [ "$record_session" = "$target" ]; } ||
      { [ "$kind" = pane ] && [ "$record_pane" = "$target" ]; }; then
      daemon_state="$record_state"
      daemon_at="$record_changed"
      return 0
    fi
  done <<< "$daemon_records"
  return 1
}

# short_path <absolute-path>
# Sets disp_path to the home-relative display form. Assigns to a caller variable
# rather than printing so the picker's per-row loop does not fork a subshell.
short_path() {
  # shellcheck disable=SC2088 # literal ~ is intentional for display
  case "$1" in
  "$HOME")   disp_path='~' ;;
  "$HOME"/*) disp_path="~/${1#"$HOME"/}" ;;
  *)          disp_path="$1" ;;
  esac
}

# classify <state>
# Sets rank, label, and desc in the caller's scope. label is the padded status
# badge; desc is the trailing note shown after the path. Shared so managed
# sessions and manual panes render identically. Assigning to caller variables
# instead of printing avoids a fork per row.
classify() {
  case "$1" in
  blocked) rank=0; label='🔴 blocked'; desc='needs input' ;;
  done)    rank=1; label='🔵 done   '; desc='finished, unseen' ;;
  idle)    rank=2; label='🟢 idle   '; desc='waiting for prompt' ;;
  working) rank=3; label='🟡 working'; desc='actively running' ;;
  *)       rank=2; label='⚪ unknown'; desc='no status extension' ;;
  esac
}

# picker_now -> current epoch seconds. Honors PICKER_NOW when set to a numeric
# value so tests can pin "now" and avoid a race: picker.sh would otherwise read
# the clock again after the test captured its own timestamp, drifting the
# rendered age across a one-second boundary. Not for production use.
picker_now() {
  if [[ "${PICKER_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$PICKER_NOW"
  else
    date +%s
  fi
}

# humanize_ago <epoch-seconds> <now> -> compact age like 45s / 12m / 3h / 2d.
# Sets ago in the caller's scope, falling back to '-' when the timestamp is
# missing or non-numeric. Assigns to a caller variable rather than printing so
# the per-row loop avoids a command-substitution fork.
humanize_ago() {
  local at="$1" now="$2" delta
  if ! [[ "$at" =~ ^[0-9]+$ ]]; then
    ago='-'
    return
  fi
  delta=$((now - at))
  [ "$delta" -lt 0 ] && delta=0
  if [ "$delta" -lt 60 ]; then
    ago="${delta}s"
  elif [ "$delta" -lt 3600 ]; then
    ago="$((delta / 60))m"
  elif [ "$delta" -lt 86400 ]; then
    ago="$((delta / 3600))h"
  else
    ago="$((delta / 86400))d"
  fi
}

pane_still_exists() {
  local target="$1" panes pane
  panes="$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)" || return 2
  while IFS= read -r pane; do
    [ "$pane" = "$target" ] && return 0
  done <<< "$panes"
  return 1
}

emit_managed_rows() {
  local now s state at path cmd tool instance name rank label desc ago disp_path daemon_state daemon_at
  now=$(picker_now)
  tmux list-sessions -F '#{session_name}	#{@agent_state}	#{@agent_state_at}	#{pane_current_path}	#{@agent_tool}	#{pane_current_command}	#{@agent_instance}' 2>/dev/null |
    while IFS=$'\t' read -r s state at path tool cmd instance; do
      is_managed_session "$s" || continue
      name=${path##*/}
      if lookup_daemon_state session "$s"; then
        state="$daemon_state"
        at="$daemon_at"
      fi
      # The agent recorded at launch, falling back to whatever runs in the pane.
      [ -n "$tool" ] || tool=${cmd##*/}
      [ -n "$instance" ] && tool="${tool}-${instance}"
      classify "$state"
      humanize_ago "$at" "$now"
      short_path "$path"
      # rank \t kind \t target \t label \t name \t age \t path \t desc \t tool
      printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$s" "$label" "$name" "$ago" "$disp_path" "$desc" "$tool"
    done
}

emit_manual_rows() {
  local now panes s pane cmd ppid path state at opts line base name rank label desc ago disp_path daemon_state daemon_at
  now=$(picker_now)
  panes="$(tmux list-panes -a -F '#{session_name}	#{pane_id}	#{pane_current_command}	#{pane_pid}	#{pane_current_path}' 2>/dev/null)" || return 1

  # Snapshot ps at most once, and only when at least one non-managed pane is
  # running a configured wrapper command. This preserves the cheap direct-command
  # path while avoiding one full process-table scan per node/npm/bun pane.
  AGENT_PS_TABLE=''
  AGENT_PS_TABLE_READY=0
  while IFS=$'\t' read -r s pane cmd ppid path; do
    [ -z "$pane" ] && continue
    is_managed_session "$s" && continue
    if is_wrapper_command "${cmd##*/}"; then
      # shellcheck disable=SC2034 # resolve_pane_agent reads these via dynamic scope
      AGENT_PS_TABLE="$(process_table_snapshot 2>/dev/null || true)"
      # shellcheck disable=SC2034 # resolve_pane_agent reads these via dynamic scope
      AGENT_PS_TABLE_READY=1
      break
    fi
  done <<< "$panes"

  while IFS=$'\t' read -r s pane cmd ppid path; do
    # Managed sessions are already listed as managed agent sessions.
    is_managed_session "$s" && continue
    # Resolve the agent name, including wrappers (codex runs under node) by
    # walking the pane's process subtree only for known wrapper commands.
    # Empty -> not an agent pane.
    base="$(resolve_pane_agent "${cmd##*/}" "$ppid")" || continue
    [ -n "$base" ] || continue
    name=${path##*/}
    if lookup_daemon_state pane "$pane"; then
      state="$daemon_state"
      at="$daemon_at"
    else
      # The tmux mirror is the daemon's restart/recovery snapshot and remains a
      # reliable picker fallback while the daemon client is unavailable.
      if ! opts="$(tmux show-options -p -t "$pane" 2>/dev/null)"; then
        pane_still_exists "$pane"
        case "$?" in
        1) continue ;;
        *) return 1 ;;
        esac
      fi
      state=''
      at=''
      while IFS= read -r line; do
        case "$line" in
        "@agent_state "*) state="${line#@agent_state }" ;;
        "@agent_state_at "*) at="${line#@agent_state_at }" ;;
        esac
      done <<< "$opts"
    fi
    if [ -n "$state" ]; then
      classify "$state"
    else
      rank=2; label='🟣 manual '; desc="pane running $base"
    fi
    humanize_ago "$at" "$now"
    short_path "$path"
    printf '%s\tpane\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$rank" "$pane" "$label" "$name" "$ago" "$disp_path" "$desc" "$base"
  done <<< "$panes"
}

format_rows() {
  awk 'BEGIN { FS = OFS = "\t" }
      {
        # Decorate: convert the humanized age (45s/12m/3h/2d/-) back into
        # seconds so the numeric sort compares real ages. Sorting the display
        # string numerically would rank "3h" (3) before "45s" (45). An unknown
        # age ("-") must sort last within its rank, not first: "-" + 0 is 0,
        # which would outrank every real timestamp as the youngest row.
        if ($6 == "-") {
          secs = 2147483647
        } else {
          n = $6 + 0
          u = substr($6, length($6))
          secs = (u == "m") ? n * 60 : (u == "h") ? n * 3600 : \
                 (u == "d") ? n * 86400 : n
        }
        print secs, $0
      }' |
    # rank asc (attention-needed floats up), then age asc so the session that
    # finished just now sits at the top of its group. Field 1 is the sort
    # decoration (age in seconds), field 2 the rank; strip it after sorting.
    sort -t$'\t' -k2,2n -k1,1n | cut -f2- |
    # Append a pre-aligned display column (field 13). Two passes first find the
    # widest project/tool names, then pad every row. Fields 1-9 are common row
    # metadata; fields 11/12 hold the cwd/resume reference for history rows.
    awk 'BEGIN { FS = OFS = "\t" }
      {
        rows[NR] = $0
        if (length($5) > w) w = length($5)
        if (length($9) > tw) tw = length($9)
      }
      END {
        for (i = 1; i <= NR; i++) {
          split(rows[i], f, "\t")
          disp = sprintf("%s  %-*s  %-*s  %4s  %s — %s", \
            f[4], tw, f[9], w, f[5], f[6], f[7], f[8])
          # Keep twelve fixed logic fields so live and history rows share one
          # fzf display field. Fields 11/12 carry history cwd/resume metadata.
          print f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], \
            f[10], f[11], f[12], disp
        }
      }'
}

emit_rows() {
  # The picker never reads legacy tmux state options for managed rows. If the
  # daemon is unavailable, rows remain discoverable with unknown/manual state.
  daemon_records="$("$DIR/daemon.sh" snapshot-picker 2>/dev/null || true)"
  {
    emit_managed_rows
    emit_manual_rows
  } | format_rows
}

emit_history_rows() {
  local now agent source session_id cwd updated title resume name ago disp_path
  local history_pi_dir history_codex_dir history_claude_dir
  now="$(picker_now)"
  history_pi_dir="$(expand_home_path "$(get_tmux_option @agent_history_pi_dir "$HOME/.pi/agent/sessions")")"
  history_codex_dir="$(expand_home_path "$(get_tmux_option @agent_history_codex_dir "$HOME/.codex")")"
  history_claude_dir="$(expand_home_path "$(get_tmux_option @agent_history_claude_dir "$HOME/.claude")")"
  if [ ! -x "$history_binary" ]; then
    printf '4\thistory-error\t-\t⚠ history\thistory unavailable\t-\t-\tbuild the history binary with cargo build --release --manifest-path daemon/Cargo.toml\t-\t\t\t\n' |
      format_rows
    return 0
  fi

  "$history_binary" list "$history_pi_dir" "$history_codex_dir" "$history_claude_dir" 2>/dev/null |
    while IFS=$'\t' read -r agent source session_id cwd updated title; do
      [ -n "$agent" ] && [ -n "$source" ] && [ -n "$session_id" ] || continue
      case "$agent" in
      pi) resume="$source" ;;
      codex|claude) resume="$session_id" ;;
      *) continue ;;
      esac
      humanize_ago "$updated" "$now"
      short_path "$cwd"
      name="${cwd##*/}"
      [ -n "$name" ] || name='/'
      printf '4\thistory\t%s\t📜 history\t%s\t%s\t%s\t%s\t%s\t\t%s\t%s\n' \
        "$source" "$name" "$ago" "$disp_path" "$title" "$agent" "$cwd" "$resume"
    done | format_rows
}

kill_target() {
  local kind="$1" target="$2" event_q
  event_q="$(printf '%q' "$DIR/event.sh")"
  case "$kind" in
  session)
    if tmux kill-session -t "$target" 2>/dev/null; then
      tmux run-shell -b "$event_q exited-session $(printf '%q' "$target")" 2>/dev/null || true
    fi
    ;;
  pane)
    # Ctrl-C interrupts the current turn; it does not prove the long-lived CLI
    # exited, so keep daemon state and Claude polling active.
    tmux send-keys -t "$target" C-c 2>/dev/null
    ;;
  esac
}

open_session_target() {
  local target="$1" origin parent
  # Move the underlying parent client to the session's origin window (best-effort),
  # then resume the session in THIS popup over it. Falls back to resuming over the
  # current window when origin/parent are unknown.
  origin=$(tmux show-options -qv -t "$target" @agent_origin 2>/dev/null)
  parent="${parent_client:-}"
  [ -n "$parent" ] || parent=$(tmux show-options -gqv @agent_parent 2>/dev/null)
  [ -n "$origin" ] && [ -n "$parent" ] &&
    tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

  # Opening a completed session marks it as seen.
  mark_managed_session_seen_if_done "$target"

  tmux attach-session -t "$target"
}

open_pane_target() {
  local target="$1" parent
  # Opening a completed manual pane marks it as seen.
  mark_pane_seen_if_done "$target"

  parent="${parent_client:-}"
  [ -n "$parent" ] || parent=$(tmux show-options -gqv @agent_parent 2>/dev/null)
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$target" 2>/dev/null || tmux switch-client -t "$target"
  else
    tmux switch-client -t "$target"
  fi
}

open_history_target() {
  local source="$1" agent="$2" cwd="$3" resume="$4" parent window
  [ -n "$source" ] && [ -n "$cwd" ] && [ -n "$resume" ] || return 0
  parent="${parent_client:-}"
  window=''
  if [ -n "$parent" ]; then
    window="$(tmux display-message -p -c "$parent" '#{window_id}' 2>/dev/null || true)"
  fi
  "$DIR/launch.sh" --attach "$cwd" "$window" "$agent" "$resume"
}

open_target() {
  local kind="$1" target="$2" tool="${3:-}" cwd="${4:-}" resume="${5:-}"
  case "$kind" in
  session) open_session_target "$target" ;;
  pane) open_pane_target "$target" ;;
  history) open_history_target "$target" "$tool" "$cwd" "$resume" ;;
  esac
}

[ "${1:-}" = '--list' ] && {
  emit_rows
  exit $?
}

[ "${1:-}" = '--list-mode' ] && {
  mode_file="${2:-}"
  if [ -n "$mode_file" ] && [ "$(picker_mode "$mode_file")" = history ]; then
    emit_history_rows
  else
    emit_rows
  fi
  exit $?
}

[ "${1:-}" = '--toggle-mode' ] && {
  mode_file="${2:-}"
  [ -n "$mode_file" ] || exit 0
  if [ "$(picker_mode "$mode_file")" = history ]; then
    printf 'live' >"$mode_file"
  else
    printf 'history' >"$mode_file"
  fi
  exit 0
}

[ "${1:-}" = '--kill' ] && {
  kill_target "${2:-}" "${3:-}"
  exit 0
}

parent_client="${1:-}"

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-argos: fzf is required for the picker"
  exit 0
fi

self="${BASH_SOURCE[0]}"
self_cmd="$(printf '%q' "$self")"
mode_file="$(mktemp "${TMPDIR:-/tmp}/agent-picker-mode.XXXXXX")" || exit 0
trap 'rm -f "$mode_file"' EXIT
printf 'live' >"$mode_file"
mode_file_q="$(printf '%q' "$mode_file")"
export FZF_DEFAULT_OPTS=''
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=13 \
  --reverse --cycle --header='Agent sessions · Tab: live/history · enter: open/resume · ctrl-x: kill live target' \
  --preview="$self_cmd --preview {2} {3} {9}" --preview-window='right,62%,wrap' \
  --bind="tab:execute-silent($self_cmd --toggle-mode $mode_file_q)+reload($self_cmd --list-mode $mode_file_q),ctrl-x:execute-silent($self_cmd --kill {2} {3})+reload($self_cmd --list-mode $mode_file_q)")

[ -z "$sel" ] && exit 0
kind="$(printf '%s' "$sel" | cut -f2)"
target="$(printf '%s' "$sel" | cut -f3)"
tool="$(printf '%s' "$sel" | cut -f9)"
history_cwd="$(printf '%s' "$sel" | cut -f11)"
resume_ref="$(printf '%s' "$sel" | cut -f12)"

open_target "$kind" "$target" "$tool" "$history_cwd" "$resume_ref"

#!/usr/bin/env bash
# Keep one nested tmux client alive while the picker switches to an agent.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

parent_client="${1:-}"
picker_session_id=''

clear_popup_state() {
  local separator session_id popup_parent popup_active context
  [ -n "$parent_client" ] || return 0

  separator=$'\037'
  context="$(tmux list-sessions -F \
    "#{session_id}${separator}#{s|${separator}| |:@agent_popup_host_client}${separator}#{@agent_popup_active}" \
    2>/dev/null || true)"
  while IFS="$separator" read -r session_id popup_parent popup_active; do
    [[ "$session_id" =~ ^\$[0-9]+$ ]] || continue
    [ "$popup_parent" = "$parent_client" ] || continue
    [ "$popup_active" = on ] || continue
    tmux set-option -u -t "$session_id" @agent_popup_active 2>/dev/null || true
  done <<< "$context"
}

cleanup() {
  clear_popup_state
  if [[ "$picker_session_id" =~ ^\$[0-9]+$ ]]; then
    tmux kill-session -t "$picker_session_id" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

picker_q="$(printf '%q' "$DIR/picker.sh")"
parent_q="$(printf '%q' "$parent_client")"
picker_session_id="$(tmux new-session -d -P -F '#{session_id}' "$picker_q $parent_q")" || exit 1
if ! [[ "$picker_session_id" =~ ^\$[0-9]+$ ]]; then
  tmux display-message 'tmux-argos: failed to create picker session'
  exit 1
fi
if ! tmux set-option -t "$picker_session_id" @agent_picker_session on; then
  tmux display-message 'tmux-argos: failed to mark picker session'
  exit 1
fi
if ! tmux set-option -t "$picker_session_id" status off; then
  tmux display-message 'tmux-argos: failed to configure picker session'
  exit 1
fi

tmux attach-session -t "$picker_session_id"

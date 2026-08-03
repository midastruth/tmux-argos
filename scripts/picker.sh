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

# shellcheck source=picker/common.sh
. "$DIR/picker/common.sh"
# shellcheck source=picker/rows.sh
. "$DIR/picker/rows.sh"
# shellcheck source=picker/actions.sh
. "$DIR/picker/actions.sh"

[ "${1:-}" = '--list' ] && {
  initialize_live_config
  emit_rows
  exit $?
}

[ "${1:-}" = '--list-mode' ] && {
  mode_file="${2:-}"
  if [ -n "$mode_file" ] && [ "$(picker_mode "$mode_file")" = history ]; then
    initialize_history_binary
    emit_history_rows
  else
    initialize_live_config
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
  kill_target "${2:-}" "${3:-}" "${4:-}"
  exit $?
}

[ "${1:-}" = '--kill-matched' ] && {
  kill_matched_sessions "${2:-}"
  exit $?
}

parent_client="${1:-}"

if ! command -v fzf >/dev/null 2>&1; then
  tmux display-message "tmux-argos: fzf is required for the picker"
  exit 0
fi

initialize_live_config
initialize_history_binary
self="${BASH_SOURCE[0]}"
self_cmd="$(printf '%q' "$self")"
mode_file="$(mktemp "${TMPDIR:-/tmp}/agent-picker-mode.XXXXXX")" || exit 0
trap 'rm -f "$mode_file"' EXIT
printf 'live' >"$mode_file"
mode_file_q="$(printf '%q' "$mode_file")"
export FZF_DEFAULT_OPTS=''
header='Agent sessions · Tab: live/history · enter: open/resume · ctrl-x: kill live target · ctrl-r: confirm bulk kill except working/blocked'
sel=$(emit_rows | fzf --ansi --delimiter='\t' --with-nth=13 \
  --reverse --cycle --header="$header" \
  --preview="$self_cmd --preview {2} {3} {9} {11}" --preview-window='right,62%,wrap' \
  --bind="tab:execute-silent($self_cmd --toggle-mode $mode_file_q)+reload($self_cmd --list-mode $mode_file_q),ctrl-x:execute-silent($self_cmd --kill {2} {3} {11})+reload($self_cmd --list-mode $mode_file_q),ctrl-r:execute($self_cmd --kill-matched {*f})+reload($self_cmd --list-mode $mode_file_q)")

[ -z "$sel" ] && exit 0
kind="$(printf '%s' "$sel" | cut -f2)"
target="$(printf '%s' "$sel" | cut -f3)"
tool="$(printf '%s' "$sel" | cut -f9)"
history_cwd="$(printf '%s' "$sel" | cut -f11)"
resume_ref="$(printf '%s' "$sel" | cut -f12)"
session_id="$(printf '%s' "$sel" | cut -f11)"

open_target "$kind" "$target" "$tool" "$history_cwd" "$resume_ref" "$session_id"

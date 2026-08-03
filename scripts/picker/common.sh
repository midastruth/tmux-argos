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

history_binary=''

initialize_history_binary() {
  if [ -n "$history_binary" ]; then
    return 0
  fi
  if [ -n "${AGENT_HISTORY_BINARY:-}" ]; then
    history_binary="$AGENT_HISTORY_BINARY"
  else
    history_binary="$(expand_home_path "$(get_tmux_option @agent_history_binary "$ROOT/daemon/target/release/tmux-argos-history")")"
  fi
  export AGENT_HISTORY_BINARY="$history_binary"
}

initialize_live_config() {
  AGENT_SESSION_PREFIX="$(agent_session_prefix)"
  AGENT_DETECT_COMMANDS="$(detect_commands)"
  AGENT_DETECT_WRAPPERS="$(wrapper_commands)"
  export AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS
}

# Preview subprocesses are started repeatedly as fzf selection changes. Load
# only the dependency required by the selected preview kind.
[ "${1:-}" = '--preview' ] && {
  case "${2:-}" in
  session) tmux capture-pane -ept "${5:-}" ;;
  pane) tmux capture-pane -ept "${3:-}" ;;
  history)
    initialize_history_binary
    "$history_binary" preview "${4:-}" "${3:-}" 2>&1
    ;;
  history-error) printf '%s\n' 'Build the bundled history reader, then reload the plugin:' '' 'cargo build --release --manifest-path daemon/Cargo.toml' ;;
  esac
  exit 0
}

# One lazily-loaded daemon snapshot supplies every live row. History toggles
# and previews do not need daemon state and must stay cheap.
daemon_records=''

# merge_daemon_state <session|pane>
# Reads daemon rows followed by a marker and tmux rows. One awk pass indexes the
# daemon snapshot and joins every tmux row in O(records + rows) time. Keeping the
# join outside the Bash row loops avoids repeatedly scanning the full snapshot.
merge_daemon_state() {
  local kind="$1"
  awk -v kind="$kind" '
    $0 == "__tmux_argos_rows__" {
      reading_tmux = 1
      next
    }
    !reading_tmux {
      count = split($0, daemon, "\037")
      if (count == 5 && daemon[4] != "") {
        key = (kind == "session") ? daemon[2] : daemon[3]
        if (key != "" && !(key in states)) {
          states[key] = daemon[4]
          changed[key] = daemon[5]
        }
      }
      next
    }
    {
      count = split($0, row, "\t")
      key = row[2]
      found = (key in states) ? 1 : 0
      if (kind == "session") {
        if (found) {
          row[3] = states[key]
          row[4] = changed[key]
        }
        for (field_index = 1; field_index <= 8; field_index++) {
          printf "%s%s", row[field_index], (field_index == 8 ? "\n" : "\t")
        }
      } else {
        for (field_index = 1; field_index <= 5; field_index++) {
          printf "%s\t", row[field_index]
        }
        printf "%d\t%s\t%s\n", found, states[key], changed[key]
      }
    }
  '
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

# sanitize_picker_field <value>
# Sets picker_field to a single-line, tab-free value suitable for the fixed fzf
# row schema. tmux format substitutions perform the same sanitization before
# list output is parsed; this second boundary check also protects generated rows
# when a tmux implementation or test double returns raw control characters.
sanitize_picker_field() {
  picker_field="$1"
  picker_field="${picker_field//$'\t'/ }"
  picker_field="${picker_field//$'\n'/ }"
  picker_field="${picker_field//$'\r'/ }"
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
  *)       rank=2; label='⚪ unknown'; desc='no detected status' ;;
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

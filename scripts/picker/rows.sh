sanitize_display_fields() {
  sanitize_picker_field "$label"
  label="$picker_field"
  sanitize_picker_field "$name"
  name="$picker_field"
  sanitize_picker_field "$ago"
  ago="$picker_field"
  sanitize_picker_field "$disp_path"
  disp_path="$picker_field"
  sanitize_picker_field "$desc"
  desc="$picker_field"
  sanitize_picker_field "$state"
  state="$picker_field"
}

emit_managed_rows() {
  local now s session_id state at path cmd tool instance name rank label desc ago disp_path picker_field
  local tmux_format
  now=$(picker_now)
  # Replace row separators inside tmux metadata before parsing. In particular,
  # pane paths may legally contain tabs or newlines and must never shift the
  # immutable session ID into an action field chosen by display metadata.
  tmux_format=$'#{s/[\t\n\r]/ /:session_name}\t#{session_id}\t#{s/[\t\n\r]/ /:@agent_state}\t#{s/[\t\n\r]/ /:@agent_state_at}\t#{s/[\t\n\r]/ /:pane_current_path}\t#{s/[\t\n\r]/ /:@agent_tool}\t#{s/[\t\n\r]/ /:pane_current_command}\t#{s/[\t\n\r]/ /:@agent_instance}'
  {
    printf '%s\n' "$daemon_records"
    printf '%s\n' '__tmux_argos_rows__'
    tmux list-sessions -F "$tmux_format" 2>/dev/null
  } | merge_daemon_state session |
    while IFS=$'\t' read -r s session_id state at path tool cmd instance; do
      [[ "$session_id" =~ ^\$[0-9]+$ ]] || continue
      is_managed_session "$s" || continue
      name=${path##*/}
      # The agent recorded at launch, falling back to whatever runs in the pane.
      [ -n "$tool" ] || tool=${cmd##*/}
      [ -n "$instance" ] && tool="${tool}-${instance}"
      classify "$state"
      humanize_ago "$at" "$now"
      short_path "$path"
      sanitize_picker_field "$s"
      s="$picker_field"
      sanitize_display_fields
      sanitize_picker_field "$tool"
      tool="$picker_field"
      # Fields 1-9 are display metadata, field 10 keeps the raw state, and
      # field 11 identifies this tmux session instance even if its name is
      # deleted and reused while a destructive action awaits confirmation.
      printf '%s\tsession\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rank" "$s" "$label" "$name" "$ago" "$disp_path" "$desc" "$tool" "$state" "$session_id"
    done
}

initialize_manual_process_table() {
  local panes="$1" session pane command pane_pid path daemon_found state changed_at
  AGENT_PS_TABLE=''
  AGENT_PS_TABLE_READY=0
  while IFS=$'\t' read -r session pane command pane_pid path daemon_found state changed_at; do
    [[ "$pane" =~ ^%[0-9]+$ ]] || continue
    is_managed_session "$session" && continue
    if contains_word "${command##*/}" "$AGENT_DETECT_WRAPPERS"; then
      AGENT_PS_TABLE="$(process_table_snapshot 2>/dev/null || true)"
      AGENT_PS_TABLE_READY=1
      return
    fi
  done <<< "$panes"
}

resolve_manual_agent() {
  local command_name="${1##*/}" pane_pid="$2"
  if [ "$command_name" = claude.exe ] && contains_word claude "$AGENT_DETECT_COMMANDS"; then
    base=claude
    return 0
  fi
  if contains_word "$command_name" "$AGENT_DETECT_COMMANDS"; then
    base="$command_name"
    return 0
  fi
  contains_word "$command_name" "$AGENT_DETECT_WRAPPERS" || return 1
  base="$(resolve_pane_agent "$command_name" "$pane_pid")"
}

load_manual_pane_state() {
  local pane="$1" daemon_found="$2" options line pane_status
  [ "$daemon_found" = 1 ] && return 0
  if ! options="$(tmux show-options -p -t "$pane" 2>/dev/null)"; then
    pane_still_exists "$pane"
    pane_status=$?
    [ "$pane_status" -eq 1 ] && return 1
    return 2
  fi
  state=''
  at=''
  while IFS= read -r line; do
    case "$line" in
    "@agent_state "*) state="${line#@agent_state }" ;;
    "@agent_state_at "*) at="${line#@agent_state_at }" ;;
    esac
  done <<< "$options"
}

emit_manual_row() {
  local session="$1" pane="$2" command="$3" pane_pid="$4" path="$5" daemon_found="$6"
  local state_result name rank label desc ago disp_path picker_field state at base
  state="$7"
  at="$8"
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
  is_managed_session "$session" && return 0
  resolve_manual_agent "$command" "$pane_pid" || return 0
  load_manual_pane_state "$pane" "$daemon_found"
  state_result=$?
  [ "$state_result" -eq 1 ] && return 0
  [ "$state_result" -eq 2 ] && return 2

  name=${path##*/}
  if [ -n "$state" ]; then
    classify "$state"
  else
    rank=2
    label='🟣 manual '
    desc="pane running $base"
  fi
  humanize_ago "$at" "$now"
  short_path "$path"
  sanitize_display_fields
  sanitize_picker_field "$base"
  base="$picker_field"
  printf '%s\tpane\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rank" "$pane" "$label" "$name" "$ago" "$disp_path" "$desc" "$base" "$state"
}

emit_manual_rows() {
  local now panes session pane command pane_pid path daemon_found state at row_result tmux_format
  now=$(picker_now)
  tmux_format=$'#{s/[\t\n\r]/ /:session_name}\t#{pane_id}\t#{s/[\t\n\r]/ /:pane_current_command}\t#{pane_pid}\t#{s/[\t\n\r]/ /:pane_current_path}'
  panes="$({
    printf '%s\n' "$daemon_records"
    printf '%s\n' '__tmux_argos_rows__'
    tmux list-panes -a -F "$tmux_format" 2>/dev/null
  } | merge_daemon_state pane)" || return 1
  initialize_manual_process_table "$panes"

  while IFS=$'\t' read -r session pane command pane_pid path daemon_found state at; do
    emit_manual_row "$session" "$pane" "$command" "$pane_pid" "$path" "$daemon_found" "$state" "$at"
    row_result=$?
    [ "$row_result" -eq 2 ] && return 1
  done <<< "$panes"
  return 0
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
    # metadata and field 10 holds live raw state. Field 11 holds either a live
    # session ID or a history cwd; field 12 holds the history resume reference.
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

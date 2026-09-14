kill_target() {
  local kind="$1" target="$2" session_id="${3:-}"
  case "$kind" in
  session)
    # A session name can be reused as soon as its predecessor exits. Target the
    # immutable ID captured in the picker row so a replacement cannot be killed.
    if ! [[ "$session_id" =~ ^\$[0-9]+$ ]]; then
      return 1
    fi
    if ! tmux kill-session -t "$session_id" 2>/dev/null; then
      return 1
    fi
    # Complete the immutable-ID exit report before this picker becomes
    # interactive again so daemon state cannot outlive the deleted session.
    if ! "$DIR/event.sh" exited-session "$session_id" >/dev/null 2>&1; then
      # The tmux kill is irreversible, so this boundary can only report the
      # lifecycle failure rather than roll back or retry without a bound.
      tmux display-message 'tmux-argos: session killed, but daemon exit report failed'
      return 1
    fi
    ;;
  pane)
    # Ctrl-C interrupts the current turn; it does not prove the long-lived CLI
    # exited, so keep daemon state and agent screen polling active.
    tmux send-keys -t "$target" C-c 2>/dev/null
    ;;
  esac
}

# report_session_exits <newline-separated-session-ids>
# Reports a completed bulk kill synchronously and sequentially before this fzf
# instance returns interactive control.
report_session_exits() {
  local session_ids="$1" session_id
  local -a event_arguments=()
  [ -n "$session_ids" ] || return 0
  while IFS= read -r session_id; do
    [ -n "$session_id" ] || continue
    event_arguments+=("$session_id")
  done <<< "$session_ids"
  [ "${#event_arguments[@]}" -gt 0 ] || return 0
  "$DIR/event.sh" exited-sessions "${event_arguments[@]}" >/dev/null 2>&1
}

read_current_managed_session_state() {
  local session_id="$1"
  if ! current_session_state="$(tmux display-message -p -t "$session_id" '#{@agent_state}' 2>/dev/null)"; then
    current_session_state=''
    return 1
  fi
  case "$current_session_state" in
  ''|idle|done|working|blocked) return 0 ;;
  *) return 2 ;;
  esac
}

read_matched_session_rows() {
  local matched_file="$1"
  if [ -z "$matched_file" ] || [ ! -r "$matched_file" ]; then
    tmux display-message 'tmux-argos: matched picker rows could not be read; bulk kill aborted'
    return 1
  fi
  if ! matched_session_rows="$(awk -f "$DIR/lib/validate_picker_rows.awk" "$matched_file")"; then
    tmux display-message 'tmux-argos: matched picker rows are malformed; bulk kill aborted'
    return 1
  fi
  if [ -z "$matched_session_rows" ]; then
    tmux display-message 'tmux-argos: no managed agent sessions in the current match set'
    return 2
  fi
}

confirm_bulk_kill() {
  local matched_session_count confirmation_reply
  matched_session_count="$(printf '%s\n' "$matched_session_rows" |
    awk -F '\t' '!seen[$11]++ { count++ } END { print count + 0 }')"
  printf 'Kill eligible managed sessions among %s currently matched session(s)?\n' "$matched_session_count"
  printf '%s\n' 'Sessions that are working or blocked will be skipped. This cannot be undone.'
  printf 'Type y to kill, anything else to cancel: '
  IFS= read -r confirmation_reply || confirmation_reply=''
  case "$confirmation_reply" in
  y|Y) return 0 ;;
  *)
    tmux display-message 'tmux-argos: bulk kill cancelled'
    return 1
    ;;
  esac
}

# join_matched_rows_with_current_state <matched-session-rows>
# Sets joined_rows to one "<session>\t<session_id>\t<protected>" line per
# distinct matched session, using a freshly read authoritative daemon snapshot.
# Returns 1 when daemon state is unavailable and 2 when it is malformed.
join_matched_rows_with_current_state() {
  local rows="$1" current_daemon_records marker
  if ! current_daemon_records="$("$DIR/daemon.sh" snapshot-picker 2>/dev/null)"; then
    return 1
  fi
  marker='__tmux_argos_daemon_rows__'
  if ! joined_rows="$({
    printf '%s\n' "$rows"
    printf '%s\n' "$marker"
    printf '%s\n' "$current_daemon_records"
  } | awk -v marker="$marker" -f "$DIR/lib/join_protected_sessions.awk")"; then
    return 2
  fi
}

load_validated_targets() {
  local join_result
  join_matched_rows_with_current_state "$matched_session_rows"
  join_result=$?
  if [ "$join_result" -eq 1 ]; then
    tmux display-message 'tmux-argos: daemon state unavailable; bulk kill aborted'
    return 1
  fi
  if [ "$join_result" -eq 2 ]; then
    tmux display-message 'tmux-argos: daemon state could not be validated; bulk kill aborted'
    return 1
  fi
  validated_targets="$joined_rows"
}

# read_current_target_protection <session_id>
# Screen-detected agents never write the session tmux mirror, so that mirror can
# stay "idle" for the whole session lifetime. Re-read authoritative daemon state
# for this exact session immediately before deleting it, because the earlier
# kills in the same batch take time during which it can start working.
# Sets current_target_protected to 0 or 1; returns 1 when daemon state is
# unavailable and 2 when it is malformed.
read_current_target_protection() {
  local session_id="$1" target_rows join_result
  current_target_protected=0
  target_rows="$(printf '%s\n' "$matched_session_rows" |
    awk -F '\t' -v session_id="$session_id" '$11 == session_id')"
  join_matched_rows_with_current_state "$target_rows"
  join_result=$?
  if [ "$join_result" -ne 0 ]; then
    return "$join_result"
  fi
  current_target_protected="$(printf '%s\n' "$joined_rows" |
    awk -F '\t' -v session_id="$session_id" \
      '$2 == session_id && $3 == 1 { protected = 1 } END { print protected + 0 }')"
}

record_killed_session() {
  local session_id="$1"
  killed=$((killed + 1))
  if [ -n "$killed_session_ids" ]; then
    killed_session_ids+=$'\n'
  fi
  killed_session_ids+="$session_id"
}

# revalidate_target_before_kill <session_id>
# Returns 0 when the target may be killed, 1 when it must be skipped because it
# is working or blocked, 2 when the remaining bulk kill must abort, and 3 when
# only this target failed.
revalidate_target_before_kill() {
  local session_id="$1" revalidation_result current_state_result
  read_current_target_protection "$session_id"
  revalidation_result=$?
  if [ "$revalidation_result" -ne 0 ]; then
    tmux display-message "tmux-argos: current state for $session_id could not be revalidated; remaining bulk kill aborted"
    return 2
  fi
  if [ "$current_target_protected" = 1 ]; then
    return 1
  fi
  read_current_managed_session_state "$session_id"
  current_state_result=$?
  if [ "$current_state_result" -eq 1 ]; then
    return 3
  fi
  if [ "$current_state_result" -eq 2 ]; then
    tmux display-message "tmux-argos: invalid current state for $session_id; remaining bulk kill aborted"
    return 2
  fi
  if [ "$current_session_state" = working ] || [ "$current_session_state" = blocked ]; then
    return 1
  fi
  return 0
}

kill_validated_target() {
  local session_id="$1" protected="$2" revalidation_result
  if [ "$protected" = 1 ]; then
    skipped=$((skipped + 1))
    return 0
  fi
  revalidate_target_before_kill "$session_id"
  revalidation_result=$?
  case "$revalidation_result" in
  1)
    skipped=$((skipped + 1))
    return 0
    ;;
  2)
    failed=$((failed + 1))
    return 2
    ;;
  3)
    failed=$((failed + 1))
    return 0
    ;;
  esac
  if tmux kill-session -t "$session_id" 2>/dev/null; then
    record_killed_session "$session_id"
  else
    failed=$((failed + 1))
  fi
}

execute_validated_targets() {
  local session session_id protected target_result
  killed=0
  failed=0
  skipped=0
  killed_session_ids=''
  while IFS=$'\t' read -r session session_id protected; do
    [ -n "$session" ] || continue
    kill_validated_target "$session_id" "$protected"
    target_result=$?
    [ "$target_result" -eq 2 ] && break
  done <<< "$validated_targets"
}

report_bulk_kill_result() {
  local lifecycle_report_failed=0
  report_session_exits "$killed_session_ids" || lifecycle_report_failed=1
  if [ "$failed" -gt 0 ]; then
    tmux display-message "tmux-argos: killed $killed matched session(s), skipped $skipped working/blocked, $failed could not be killed"
    return 1
  fi
  if [ "$lifecycle_report_failed" -eq 1 ]; then
    tmux display-message "tmux-argos: killed $killed matched session(s), skipped $skipped working/blocked; daemon exit report failed"
    return 1
  fi
  tmux display-message "tmux-argos: killed $killed matched session(s), skipped $skipped working/blocked"
}

kill_matched_sessions() {
  local matched_file="$1" matched_rows_result
  local matched_session_rows validated_targets joined_rows
  local current_session_state current_target_protected
  local killed failed skipped killed_session_ids

  read_matched_session_rows "$matched_file"
  matched_rows_result=$?
  [ "$matched_rows_result" -eq 1 ] && return 1
  [ "$matched_rows_result" -eq 2 ] && return 0
  confirm_bulk_kill || return 0
  load_validated_targets || return 1
  execute_validated_targets
  report_bulk_kill_result
}

record_popup_host() {
  local target="$1" parent="$2" separator context
  local host_session_id host_window_id host_pane_id
  local client session_id window_id pane_id
  [ -n "$parent" ] || return 1

  separator=$'\037'
  context=$(tmux list-clients -F \
    "#{s|${separator}| |:client_name}${separator}#{session_id}${separator}#{window_id}${separator}#{pane_id}" \
    2>/dev/null) || return 1
  host_session_id=''
  host_window_id=''
  host_pane_id=''
  while IFS="$separator" read -r client session_id window_id pane_id; do
    [ "$client" = "$parent" ] || continue
    host_session_id="$session_id"
    host_window_id="$window_id"
    host_pane_id="$pane_id"
    break
  done <<< "$context"
  [[ "$host_session_id" =~ ^\$[0-9]+$ ]] || return 1
  [[ "$host_window_id" =~ ^@[0-9]+$ ]] || return 1
  [[ "$host_pane_id" =~ ^%[0-9]+$ ]] || return 1

  tmux set-option -t "$target" @agent_popup_host_client "$parent" \
    \; set-option -t "$target" @agent_popup_host_session_id "$host_session_id" \
    \; set-option -t "$target" @agent_popup_host_window_id "$host_window_id" \
    \; set-option -t "$target" @agent_popup_host_pane_id "$host_pane_id" \
    \; set-option -t "$target" @agent_popup_active on 2>/dev/null
}

mark_popup_inactive() {
  local target="$1"
  tmux set-option -u -t "$target" @agent_popup_active 2>/dev/null
}

open_session_target() {
  local target="$1" origin parent attach_status popup_host_recorded
  [[ "$target" =~ ^\$[0-9]+$ ]] || return 1
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

  popup_host_recorded=0
  if record_popup_host "$target" "$parent"; then
    popup_host_recorded=1
  fi
  tmux attach-session -t "$target"
  attach_status=$?
  if [ "$popup_host_recorded" -eq 1 ]; then
    mark_popup_inactive "$target" || true
  fi
  return "$attach_status"
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
  local kind="$1" target="$2" tool="${3:-}" cwd="${4:-}" resume="${5:-}" session_id="${6:-}"
  case "$kind" in
  session) open_session_target "$session_id" ;;
  pane) open_pane_target "$target" ;;
  history) open_history_target "$target" "$tool" "$cwd" "$resume" ;;
  esac
}

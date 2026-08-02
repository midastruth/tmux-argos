#!/usr/bin/env bash
# Shared tmux/ps mocks for the test suite. Source this file, then call
# install_tmux_mock <bindir> to write executable `tmux` and `ps` mocks there.
#
# The tmux mock is driven entirely by environment variables:
#   TMUX_MOCK_LOG              append every invocation (tab-separated) to file
#   TMUX_MOCK_OPTIONS          "key=value" lines for global show-option
#   TMUX_MOCK_TARGET_OPTIONS   "target|key=value" lines for -t show-option(s)
#   TMUX_MOCK_STATUS_OPTIONS   output for display-message with -F
#   TMUX_MOCK_LIST_SESSIONS    output for the first list-sessions call
#   TMUX_MOCK_LIST_SESSIONS_AFTER_FIRST
#                              output for later calls when set; call state is
#                              stored under TMUX_MOCK_STATE_DIR
#   TMUX_MOCK_LIST_PANES       output for list-panes (single fixture)
#   TMUX_MOCK_LIST_PANES_PICKER / TMUX_MOCK_LIST_PANES_STATUS
#                              alternative per-caller fixtures: when either is
#                              set, list-panes returns the PICKER fixture for
#                              formats containing pane_current_command and the
#                              STATUS fixture otherwise
#   TMUX_MOCK_LIST_CLIENTS     tab-separated client_name, session_name,
#                              client_pid rows
#   TMUX_MOCK_SERVER_PID       value for the #{pid} server-pid format
#   TMUX_MOCK_HAS_SESSION      "yes" to make every has-session succeed
#   TMUX_MOCK_EXISTING_SESSIONS space-separated session names that exist
#   TMUX_MOCK_CURRENT_SESSION  session name for '#S' display-message formats
#   TMUX_MOCK_PANE_SESSION     session name for '#{session_name}' formats
#   TMUX_MOCK_PANE_VISIBLE     output for '#{session_attached}' formats
#   TMUX_MOCK_FAIL_TARGETS     space-separated targets whose -t queries fail,
#                              including kill-session
#   TMUX_MOCK_FAIL_REFRESH_CLIENT
#                              non-empty makes refresh-client fail
#   TMUX_MOCK_SHOW_HOOKS       hook names returned by show-hooks -g
#   TMUX_MOCK_IF_SHELL_RESULT  retained for generic if-shell tests
#
# The ps mock is driven by:
#   TMUX_MOCK_PS_CHILDREN      "ppid=pid pid..." lines
#   TMUX_MOCK_PS_COMM          "pid=comm" lines

install_tmux_mock() {
  local bin="$1"
  mkdir -p "$bin"

  cat >"$bin/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
set -u

log() {
  [ -n "${TMUX_MOCK_LOG:-}" ] || return 0
  {
    printf '%s' "${1:-}"
    shift || true
    for arg in "$@"; do
      printf '\t%s' "$arg"
    done
    printf '\n'
  } >>"$TMUX_MOCK_LOG"
}

kv_get() {
  local key="$1" line k v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [ "$k" = "$key" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "${TMUX_MOCK_OPTIONS:-}"
  return 1
}

target_kv_get() {
  local target="$1" opt="$2" line k v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [ "$k" = "$target|$opt" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "${TMUX_MOCK_TARGET_OPTIONS:-}"
  return 1
}

last_arg() {
  local x last=''
  for x in "$@"; do last="$x"; done
  printf '%s' "$last"
}

target_arg() {
  local prev='' x
  for x in "$@"; do
    if [ "$prev" = '-t' ]; then
      printf '%s' "$x"
      return 0
    fi
    prev="$x"
  done
  return 1
}

target_should_fail() {
  local target="$1"
  [ -n "$target" ] || return 1
  case " ${TMUX_MOCK_FAIL_TARGETS:-} " in
  *" $target "*) return 0 ;;
  *) return 1 ;;
  esac
}

show_option() {
  local opt target value x value_only=no quiet=no
  opt="$(last_arg "$@")"
  target="$(target_arg "$@" || true)"
  for x in "$@"; do
    case "$x" in
    -*v*) value_only=yes ;;
    -*q*) quiet=yes ;;
    esac
  done
  if target_should_fail "$target"; then
    [ "$quiet" = yes ] && return 0
    return 1
  fi
  if [ -n "$target" ] && [[ "$opt" != @* ]]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      k="${line%%=*}"
      value="${line#*=}"
      case "$k" in
      "$target|"@*) printf '%s %s\n' "${k#"$target|"}" "$value" ;;
      esac
    done <<< "${TMUX_MOCK_TARGET_OPTIONS:-}"
    return 0
  fi
  if [ -n "$target" ]; then
    value="$(target_kv_get "$target" "$opt" || true)"
  else
    value="$(kv_get "$opt" || true)"
  fi
  [ -n "$value" ] || return 0
  if [ "$value_only" = yes ]; then
    printf '%s' "$value"
  else
    printf '%s %s' "$opt" "$value"
  fi
}

run_group() {
  local group_cmd="$1" joined target
  shift || true
  case "$group_cmd" in
    show-option|show-options)
      show_option "$@"
      ;;
    display-message)
      joined=" $* "
      target="$(target_arg "$@" || true)"
      if target_should_fail "$target"; then
        return 1
      fi
      if [[ "$joined" == *' -F '* ]]; then
        printf '%s' "${TMUX_MOCK_STATUS_OPTIONS:-}"
      elif [[ "$joined" == *'__agent_pane__ '* && "$joined" == *'#{session_attached}'* ]]; then
        printf '__agent_pane__ %s %s' "${target:-}" "${TMUX_MOCK_PANE_VISIBLE:-0 0 0}"
      elif [[ "$joined" == *'#{session_attached}'* ]]; then
        printf '%s' "${TMUX_MOCK_PANE_VISIBLE:-0 0 0}"
      elif [[ "$joined" == *'#{session_name}'* ]]; then
        printf '%s' "${TMUX_MOCK_PANE_SESSION:-${TMUX_MOCK_CURRENT_SESSION:-}}"
      elif [[ "$joined" == *'#{pid}'* ]]; then
        printf '%s' "${TMUX_MOCK_SERVER_PID:-}"
      elif [[ "$joined" == *'#S'* ]]; then
        printf '%s' "${TMUX_MOCK_CURRENT_SESSION:-}"
      else
        last_arg "$@"
      fi
      ;;
  esac
}

run_chain() {
  local -a group=()
  local arg first=yes status=0
  for arg in "$@"; do
    if [ "$arg" = ';' ]; then
      if [ "${#group[@]}" -gt 0 ]; then
        [ "$first" = no ] && printf '\n'
        run_group "${group[@]}" || status=$?
        first=no
      fi
      group=()
    else
      group+=("$arg")
    fi
  done
  if [ "${#group[@]}" -gt 0 ]; then
    [ "$first" = no ] && printf '\n'
    run_group "${group[@]}" || status=$?
  fi
  return "$status"
}

emit_list_panes() {
  local data="$1" joined="$2" line f1 f2 rest
  [ -n "$data" ] || return 0
  if [[ "$joined" == *'#{pane_id}'* ]] &&
    [[ "$joined" != *'#{session_name}'* ]] &&
    [[ "$joined" != *pane_current_command* ]]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=$'\t' read -r f1 f2 rest <<< "$line"
      printf '%s\n' "${f2:-$f1}"
    done <<< "$data"
  else
    printf '%s\n' "$data"
  fi
}

cmd="${1:-}"
shift || true
log "$cmd" "$@"

case "$cmd" in
  show-option|show-options|display-message)
    run_chain "$cmd" "$@"
    ;;
  list-sessions)
    list_sessions="${TMUX_MOCK_LIST_SESSIONS:-}"
    if [ "${TMUX_MOCK_LIST_SESSIONS_AFTER_FIRST+x}" = x ]; then
      count_file="${TMUX_MOCK_STATE_DIR:?}/list-sessions-count"
      count=0
      if [ -r "$count_file" ]; then
        read -r count <"$count_file"
      fi
      if [ "$count" -gt 0 ]; then
        list_sessions="$TMUX_MOCK_LIST_SESSIONS_AFTER_FIRST"
      fi
      printf '%s\n' "$((count + 1))" >"$count_file"
    fi
    if [ -n "$list_sessions" ]; then
      if [[ " $* " == *$'\037'* ]]; then
        printf '%s\n' "$list_sessions" | tr '\t' '\037'
      else
        printf '%s\n' "$list_sessions"
      fi
    fi
    exit 0
    ;;
  list-panes)
    joined=" $* "
    if [ -n "${TMUX_MOCK_LIST_PANES_PICKER:-}" ] || [ -n "${TMUX_MOCK_LIST_PANES_STATUS:-}" ]; then
      if [[ "$joined" == *pane_current_command* ]]; then
        emit_list_panes "${TMUX_MOCK_LIST_PANES_PICKER:-}" "$joined"
      else
        emit_list_panes "${TMUX_MOCK_LIST_PANES_STATUS:-}" "$joined"
      fi
    else
      emit_list_panes "${TMUX_MOCK_LIST_PANES:-}" "$joined"
    fi
    ;;
  list-clients)
    joined=" $* "
    while IFS=$'\t' read -r client session pid; do
      [ -n "$client" ] || continue
      if [[ "$joined" == *'#{client_pid}'* ]]; then
        printf '%s\t%s\n' "$client" "$pid"
      elif [[ "$joined" == *'#{session_name}'* ]]; then
        printf '%s\t%s\n' "$client" "$session"
      else
        printf '%s\n' "$client"
      fi
    done <<< "${TMUX_MOCK_LIST_CLIENTS:-}"
    ;;
  has-session)
    target="$(target_arg "$@" || true)"
    if [ "${TMUX_MOCK_HAS_SESSION:-no}" = yes ]; then
      exit 0
    fi
    if [[ "$target" == =* ]]; then
      # A leading '=' is tmux's exact target syntax.
      target="${target#=}"
      case " ${TMUX_MOCK_EXISTING_SESSIONS:-} " in
      *" $target "*) exit 0 ;;
      *) exit 1 ;;
      esac
    fi
    # Without '=', model tmux's normal prefix matching. This matters for tests
    # such as instance -1 versus an existing instance -10.
    for existing in ${TMUX_MOCK_EXISTING_SESSIONS:-}; do
      [[ "$existing" == "$target"* ]] && exit 0
    done
    exit 1
    ;;
  show-hooks)
    printf '%s\n' "${TMUX_MOCK_SHOW_HOOKS:-}"
    ;;
  refresh-client)
    [ -z "${TMUX_MOCK_FAIL_REFRESH_CLIENT:-}" ]
    ;;
  if-shell)
    if [ "${TMUX_MOCK_IF_SHELL_RESULT:-committed}" = committed ]; then
      log '__if-shell-then__' "${3:-}"
      printf '%s' committed
    else
      log '__if-shell-else__' "${4:-}"
      printf '%s' stale
    fi
    ;;
  kill-session)
    # Model a session that vanished or that tmux refuses to kill, so callers can
    # be tested for propagating the failure instead of reporting a clean sweep.
    target="$(target_arg "$@" || true)"
    target_should_fail "$target" && exit 1
    exit 0
    ;;
  new-session|set-option|set-hook|display-popup|send-keys|attach-session|switch-client|detach-client)
    exit 0
    ;;
  run-shell)
    # Background commands are logged but not executed; individual tests invoke
    # daemon/event clients directly when their output matters.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
TMUX_MOCK
  chmod +x "$bin/tmux"

  cat >"$bin/ps" <<'PS_MOCK'
#!/usr/bin/env bash
set -u

kv_get() {
  local data="$1" key="$2" line k v
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%=*}"
    v="${line#*=}"
    if [ "$k" = "$key" ]; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "$data"
  return 1
}

# Portable full-table form used by resolve_pane_agent:
#   ps -axo pid=,ppid=,comm=   (BSD/macOS)
#   ps -eo  pid=,ppid=,comm=   (GNU/Linux fallback)
# Reconstruct the table from the parent/child and comm fixtures.
if { [ "${1:-}" = '-axo' ] || [ "${1:-}" = '-eo' ]; } &&
  [ "${2:-}" = 'pid=,ppid=,comm=' ]; then
  line=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    parent="${line%%=*}"
    kids="${line#*=}"
    for child in $kids; do
      comm="$(kv_get "${TMUX_MOCK_PS_COMM:-}" "$child" || true)"
      printf '%s %s %s\n' "$child" "$parent" "$comm"
    done
  done <<< "${TMUX_MOCK_PS_CHILDREN:-}"
  exit 0
fi

if [ "${1:-}" = '-o' ] && [ "${2:-}" = 'ppid=' ] && [ "${3:-}" = '-p' ]; then
  wanted="${4:-}"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    parent="${line%%=*}"
    for child in ${line#*=}; do
      if [ "$child" = "$wanted" ]; then
        printf '%s\n' "$parent"
        exit 0
      fi
    done
  done <<< "${TMUX_MOCK_PS_CHILDREN:-}"
  exit 0
fi

exit 0
PS_MOCK
  chmod +x "$bin/ps"
}

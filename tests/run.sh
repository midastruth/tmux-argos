#!/usr/bin/env bash
# shellcheck disable=SC2034 # mock configuration variables are consumed by subprocesses
# shellcheck source-path=SCRIPTDIR
# Lightweight unit tests for tmux-agents-session-manager.
# No external test framework is required; run with: bash tests/run.sh
set -u
# Most tests configure the tmux mock through environment variables. Export new
# assignments by default so subprocesses under run_bash see them.
set -a

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-agents-tests.$$"
MOCK_BIN="$TMP_ROOT/bin"
TMUX_LOG="$TMP_ROOT/tmux.log"
TMUX_MOCK_STATE_DIR="$TMP_ROOT/mock-state"
mkdir -p "$MOCK_BIN" "$TMUX_MOCK_STATE_DIR"
: >"$TMUX_LOG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# shellcheck source=lib/tmux_mock.sh
. "$ROOT/tests/lib/tmux_mock.sh"
install_tmux_mock "$MOCK_BIN"

DAEMON_LOG="$TMP_ROOT/daemon.log"
: >"$DAEMON_LOG"
cat >"$MOCK_BIN/state-daemon" <<'DAEMON_MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DAEMON_LOG"
if [ "${1:-}" = snapshot-picker ]; then
  snapshot_rows="${DAEMON_SNAPSHOT_ROWS:-}"
  if [ "${DAEMON_SNAPSHOT_ROWS_AFTER_FIRST+x}" = x ]; then
    count_file="${TMUX_MOCK_STATE_DIR:?}/daemon-snapshot-picker-count"
    count=0
    if [ -r "$count_file" ]; then
      read -r count <"$count_file"
    fi
    if [ "$count" -gt 0 ]; then
      snapshot_rows="$DAEMON_SNAPSHOT_ROWS_AFTER_FIRST"
    fi
    printf '%s\n' "$((count + 1))" >"$count_file"
  fi
  printf '%s' "$snapshot_rows"
elif [ "${1:-}" = snapshot ]; then
  printf '%s\n' "${DAEMON_SNAPSHOT:-{\"ok\":true,\"data\":{\"records\":[]}}}"
else
  printf '{"ok":true}\n'
fi
DAEMON_MOCK
chmod +x "$MOCK_BIN/state-daemon"
export DAEMON_LOG TMUX_MOCK_STATE_DIR AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"

cat >"$MOCK_BIN/history-reader" <<'HISTORY_MOCK'
#!/usr/bin/env bash
case "${1:-}" in
list) printf '%s\n' "${HISTORY_MOCK_ROWS:-}" ;;
preview) printf '%s\n' "preview:${2:-}:${3:-}" ;;
esac
HISTORY_MOCK
chmod +x "$MOCK_BIN/history-reader"

FZF_LOG="$TMP_ROOT/fzf.log"
: >"$FZF_LOG"
cat >"$MOCK_BIN/fzf" <<'FZF_MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FZF_LOG"
cat >/dev/null
FZF_MOCK
chmod +x "$MOCK_BIN/fzf"
export FZF_LOG

export PATH="$MOCK_BIN:$PATH"
export TMUX_MOCK_LOG="$TMUX_LOG"

PASS=0
FAIL=0

reset_mocks() {
  : >"$TMUX_LOG"
  : >"$DAEMON_LOG"
  : >"$FZF_LOG"
  rm -f "$TMUX_MOCK_STATE_DIR"/*
  unset DAEMON_SNAPSHOT DAEMON_SNAPSHOT_ROWS DAEMON_SNAPSHOT_ROWS_AFTER_FIRST HISTORY_MOCK_ROWS
  unset TMUX_MOCK_OPTIONS TMUX_MOCK_TARGET_OPTIONS TMUX_MOCK_STATUS_OPTIONS \
    TMUX_MOCK_LIST_SESSIONS TMUX_MOCK_LIST_SESSIONS_AFTER_FIRST \
    TMUX_MOCK_LIST_PANES TMUX_MOCK_LIST_CLIENTS \
    TMUX_MOCK_LIST_PANES_PICKER TMUX_MOCK_LIST_PANES_STATUS \
    TMUX_MOCK_HAS_SESSION TMUX_MOCK_EXISTING_SESSIONS TMUX_MOCK_CURRENT_SESSION \
    TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE TMUX_MOCK_SERVER_PID \
    TMUX_MOCK_FAIL_TARGETS \
    TMUX_MOCK_FAIL_REFRESH_CLIENT TMUX_MOCK_IF_SHELL_RESULT TMUX_MOCK_SHOW_HOOKS \
    TMUX_MOCK_PS_CHILDREN TMUX_MOCK_PS_COMM \
    AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS TMUX_PANE \
    PICKER_NOW
}

pass() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
  [ "$#" -gt 1 ] && printf '  %s\n' "$2" >&2
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected: [$expected], actual: [$actual]"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "missing: [$needle] in [$haystack]"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "unexpected: [$needle] in [$haystack]"
  fi
}

run_bash() {
  (cd "$ROOT" && bash -c "$1")
}

# helpers.sh
reset_mocks
TMUX_MOCK_OPTIONS=$'@foo=bar'
out="$(run_bash '. scripts/helpers.sh; get_tmux_option @foo default')"
assert_eq 'get_tmux_option reads tmux value' 'bar' "$out"

reset_mocks
out="$(run_bash '. scripts/helpers.sh; get_tmux_option @missing default')"
assert_eq 'get_tmux_option returns default when unset' 'default' "$out"

reset_mocks
out="$(run_bash 'AGENT_SESSION_PREFIX=bot-; . scripts/helpers.sh; agent_session_prefix')"
assert_eq 'agent_session_prefix prefers environment override' 'bot-' "$out"

reset_mocks
run_bash 'AGENT_SESSION_PREFIX=bot-; . scripts/helpers.sh; is_managed_session bot-123' >/dev/null
assert_eq 'is_managed_session accepts configured prefix' '0' "$?"
run_bash 'AGENT_SESSION_PREFIX=bot-; . scripts/helpers.sh; is_managed_session agent-123' >/dev/null
assert_eq 'is_managed_session rejects other prefix' '1' "$?"

reset_mocks
out="$(run_bash 'AGENT_DETECT_COMMANDS="pi aider"; . scripts/helpers.sh; is_detected_command aider && printf yes')"
assert_eq 'is_detected_command uses environment command list' 'yes' "$out"

reset_mocks
out="$(run_bash '. scripts/helpers.sh; agents_config "pi --ext"')"
assert_eq 'agents_config defaults include pi/codex/claude' $'pi=pi --ext\ncodex=codex\nclaude=claude' "$out"

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_agents=foo=foo --bar\\nbar=bar --baz'
out="$(run_bash '. scripts/helpers.sh; agent_command bar "pi"')"
assert_eq 'agent_command reads configured registry' 'bar --baz' "$out"
run_bash '. scripts/helpers.sh; agent_command nope "pi"' >/dev/null
assert_eq 'agent_command fails for unknown agent' '1' "$?"
out="$(run_bash '. scripts/helpers.sh; agent_names "pi"')"
assert_eq 'agent_names reads configured registry' $'foo\nbar' "$out"

reset_mocks
out="$(run_bash '. scripts/helpers.sh; session_hash /tmp/project')"
assert_eq 'session_hash is stable and 8 chars' '6533d8b9' "$out"

reset_mocks
out="$(run_bash 'AGENT_DETECT_COMMANDS="pi codex"; . scripts/helpers.sh; resolve_pane_agent codex 123')"
assert_eq 'resolve_pane_agent returns direct detected command' 'codex' "$out"

reset_mocks
out="$(run_bash 'AGENT_DETECT_COMMANDS="pi codex claude"; . scripts/helpers.sh; resolve_pane_agent claude.exe 123')"
assert_eq 'resolve_pane_agent normalizes Claude executable name' 'claude' "$out"

reset_mocks
AGENT_DETECT_COMMANDS='pi codex'
AGENT_DETECT_WRAPPERS='node'
TMUX_MOCK_PS_CHILDREN=$'123=456\n456=789'
TMUX_MOCK_PS_COMM=$'456=bash\n789=codex'
out="$(run_bash '. scripts/helpers.sh; resolve_pane_agent node 123')"
assert_eq 'resolve_pane_agent finds child agent for configured wrapper' 'codex' "$out"

# tmux may report the wrapper basename ("node") while the pane root process has
# renamed itself in place to the real agent ("pi"). The root pid's own comm must
# be detected even when it has no matching descendant.
reset_mocks
AGENT_DETECT_COMMANDS='pi codex'
AGENT_DETECT_WRAPPERS='node'
TMUX_MOCK_PS_CHILDREN=$'0=123'
TMUX_MOCK_PS_COMM=$'123=pi'
out="$(run_bash '. scripts/helpers.sh; resolve_pane_agent node 123')"
assert_eq 'resolve_pane_agent detects renamed-in-place root process' 'pi' "$out"

reset_mocks
TMUX_MOCK_TARGET_OPTIONS=$'%7|@agent_state=done'
run_bash '. scripts/helpers.sh; mark_pane_seen_if_done %7' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'mark_pane_seen_if_done sets pane state to idle' "$log_contents" $'set-option\t-p\t-t\t%7\t@agent_state\tidle'

reset_mocks
TMUX_MOCK_TARGET_OPTIONS=$'%7|@agent_state=working'
run_bash '. scripts/helpers.sh; mark_pane_seen_if_done %7' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'mark_pane_seen_if_done leaves non-done pane unchanged' "$log_contents" $'set-option\t-p\t-t\t%7\t@agent_state\tidle'

# list.sh: a regular terminal client switched directly into a managed session
# must not be mistaken for the nested client created by display-popup.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_SERVER_PID=100
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/1\tagent-a\t300'
TMUX_MOCK_PS_CHILDREN=$'10=300'
run_bash "scripts/list.sh /dev/pts/1" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'list.sh keeps a direct managed-session client attached' "$log_contents" $'detach-client\t'
assert_contains 'list.sh opens picker on the direct managed-session client' "$log_contents" $'display-popup\t-c\t/dev/pts/1'

# A client spawned inside an agent popup is safe to detach, but only that exact
# client should be detached; other clients on its managed session must survive.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_SERVER_PID=100
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/1\twork\t200\n/dev/pts/2\tagent-a\t300'
TMUX_MOCK_PS_CHILDREN=$'100=250\n250=300'
run_bash "scripts/list.sh /dev/pts/2" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'list.sh detaches only the nested popup client' "$log_contents" $'detach-client\t-t\t/dev/pts/2'
assert_not_contains 'list.sh never detaches a whole managed session' "$log_contents" $'detach-client\t-s\t'
assert_contains 'list.sh reopens picker on an outer client' "$log_contents" $'display-popup\t-c\t/dev/pts/1'

# If the invoking client disappears before list.sh resolves it, use another
# valid ordinary client rather than targeting the stale client name.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/1\twork\t200'
run_bash "scripts/list.sh /dev/pts/stale" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'list.sh falls back when invoking client is stale' "$log_contents" $'display-popup\t-c\t/dev/pts/1'
assert_not_contains 'list.sh does not target a stale invoking client' "$log_contents" $'display-popup\t-c\t/dev/pts/stale'

# picker.sh --list
reset_mocks
picker_home="$HOME"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
# Pin now via PICKER_NOW so picker.sh uses the same instant we stamp into the
# mock rows; reading the clock twice would race a one-second boundary and make
# the rendered age (0s) flaky.
picker_now="$(date +%s)"
PICKER_NOW="$picker_now"
TMUX_MOCK_LIST_SESSIONS="agent-pi	blocked	${picker_now}	${picker_home}/proj	pi	pi	1
other	done	${picker_now}	/tmp/x		bash	"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits managed session row identity' "$out" $'session\tagent-pi\t🔴 blocked\tproj\t0s'
assert_contains 'picker --list shortens home path and shows numbered tool' "$out" $'~/proj\tneeds input\tpi-1'
assert_not_contains 'picker --list ignores unmanaged sessions' "$out" $'session\tother'

# picker.sh age column scales seconds/minutes/hours/days.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-a	blocked	$((now_ts - 45))	/tmp/a	pi	pi
agent-b	blocked	$((now_ts - 720))	/tmp/b	pi	pi
agent-c	blocked	$((now_ts - 10800))	/tmp/c	pi	pi
agent-d	blocked	$((now_ts - 172800))	/tmp/d	pi	pi"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list age shows seconds' "$out" $'session\tagent-a\t🔴 blocked\ta\t45s'
assert_contains 'picker --list age shows minutes' "$out" $'session\tagent-b\t🔴 blocked\tb\t12m'
assert_contains 'picker --list age shows hours' "$out" $'session\tagent-c\t🔴 blocked\tc\t3h'
assert_contains 'picker --list age shows days' "$out" $'session\tagent-d\t🔴 blocked\td\t2d'

# Rows within the same rank must sort by real age (youngest first), not by the
# leading number of the humanized age string ("3h" is older than "45s").
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-old	blocked	$((now_ts - 10800))	/tmp/old	pi	pi
agent-new	blocked	$((now_ts - 45))	/tmp/new	pi	pi"
out="$(run_bash 'scripts/picker.sh --list' | cut -f3 | paste -sd, -)"
assert_eq 'picker --list sorts same-rank rows by real age ascending' \
  'agent-new,agent-old' "$out"

# A row with no timestamp renders '-' for its age. It must sort LAST within its
# rank, not first: awk's "-" + 0 is 0, which would otherwise make an unknown
# age look like the youngest row.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-old	blocked	$((now_ts - 10800))	/tmp/old	pi	pi
agent-noage	blocked		/tmp/noage	pi	pi
agent-new	blocked	$((now_ts - 45))	/tmp/new	pi	pi"
out="$(run_bash 'scripts/picker.sh --list' | cut -f3 | paste -sd, -)"
assert_eq 'picker --list sorts unknown age last within its rank' \
  'agent-new,agent-old,agent-noage' "$out"

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits manual pane row' "$out" $'pane\t%1\t🟣 manual \tmanual-proj'
assert_contains 'picker --list describes manual pane agent' "$out" $'/tmp/manual-proj\tpane running pi\tpi'

reset_mocks
# Pin now so picker.sh and the stamped @agent_state_at agree exactly, keeping
# the rendered age deterministic at 0s.
picker_now="$(date +%s)"
PICKER_NOW="$picker_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_TARGET_OPTIONS="%1|@agent_state=done"$'\n'"%1|@agent_state_at=$picker_now"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list reads manual pane state and timestamp' "$out" $'pane\t%1\t🔵 done   \tmanual-proj\t0s'

# Tab mode reloads use --list-mode. History rows retain an absolute cwd and
# resume reference in hidden fields while displaying a compact saved record.
reset_mocks
mode_file="$TMP_ROOT/picker-mode"
printf 'history' >"$mode_file"
TMUX_MOCK_OPTIONS="@agent_history_binary=$MOCK_BIN/history-reader"
PICKER_NOW=200
HISTORY_MOCK_ROWS=$'pi\t/tmp/pi.jsonl\tpi-id\t/Users/example/project\t190\tFix auth\ncodex\t/tmp/codex.jsonl\tcodex-id\t/tmp/code\t180\tReview release\nclaude\t/tmp/claude.jsonl\tclaude-id\t/tmp/docs\t170\tUpdate docs'
out="$(run_bash "scripts/picker.sh --list-mode '$mode_file'")"
assert_contains 'picker history mode lists Pi conversations' "$out" $'history\t/tmp/pi.jsonl\t📚 history\tproject\t10s\t/Users/example/project\tFix auth\tpi'
assert_contains 'picker history mode uses the Pi file as resume reference' "$out" $'pi\t\t/Users/example/project\t/tmp/pi.jsonl'
assert_contains 'picker history mode lists Codex conversations' "$out" $'history\t/tmp/codex.jsonl\t📚 history\tcode\t20s\t/tmp/code\tReview release\tcodex'
assert_contains 'picker history mode uses the Codex id as resume reference' "$out" $'codex\t\t/tmp/code\tcodex-id'
assert_contains 'picker history mode lists Claude conversations' "$out" $'history\t/tmp/claude.jsonl\t📚 history\tdocs\t30s\t/tmp/docs\tUpdate docs\tclaude'

run_bash "scripts/picker.sh --toggle-mode '$mode_file'"
assert_eq 'picker Tab toggle returns history mode to live mode' 'live' "$(<"$mode_file")"
run_bash "scripts/picker.sh --toggle-mode '$mode_file'"
assert_eq 'picker Tab toggle switches live mode to history mode' 'history' "$(<"$mode_file")"

reset_mocks
run_bash 'scripts/picker.sh test-client' >/dev/null
fzf_arguments="$(<"$FZF_LOG")"
assert_contains 'picker binds Tab to toggle live and history modes' "$fzf_arguments" 'tab:execute-silent('
assert_contains 'picker Tab binding reloads the selected mode' "$fzf_arguments" '--list-mode'
assert_contains 'picker uses the shared live/history display field' "$fzf_arguments" '--with-nth=13'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_FAIL_TARGETS='%1'
out="$(run_bash 'scripts/picker.sh --list' 2>/dev/null)"
rc="$?"
assert_eq 'picker --list fails on non-race manual pane option error' '1' "$rc"

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_PANES_PICKER=$'work\t%1\tpi\t123\t/tmp/manual-proj'
TMUX_MOCK_LIST_PANES_STATUS=''
TMUX_MOCK_FAIL_TARGETS='%1'
out="$(run_bash 'scripts/picker.sh --list')"
rc="$?"
assert_eq 'picker --list skips manual pane closed during option query' '0' "$rc"
assert_eq 'picker --list emits no stale row for closed manual pane' '' "$out"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker --list validates closed pane without quiet target suppression' "$log_contents" $'show-options\t-p\t-t\t%1'
assert_not_contains 'picker --list no longer uses quiet option query for race detection' "$log_contents" $'show-options\t-pq\t-t\t%1'

# state.sh
AGENT_TOOL=pi
export AGENT_TOOL
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=on'
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_MOCK_OPTIONS TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh writes pane scoped state' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_contains 'state.sh writes session scoped state for managed sessions' "$log_contents" $'set-option\t-t\tagent-a\t@agent_state\tdone'
daemon_log_contents="$(<"$DAEMON_LOG")"
assert_contains 'state.sh reports state to daemon' "$daemon_log_contents" '"type":"Report"'
assert_contains 'state.sh sends a process generation' "$daemon_log_contents" '"process_generation":'
assert_contains 'state.sh sends a monotonic sequence' "$daemon_log_contents" '"sequence":1'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='work'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh still writes pane scoped state for manual panes' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_not_contains 'state.sh does not pollute manual sessions' "$log_contents" $'set-option\t-t\twork\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh nonsense' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'state.sh ignores invalid states' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tnonsense'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh downgrades done to idle on watched managed pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tidle'
assert_not_contains 'state.sh does not record done on watched managed pane' "$log_contents" $'@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='work'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh downgrades done to idle on watched manual pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tidle'
assert_not_contains 'state.sh does not record done on watched manual pane' "$log_contents" $'@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
export TMUX_PANE TMUX_MOCK_PANE_SESSION
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh keeps done on unwatched managed pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'
assert_contains 'state.sh writes session done on unwatched managed pane' "$log_contents" $'set-option\t-t\tagent-a\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 0 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh keeps done when managed window is inactive' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 1 0'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh done' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh keeps done when managed pane is inactive' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tdone'

reset_mocks
TMUX_PANE='%1'
TMUX_MOCK_PANE_SESSION='agent-a'
TMUX_MOCK_PANE_VISIBLE='1 1 1'
export TMUX_PANE TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE
run_bash 'scripts/state.sh working' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'state.sh does not downgrade working on watched managed pane' "$log_contents" $'set-option\t-p\t-t\t%1\t@agent_state\tworking'
assert_not_contains 'state.sh does not turn working into idle when watched' "$log_contents" $'@agent_state\tidle'
unset AGENT_TOOL

# launch.sh
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='no'
run_bash 'scripts/launch.sh /tmp/project @9' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh creates numbered default session from path hash' "$log_contents" $'new-session\t-d\t-s\tagent-6533d8b9-1\t-c\t/tmp/project'
assert_contains 'launch.sh records instance number' "$log_contents" $'set-option\t-t\tagent-6533d8b9-1\t@agent_instance\t1'
assert_contains 'launch.sh records origin window' "$log_contents" $'set-option\t-t\tagent-6533d8b9-1\t@agent_origin\t@9'
assert_contains 'launch.sh opens popup attached to numbered session' "$log_contents" $'display-popup\t-w\t90%\t-h\t90%\t-E\ttmux attach-session -t agent-6533d8b9-1'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_EXISTING_SESSIONS='agent-pi-6533d8b9-1 agent-pi-6533d8b9-2'
TMUX_MOCK_OPTIONS=$'@agent_agents=pi=pi'
run_bash 'scripts/launch.sh /tmp/project @9 pi' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh chooses the next free instance number' "$log_contents" $'new-session\t-d\t-s\tagent-pi-6533d8b9-3\t-c\t/tmp/project'
assert_contains 'launch.sh labels the selected agent instance' "$log_contents" $'set-option\t-t\tagent-pi-6533d8b9-3\t@agent_instance\t3'
assert_contains 'launch.sh checks numbered sessions by exact name' "$log_contents" $'has-session\t-t\t=agent-pi-6533d8b9-1'

# tmux normally treats a target as a prefix. An existing -10 must not make the
# exact -1 name appear occupied.
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_EXISTING_SESSIONS='agent-pi-6533d8b9-10'
TMUX_MOCK_OPTIONS=$'@agent_agents=pi=pi'
run_bash 'scripts/launch.sh /tmp/project @9 pi' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh does not confuse instance 1 with instance 10' "$log_contents" $'new-session\t-d\t-s\tagent-pi-6533d8b9-1\t-c\t/tmp/project'
assert_not_contains 'launch.sh does not skip free instance 1 due to prefix matching' "$log_contents" $'new-session\t-d\t-s\tagent-pi-6533d8b9-2'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='yes'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex --fast\\npi=pi\n@agent_multiple_instances=off'
run_bash 'scripts/launch.sh /tmp/project @9 codex' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'launch.sh does not recreate existing named session when instances disabled' "$log_contents" $'new-session\t-d\t-s\tagent-codex-6533d8b9'
assert_contains 'launch.sh checks legacy session by exact name' "$log_contents" $'has-session\t-t\t=agent-codex-6533d8b9'
assert_contains 'launch.sh opens existing named session when instances disabled' "$log_contents" $'display-popup\t-w\t90%\t-h\t90%\t-E\ttmux attach-session -t agent-codex-6533d8b9'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex'
run_bash 'scripts/launch.sh /tmp/project @9 nope' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh reports unknown named agent' "$log_contents" $'display-message\tUnknown agent: nope'
assert_not_contains 'launch.sh does not open popup for unknown agent' "$log_contents" $'display-popup'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=pi=pi --custom'
run_bash 'scripts/launch.sh --attach /tmp @9 pi /tmp/pi-session.jsonl' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh resumes Pi history by file' "$log_contents" $'pi --custom --session /tmp/pi-session.jsonl'
assert_contains 'launch.sh records the resumed history reference' "$log_contents" $'@agent_history_id\t/tmp/pi-session.jsonl'
assert_contains 'launch.sh attaches history inside the picker popup' "$log_contents" $'attach-session\t-t\tagent-pi-'
assert_not_contains 'launch.sh does not open a second popup for history' "$log_contents" $'display-popup\t'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex --search\n@agent_multiple_instances=off'
run_bash 'scripts/launch.sh --attach /tmp @9 codex 019f-codex' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh resumes Codex history by session id' "$log_contents" $'codex --search resume 019f-codex'
assert_contains 'launch.sh forces a numbered session for selected history' "$log_contents" $'new-session\t-d\t-s\tagent-codex-'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=claude=claude'
run_bash 'scripts/launch.sh --attach /tmp @9 claude claude-id' >/dev/null
assert_contains 'launch.sh resumes Claude history by session id' "$(<"$TMUX_LOG")" $'claude --resume claude-id'

# daemon client / lifecycle integration
reset_mocks
run_bash 'scripts/event.sh seen-pane %7' >/dev/null
log_contents="$(<"$DAEMON_LOG")"
assert_contains 'event client sends Seen' "$log_contents" '"type":"Seen"'
assert_contains 'event client sends seen pane id' "$log_contents" '"pane_id":"%7"'

reset_mocks
run_bash 'scripts/event.sh exited-pane %8' >/dev/null
assert_contains 'event client sends pane Exited' "$(<"$DAEMON_LOG")" '"type":"Exited"'

reset_mocks
run_bash 'scripts/picker.sh --kill pane %8' >/dev/null
assert_contains 'picker interrupt sends Ctrl-C to manual pane' "$(<"$TMUX_LOG")" $'send-keys\t-t\t%8\tC-c'
assert_not_contains 'picker interrupt does not report a still-running pane as exited' "$(<"$DAEMON_LOG")" '"type":"Exited"'

reset_mocks
run_bash 'scripts/picker.sh --kill session agent-pi' >/dev/null
assert_contains 'picker managed-session kill schedules exit report' "$(<"$TMUX_LOG")" 'event.sh exited-session agent-pi'

# ctrl-r bulk cleanup of stale sessions. Two fixtures drive every case:
# TMUX_MOCK_LIST_SESSIONS rows are "<session>\t<session_attached>", and
# DAEMON_SNAPSHOT_ROWS rows are "<session>\037<pane>\037<state>\037<changedAt>".
# The daemon snapshot is the only source of last-change time on this path: the
# tmux mirror @agent_state_at is written once at launch and never refreshed for
# codex/claude sessions, so it cannot distinguish idle from working.
stale_now=1000000

reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0\nagent-fresh\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'"agent-fresh"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 3600))"$'\n'
out="$(run_bash 'scripts/picker.sh --kill-stale' <<< 'y')"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker stale cleanup kills an unattached session idle past the default 7d' "$log_contents" $'kill-session\t-t\tagent-old'
assert_not_contains 'picker stale cleanup keeps a session idle below the threshold' "$log_contents" $'kill-session\t-t\tagent-fresh'
assert_contains 'picker stale cleanup reports the killed session in the confirmation prompt' "$out" 'agent-old'
assert_contains 'picker stale cleanup schedules an exit report for each killed session' "$log_contents" 'event.sh exited-session agent-old'

# Revalidation after confirmation must observe attachment changes that happened
# while the prompt was open.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-watched\t0'
TMUX_MOCK_LIST_SESSIONS_AFTER_FIRST=$'agent-watched\t1'
DAEMON_SNAPSHOT_ROWS="agent-watched"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
out="$(run_bash 'scripts/picker.sh --kill-stale' <<< 'y')"
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker stale cleanup confirms a session before it becomes attached' "$out" 'agent-watched'
assert_not_contains 'picker stale cleanup skips a confirmed session that becomes attached' "$log_contents" $'kill-session\t-t\tagent-watched'
assert_contains 'picker stale cleanup reports a session skipped after revalidation' "$log_contents" 'skipped 1 that became attached or active'

# Fresh daemon activity reported while confirmation is pending also removes the
# session from the eligible set.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-active\t0'
DAEMON_SNAPSHOT_ROWS="agent-active"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
DAEMON_SNAPSHOT_ROWS_AFTER_FIRST="agent-active"$'\037''%1'$'\037''working'$'\037'"$((stale_now - 60))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'picker stale cleanup skips a confirmed session that reports fresh activity' "$log_contents" $'kill-session\t-t\tagent-active'
assert_contains 'picker stale cleanup reports fresh sessions skipped after revalidation' "$log_contents" 'skipped 1 that became attached or active'

# Revalidation is an intersection with the displayed list, not a new bulk
# selection: a session that only becomes stale after the prompt is shown was
# never confirmed and must remain running.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-confirmed\t0\nagent-newly-stale\t0'
DAEMON_SNAPSHOT_ROWS="agent-confirmed"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'"agent-newly-stale"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 60))"$'\n'
DAEMON_SNAPSHOT_ROWS_AFTER_FIRST="agent-confirmed"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'"agent-newly-stale"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
out="$(run_bash 'scripts/picker.sh --kill-stale' <<< 'y')"
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'picker stale cleanup does not ask for confirmation of a fresh session' "$out" 'agent-newly-stale'
assert_contains 'picker stale cleanup kills a confirmed session that remains stale' "$log_contents" $'kill-session\t-t\tagent-confirmed'
assert_not_contains 'picker stale cleanup never kills a newly stale unconfirmed session' "$log_contents" $'kill-session\t-t\tagent-newly-stale'

# Refusing the prompt must leave every session running.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'n' >/dev/null
assert_not_contains 'picker stale cleanup kills nothing when the confirmation is declined' "$(<"$TMUX_LOG")" 'kill-session'

# An empty answer is not a confirmation.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< '' >/dev/null
assert_not_contains 'picker stale cleanup kills nothing on an empty confirmation' "$(<"$TMUX_LOG")" 'kill-session'

# Attached sessions may report no state change for days while someone is
# actively watching them, so they are never bulk-killed.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-watched\t1'
DAEMON_SNAPSHOT_ROWS="agent-watched"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
assert_not_contains 'picker stale cleanup never kills an attached session' "$(<"$TMUX_LOG")" 'kill-session'

reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'work\t0'
DAEMON_SNAPSHOT_ROWS="work"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
assert_not_contains 'picker stale cleanup never kills an unmanaged session' "$(<"$TMUX_LOG")" 'kill-session'

# The daemon snapshot is the only accepted evidence of age. A session it does
# not know about renders as '-' in the picker and is never bulk-killed, even
# though the tmux mirror written at launch would make it look ancient: that
# mirror is never refreshed for codex/claude sessions, so an actively working
# codex session would otherwise be destroyed.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-codex\t0'
DAEMON_SNAPSHOT_ROWS=''
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'picker stale cleanup never kills a session absent from the daemon snapshot' "$log_contents" 'kill-session'
assert_contains 'picker stale cleanup reports nothing stale when no session has a daemon record' "$log_contents" 'no unattached agent session idle for 7d'

# An unreadable daemon snapshot aborts the whole cleanup instead of degrading to
# the launch-time tmux mirror, which cannot tell a working codex session from an
# abandoned one.
reset_mocks
PICKER_NOW="$stale_now"
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-codex\t0'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"
assert_eq 'picker stale cleanup fails when the daemon snapshot is unavailable' '1' "$rc"
assert_not_contains 'picker stale cleanup kills nothing when the daemon snapshot is unavailable' "$log_contents" 'kill-session'
assert_contains 'picker stale cleanup reports the unavailable daemon on the status line' "$log_contents" 'daemon state unavailable'

reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_stale_kill_age=30m'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0\nagent-fresh\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 3600))"$'\n'"agent-fresh"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 60))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker stale cleanup honors a custom @agent_stale_kill_age' "$log_contents" $'kill-session\t-t\tagent-old'
assert_not_contains 'picker stale cleanup keeps sessions below a custom threshold' "$log_contents" $'kill-session\t-t\tagent-fresh'

# A managed session can own several daemon records at once (a screen record per
# codex/claude pane alongside an event record per pi process generation), and the
# daemon serializes them from a HashMap in arbitrary order. The kill path must
# use the newest one, or an ancient record listed first would destroy a session
# that reported activity a minute ago.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t0'
DAEMON_SNAPSHOT_ROWS="agent-pi"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'"agent-pi"$'\037''%2'$'\037''working'$'\037'"$((stale_now - 60))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
assert_not_contains 'picker stale cleanup uses the newest daemon record when a session has several' "$(<"$TMUX_LOG")" 'kill-session'

# The reverse order must reach the same verdict, proving the result does not
# depend on which record the daemon happened to serialize first.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t0'
DAEMON_SNAPSHOT_ROWS="agent-pi"$'\037''%2'$'\037''working'$'\037'"$((stale_now - 60))"$'\n'"agent-pi"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
assert_not_contains 'picker stale cleanup ignores daemon record order for a multi-record session' "$(<"$TMUX_LOG")" 'kill-session'

# Every record for the session is old, so the newest one is still stale.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t0'
DAEMON_SNAPSHOT_ROWS="agent-pi"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 9 * 86400))"$'\n'"agent-pi"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
assert_contains 'picker stale cleanup kills a session whose newest daemon record is stale' "$(<"$TMUX_LOG")" $'kill-session\t-t\tagent-pi'

# The daemon serializes a missing changedAt as 0 rather than omitting the record;
# treating that as an epoch timestamp would make every such session look ancient.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t0'
DAEMON_SNAPSHOT_ROWS="agent-pi"$'\037''%1'$'\037''idle'$'\037''0'$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
assert_not_contains 'picker stale cleanup never kills on a zero daemon timestamp' "$(<"$TMUX_LOG")" 'kill-session'

# kill-session can fail when a session vanishes during the confirmation window.
# Reporting that as a clean sweep would hide a destructive partial failure.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-gone\t0\nagent-old\t0'
DAEMON_SNAPSHOT_ROWS="agent-gone"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'"agent-old"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 9 * 86400))"$'\n'
TMUX_MOCK_FAIL_TARGETS='agent-gone'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker stale cleanup fails when a session could not be killed' '1' "$rc"
assert_contains 'picker stale cleanup counts only sessions it actually killed' "$log_contents" 'killed 1 agent session(s), 1 could not be killed'
assert_contains 'picker stale cleanup still kills the remaining stale sessions' "$log_contents" $'kill-session\t-t\tagent-old'
assert_not_contains 'picker stale cleanup reports no exit event for a session it failed to kill' "$log_contents" 'event.sh exited-session agent-gone'

# A leading-zero threshold must not leak bash's octal arithmetic error.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_stale_kill_age=08h'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 9 * 3600))"$'\n'
err="$(run_bash 'scripts/picker.sh --kill-stale' <<< 'y' 2>&1 >/dev/null)"
assert_not_contains 'picker stale cleanup parses a leading-zero threshold in base 10' "$err" 'value too great for base'
assert_contains 'picker stale cleanup honors a leading-zero threshold' "$(<"$TMUX_LOG")" $'kill-session\t-t\tagent-old'

# A seconds suffix is accepted and documented alongside the minute/hour/day ones.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_stale_kill_age=90s'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0\nagent-fresh\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 120))"$'\n'"agent-fresh"$'\037''%2'$'\037''idle'$'\037'"$((stale_now - 30))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker stale cleanup honors a seconds-suffixed threshold' "$log_contents" $'kill-session\t-t\tagent-old'
assert_not_contains 'picker stale cleanup keeps sessions below a seconds-suffixed threshold' "$log_contents" $'kill-session\t-t\tagent-fresh'

# Zero means "kill every unattached managed session", which is not a staleness
# rule; reject it with the other invalid thresholds.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_stale_kill_age=0'
TMUX_MOCK_LIST_SESSIONS=$'agent-fresh\t0'
DAEMON_SNAPSHOT_ROWS="agent-fresh"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 60))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker stale cleanup rejects a zero threshold' '1' "$rc"
assert_not_contains 'picker stale cleanup kills nothing on a zero threshold' "$log_contents" 'kill-session'

# Shell arithmetic is 64-bit signed: an absurd digit run multiplied by 86400 can
# wrap to a small positive threshold that would select every unattached session.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_stale_kill_age=9999999999999999d'
TMUX_MOCK_LIST_SESSIONS=$'agent-fresh\t0'
DAEMON_SNAPSHOT_ROWS="agent-fresh"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 60))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker stale cleanup rejects an overflowing threshold' '1' "$rc"
assert_not_contains 'picker stale cleanup kills nothing on an overflowing threshold' "$log_contents" 'kill-session'

reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-\n@agent_stale_kill_age=7 days'
TMUX_MOCK_LIST_SESSIONS=$'agent-old\t0'
DAEMON_SNAPSHOT_ROWS="agent-old"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 8 * 86400))"$'\n'
run_bash 'scripts/picker.sh --kill-stale' <<< 'y' >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker stale cleanup fails on an unparseable @agent_stale_kill_age' '1' "$rc"
assert_not_contains 'picker stale cleanup kills nothing on an unparseable threshold' "$log_contents" 'kill-session'
assert_contains 'picker stale cleanup reports an unparseable threshold' "$log_contents" "invalid @agent_stale_kill_age '7 days'"

# With nothing stale the cleanup reports through the tmux status line and never
# prompts, because fzf redraws over terminal output as soon as it returns.
reset_mocks
PICKER_NOW="$stale_now"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-fresh\t0'
DAEMON_SNAPSHOT_ROWS="agent-fresh"$'\037''%1'$'\037''idle'$'\037'"$((stale_now - 60))"$'\n'
out="$(run_bash 'scripts/picker.sh --kill-stale' < /dev/null)"
assert_not_contains 'picker stale cleanup prompts nothing when no session is stale' "$out" 'Type y to kill'
assert_contains 'picker stale cleanup reports an empty result on the status line' "$(<"$TMUX_LOG")" 'no unattached agent session idle for 7d'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_stale_kill_age=12h'
run_bash 'scripts/picker.sh test-client' >/dev/null
fzf_arguments="$(<"$FZF_LOG")"
assert_contains 'picker binds ctrl-r to the stale-session cleanup' "$fzf_arguments" 'ctrl-r:execute('
assert_contains 'picker ctrl-r binding reloads rows after cleanup' "$fzf_arguments" '--kill-stale'
assert_contains 'picker header shows the configured stale threshold' "$fzf_arguments" 'ctrl-r: kill sessions idle 12h+'

# A missing daemon snapshot must retain the tmux recovery mirror in the picker.
reset_mocks
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
PICKER_NOW=100
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\tdone\t100\t/tmp/project\tpi\tpi\t1'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker falls back to managed tmux mirror when daemon is unavailable' "$out" $'session\tagent-pi\t🔵 done'
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"

reset_mocks
PICKER_NOW=100
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\tdone\t90\t/tmp/project\tpi\tpi\t1'
DAEMON_SNAPSHOT_ROWS=$'agent-pi\037%1\037working\037100\n'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker prefers authoritative daemon snapshot over recovery mirror' "$out" $'session\tagent-pi\t🟡 working'

# agents_session_manager.tmux status badge fragment publication
# The entrypoint is an executable bash script (tpm runs it directly), not a
# sourced library, so invoke it with `bash <file>` rather than run_bash's
# `. scripts/...` style. It publishes @agent_launch_badge and
# @agent_summary_badge for the user to place; it never touches status-right.
run_entrypoint() {
  (cd "$ROOT" && bash agents_session_manager.tmux)
}

# The entrypoint publishes placeable fragments and never rewrites status-right.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status_mouse=off'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint never rewrites status-right' "$log_contents" $'set-option	-g	status-right'
assert_contains 'entrypoint publishes plain launch badge fragment when mouse disabled' "$log_contents" $'set-option	-g	@agent_launch_badge	[+]'
assert_contains 'entrypoint publishes plain summary badge fragment when mouse disabled' "$log_contents" $'set-option	-g	@agent_summary_badge	#{@agent_status_cache}'
assert_not_contains 'entrypoint status fragments perform zero forks' "$log_contents" '#('
assert_contains 'entrypoint ensures and reloads daemon' "$log_contents" 'daemon.sh ensure'

reset_mocks
TMUX_MOCK_SHOW_HOOKS=$'after-kill-pane\nsession-closed'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint skips pane hook without reliable killed-pane identity' "$log_contents" $'set-hook\t-ag\tafter-kill-pane'
assert_contains 'entrypoint appends supported session lifecycle hook' "$log_contents" $'set-hook\t-ag\tsession-closed'

reset_mocks
TMUX_MOCK_SHOW_HOOKS=$'session-closed[0] run-shell "user hook"'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint appends session lifecycle hook when user hook already exists' "$log_contents" $'set-hook\t-ag\tsession-closed'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=off'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint publishes no launch badge when status disabled' "$log_contents" $'set-option	-g	@agent_launch_badge'
assert_not_contains 'entrypoint publishes no summary badge when status disabled' "$log_contents" $'set-option	-g	@agent_summary_badge'
assert_not_contains 'entrypoint publishes no detach badge when status disabled' "$log_contents" $'set-option	-g	@agent_detach_badge'

# Mouse badges: clickable launch/list ranges plus a MouseDown1Status dispatcher.
reset_mocks
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint wraps launch fragment in a clickable range' "$log_contents" $'set-option\t-g\t@agent_launch_badge\t#[range=user|agent_launch][+]#[norange]'
assert_contains 'entrypoint wraps summary fragment in a clickable range' "$log_contents" $'set-option\t-g\t@agent_summary_badge\t#[range=user|agent_list]#{@agent_status_cache}#[norange]'
assert_contains 'entrypoint gates the detach badge on managed sessions with a clickable range' "$log_contents" $'set-option\t-g\t@agent_detach_badge\t#{?#{m:agent-*,#{session_name}},#[range=user|agent_detach][x]#[norange],}'
assert_contains 'entrypoint binds a status mouse dispatcher' "$log_contents" $'bind-key\t-T\troot\tMouseDown1Status'
assert_contains 'entrypoint mouse dispatcher preserves default status click' "$log_contents" 'switch-client -t ='
assert_not_contains 'entrypoint mouse badge fragments perform zero forks' "$log_contents" '#('

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status_launch_label=start\n@agent_status_detach_label=close\n@agent_session_prefix=ai-'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint honors a custom launch label' "$log_contents" $'#[range=user|agent_launch]start#[norange]'
assert_contains 'entrypoint honors a custom detach label and session prefix' "$log_contents" $'set-option\t-g\t@agent_detach_badge\t#{?#{m:ai-*,#{session_name}},#[range=user|agent_detach]close#[norange],}'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status_mouse=off'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint publishes plain summary fragment when mouse disabled' "$log_contents" $'set-option\t-g\t@agent_summary_badge\t#{@agent_status_cache}'
assert_contains 'entrypoint publishes an empty detach badge when mouse disabled' "$log_contents" $'set-option\t-g\t@agent_detach_badge\t'
assert_contains 'entrypoint restores default status click when mouse disabled' "$log_contents" $'bind-key\t-T\troot\tMouseDown1Status\tswitch-client\t-t\t='

# status_click.sh routes ranges to the picker and the launcher entry points.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/9\twork\t400'
run_bash "scripts/status_click.sh agent_list /dev/pts/9 /tmp/proj @1" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status_click list range opens the picker on the clicking client' "$log_contents" $'display-popup\t-c\t/dev/pts/9'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_agents=solo=solo-cmd'
run_bash "scripts/status_click.sh agent_launch /dev/pts/9 /tmp/proj @1" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status_click launch range creates a session for the pane directory' "$log_contents" $'new-session\t-d\t-s'
assert_contains 'status_click launch range launches in the pane directory' "$log_contents" $'-c\t/tmp/proj'

reset_mocks
run_bash "scripts/status_click.sh agent_detach /dev/pts/9 /tmp/proj @1" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'status_click detach range detaches only the clicked client' "$log_contents" $'detach-client\t-t\t/dev/pts/9'
assert_not_contains 'status_click detach range never detaches a whole session' "$log_contents" $'detach-client\t-s\t'

reset_mocks
run_bash "scripts/status_click.sh agent_detach '' /tmp/proj @1" >/dev/null
assert_eq 'status_click detach range without a client is a no-op' '0' "$?"
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'status_click detach range without a client never detaches' "$log_contents" 'detach-client'

reset_mocks
run_bash "scripts/status_click.sh other /dev/pts/9 /tmp/proj @1" >/dev/null
assert_eq 'status_click ignores unknown ranges' '0' "$?"
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'status_click does nothing for unknown ranges' "$log_contents" 'display-popup'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

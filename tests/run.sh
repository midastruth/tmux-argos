#!/usr/bin/env bash
# shellcheck disable=SC2034 # mock configuration variables are consumed by subprocesses
# shellcheck source-path=SCRIPTDIR
# Lightweight unit tests for tmux-argos.
# No external test framework is required; run with: bash tests/run.sh
set -u
# Most tests configure the tmux mock through environment variables. Export new
# assignments by default so subprocesses under run_bash see them.
set -a

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tmux-argos-tests.$$"
MOCK_BIN="$TMP_ROOT/bin"
TMUX_LOG="$TMP_ROOT/tmux.log"
mkdir -p "$MOCK_BIN"
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
  printf '%s' "${DAEMON_SNAPSHOT_ROWS:-}"
elif [ "${1:-}" = snapshot ]; then
  printf '%s\n' "${DAEMON_SNAPSHOT:-{\"ok\":true,\"data\":{\"records\":[]}}}"
else
  printf '{"ok":true}\n'
fi
DAEMON_MOCK
chmod +x "$MOCK_BIN/state-daemon"
export DAEMON_LOG AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"

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
  unset DAEMON_SNAPSHOT DAEMON_SNAPSHOT_ROWS HISTORY_MOCK_ROWS
  unset TMUX_MOCK_OPTIONS TMUX_MOCK_TARGET_OPTIONS TMUX_MOCK_STATUS_OPTIONS \
    TMUX_MOCK_LIST_SESSIONS TMUX_MOCK_LIST_PANES TMUX_MOCK_LIST_CLIENTS \
    TMUX_MOCK_LIST_PANES_PICKER TMUX_MOCK_LIST_PANES_STATUS \
    TMUX_MOCK_HAS_SESSION TMUX_MOCK_EXISTING_SESSIONS TMUX_MOCK_CURRENT_SESSION \
    TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_VISIBLE TMUX_MOCK_SERVER_PID \
    TMUX_MOCK_FAIL_TARGETS \
    TMUX_MOCK_FAIL_REFRESH_CLIENT TMUX_MOCK_FAIL_RUN_SHELL \
    TMUX_MOCK_IF_SHELL_RESULT TMUX_MOCK_SHOW_HOOKS \
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
assert_eq 'picker live rows retain raw state for bulk protection' 'blocked' \
  "$(printf '%s\n' "$out" | cut -f10 | sort -u)"

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
assert_contains 'picker history mode lists Pi conversations' "$out" $'history\t/tmp/pi.jsonl\t📜 history\tproject\t10s\t/Users/example/project\tFix auth\tpi'
assert_contains 'picker history mode uses the Pi file as resume reference' "$out" $'pi\t\t/Users/example/project\t/tmp/pi.jsonl'
assert_contains 'picker history mode lists Codex conversations' "$out" $'history\t/tmp/codex.jsonl\t📜 history\tcode\t20s\t/tmp/code\tReview release\tcodex'
assert_contains 'picker history mode uses the Codex id as resume reference' "$out" $'codex\t\t/tmp/code\tcodex-id'
assert_contains 'picker history mode lists Claude conversations' "$out" $'history\t/tmp/claude.jsonl\t📜 history\tdocs\t30s\t/tmp/docs\tUpdate docs\tclaude'

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
run_bash 'scripts/event.sh exited-sessions agent-one agent-two' >/dev/null
log_contents="$(<"$DAEMON_LOG")"
assert_contains 'event client batch reports the first exited session' "$log_contents" '"session_name":"agent-one"'
assert_contains 'event client batch reports the second exited session' "$log_contents" '"session_name":"agent-two"'
assert_eq 'event client batch sends one request per session sequentially' '2' "$(grep -c '^send ' "$DAEMON_LOG")"

reset_mocks
run_bash 'scripts/picker.sh --kill pane %8' >/dev/null
assert_contains 'picker interrupt sends Ctrl-C to manual pane' "$(<"$TMUX_LOG")" $'send-keys\t-t\t%8\tC-c'
assert_not_contains 'picker interrupt does not report a still-running pane as exited' "$(<"$DAEMON_LOG")" '"type":"Exited"'

reset_mocks
run_bash 'scripts/picker.sh --kill session agent-pi' >/dev/null
assert_contains 'picker managed-session kill schedules exit report' "$(<"$TMUX_LOG")" 'event.sh exited-session agent-pi'

# ctrl-r bulk kill operates on the exact rows currently matched by fzf. The
# fzf {*f} placeholder writes every match to this file, including all visible
# rows when the query is empty.
reset_mocks
matched_file="$TMP_ROOT/matched-rows"
printf '%s\n' \
  $'2\tsession\tagent-one\t🟢 idle   \tone\t1m\t/tmp/one\twaiting\tpi\tidle' \
  $'1\tsession\tagent-two\t🔵 done   \ttwo\t2m\t/tmp/two\tfinished\tpi\tdone' \
  $'2\tpane\t%9\t🟣 manual \tmanual\t-\t/tmp/manual\tpane running pi\tpi\t' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker bulk kill clears the first managed session in an empty-query match set' "$log_contents" $'kill-session\t-t\t=agent-one'
assert_contains 'picker bulk kill clears the second managed session in an empty-query match set' "$log_contents" $'kill-session\t-t\t=agent-two'
assert_not_contains 'picker bulk kill ignores matched manual panes' "$log_contents" $'send-keys\t-t\t%9'
assert_contains 'picker bulk kill reports every killed session with one lifecycle worker' "$log_contents" 'event.sh exited-sessions agent-one agent-two'
assert_eq 'picker bulk kill schedules one lifecycle batch' '1' "$(grep -c $'^run-shell\t-b\t.*event.sh exited-sessions' "$TMUX_LOG")"
assert_contains 'picker bulk kill reports the completed empty-query clear' "$log_contents" 'killed 2 matched session(s), skipped 0 working/blocked'

# A non-empty fzf query passes only its current matches, so sessions outside the
# filtered result are not considered even if they are otherwise idle.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-matched\t🟢 idle   \tmatched\t1m\t/tmp/matched\twaiting\tpi\tidle' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker bulk kill kills a session in the filtered match set' "$log_contents" $'kill-session\t-t\t=agent-matched'
assert_not_contains 'picker bulk kill does not discover sessions outside the fzf match set' "$log_contents" 'list-sessions'

# Both the status embedded in the displayed row and a fresh daemon snapshot can
# protect a session. Any working/blocked daemon record protects the whole
# session when it owns several agent records.
reset_mocks
printf '%s\n' \
  $'3\tsession\tagent-visible-working\t🟡 working\tvisible\t1m\t/tmp/visible\trunning\tpi\tworking' \
  $'2\tsession\tagent-current-blocked\t🟢 idle   \tcurrent\t1m\t/tmp/current\twaiting\tpi\tidle' \
  $'2\tsession\tagent-safe\t⚪ unknown\tsafe\t-\t/tmp/safe\tunknown\tpi\t' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-visible-working\037%1\037idle\037100\nagent-current-blocked\037%2\037idle\037100\nagent-current-blocked\037%3\037blocked\037200'
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'picker bulk kill keeps a session displayed as working' "$log_contents" $'kill-session\t-t\t=agent-visible-working'
assert_not_contains 'picker bulk kill keeps a session with a current blocked daemon record' "$log_contents" $'kill-session\t-t\t=agent-current-blocked'
assert_contains 'picker bulk kill allows a matched session with unknown state' "$log_contents" $'kill-session\t-t\t=agent-safe'
assert_contains 'picker bulk kill reports protected working and blocked sessions' "$log_contents" 'killed 1 matched session(s), skipped 2 working/blocked'

# Duplicate fzf rows must never produce duplicate kill attempts or lifecycle
# events for the same session.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-duplicate\t🟢 idle   \tduplicate\t1m\t/tmp/a\twaiting\tpi\tidle' \
  $'2\tsession\tagent-duplicate\t🟢 idle   \tduplicate\t1m\t/tmp/b\twaiting\tpi\tidle' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
assert_eq 'picker bulk kill de-duplicates matched session rows' '1' "$(grep -c $'^kill-session\t-t\t=agent-duplicate$' "$TMUX_LOG")"

# Manual/history-only matches are a successful no-op and do not require daemon
# state, because neither row represents a managed live session.
reset_mocks
printf '%s\n' \
  $'2\tpane\t%9\t🟣 manual \tmanual\t-\t/tmp/manual\tpane running pi\tpi\t' \
  $'4\thistory\t/tmp/session.jsonl\t📜 history\tproject\t1d\t/tmp/project\ttitle\tpi' \
  >"$matched_file"
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
rc="$?"
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"
assert_eq 'picker bulk kill treats manual and history matches as a no-op' '0' "$rc"
assert_not_contains 'picker bulk kill never kills from manual or history rows' "$(<"$TMUX_LOG")" 'kill-session'
assert_contains 'picker bulk kill reports when the match set has no managed sessions' "$(<"$TMUX_LOG")" 'no managed agent sessions in the current match set'

# Current state is a destructive-operation boundary: unavailable or malformed
# daemon output aborts before any matched session is killed.
reset_mocks
printf '%s\n' $'2\tsession\tagent-safe\t🟢 idle   \tsafe\t1m\t/tmp/safe\twaiting\tpi\tidle' >"$matched_file"
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
rc="$?"
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"
assert_eq 'picker bulk kill fails when current daemon state is unavailable' '1' "$rc"
assert_not_contains 'picker bulk kill kills nothing when daemon state is unavailable' "$(<"$TMUX_LOG")" 'kill-session'

reset_mocks
printf '%s\n' $'2\tsession\tagent-safe\t🟢 idle   \tsafe\t1m\t/tmp/safe\twaiting\tpi\tidle' >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-safe\037%1\037working\037not-a-timestamp'
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails on malformed daemon state' '1' "$rc"
assert_not_contains 'picker bulk kill kills nothing on malformed daemon state' "$(<"$TMUX_LOG")" 'kill-session'
assert_contains 'picker bulk kill reports malformed daemon state' "$(<"$TMUX_LOG")" 'daemon state could not be validated'

# Partial tmux failure is reported accurately, and only successful kills are
# included in the asynchronous lifecycle batch.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-fail\t🟢 idle   \tfail\t1m\t/tmp/fail\twaiting\tpi\tidle' \
  $'2\tsession\tagent-ok\t🟢 idle   \tok\t1m\t/tmp/ok\twaiting\tpi\tidle' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
TMUX_MOCK_FAIL_TARGETS='=agent-fail'
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker bulk kill fails when a matched session could not be killed' '1' "$rc"
assert_contains 'picker bulk kill continues after one tmux kill failure' "$log_contents" $'kill-session\t-t\t=agent-ok'
assert_contains 'picker bulk kill reports the partial failure' "$log_contents" 'killed 1 matched session(s), skipped 0 working/blocked, 1 could not be killed'
exit_report_log="$(grep $'^run-shell\t-b\t' "$TMUX_LOG" || true)"
assert_contains 'picker bulk kill reports successful sessions to the daemon' "$exit_report_log" 'agent-ok'
assert_not_contains 'picker bulk kill does not report a failed kill as exited' "$exit_report_log" 'agent-fail'

# Lifecycle scheduling is best-effort after the irreversible tmux operations.
reset_mocks
printf '%s\n' $'2\tsession\tagent-report-unavailable\t🟢 idle   \treport\t1m\t/tmp/report\twaiting\tpi\tidle' >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
TMUX_MOCK_FAIL_RUN_SHELL=1
run_bash "scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
rc="$?"
assert_eq 'picker bulk kill remains successful when lifecycle scheduling fails after a kill' '0' "$rc"
assert_contains 'picker bulk kill still reports the completed kill when lifecycle scheduling fails' "$(<"$TMUX_LOG")" 'killed 1 matched session(s), skipped 0 working/blocked'

reset_mocks
run_bash 'scripts/picker.sh test-client' >/dev/null
fzf_arguments="$(<"$FZF_LOG")"
assert_contains 'picker binds ctrl-r to kill all current fzf matches' "$fzf_arguments" 'ctrl-r:execute-silent('
assert_contains 'picker bulk binding passes all matched rows through an fzf temporary file' "$fzf_arguments" '--kill-matched {*f}'
assert_contains 'picker ctrl-r binding reloads rows after bulk kill' "$fzf_arguments" '+reload('
assert_contains 'picker header explains the working and blocked protection' "$fzf_arguments" 'kill all matched sessions except working/blocked'

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

# tmux-argos.tmux status badge fragment publication
# The entrypoint is an executable bash script (tpm runs it directly), not a
# sourced library, so invoke it with `bash <file>` rather than run_bash's
# `. scripts/...` style. It publishes @agent_launch_badge and
# @agent_summary_badge for the user to place; it never touches status-right.
run_entrypoint() {
  (cd "$ROOT" && bash tmux-argos.tmux)
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

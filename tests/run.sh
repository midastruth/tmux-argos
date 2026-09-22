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
DAEMON_SNAPSHOT_CALLS="$TMP_ROOT/daemon-snapshot-calls"
: >"$DAEMON_SNAPSHOT_CALLS"
export DAEMON_SNAPSHOT_CALLS
cat >"$MOCK_BIN/state-daemon" <<'DAEMON_MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DAEMON_LOG"
if [ "${1:-}" = snapshot-picker ]; then
  # Record every snapshot request so tests can assert how many times the picker
  # consults authoritative state, and let a test model state that changes
  # between the first read and a later revalidation read.
  printf 'snapshot-picker\n' >>"$DAEMON_SNAPSHOT_CALLS"
  if [ -n "${DAEMON_SNAPSHOT_ROWS_AFTER_FIRST:-}" ] &&
    [ "$(grep -c . "$DAEMON_SNAPSHOT_CALLS")" -gt 1 ]; then
    printf '%s' "$DAEMON_SNAPSHOT_ROWS_AFTER_FIRST"
  else
    printf '%s' "${DAEMON_SNAPSHOT_ROWS:-}"
  fi
elif [ "${1:-}" = snapshot ]; then
  printf '%s\n' "${DAEMON_SNAPSHOT:-{\"ok\":true,\"data\":{\"records\":[]}}}"
else
  if [ -n "${DAEMON_MOCK_FAIL_SEND:-}" ]; then
    exit 1
  fi
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
printf '%s' "${FZF_MOCK_OUTPUT:-}"
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
  : >"$DAEMON_SNAPSHOT_CALLS"
  unset DAEMON_SNAPSHOT DAEMON_SNAPSHOT_ROWS DAEMON_SNAPSHOT_ROWS_AFTER_FIRST \
    HISTORY_MOCK_ROWS FZF_MOCK_OUTPUT
  unset TMUX_MOCK_OPTIONS TMUX_MOCK_TARGET_OPTIONS TMUX_MOCK_STATUS_OPTIONS \
    TMUX_MOCK_LIST_SESSIONS TMUX_MOCK_LIST_PANES TMUX_MOCK_LIST_CLIENTS \
    TMUX_MOCK_CLIENT_CONTEXT \
    TMUX_MOCK_LIST_PANES_PICKER TMUX_MOCK_LIST_PANES_STATUS \
    TMUX_MOCK_HAS_SESSION TMUX_MOCK_NEW_SESSION_ID TMUX_MOCK_EXISTING_SESSIONS TMUX_MOCK_CURRENT_SESSION \
    TMUX_MOCK_PANE_SESSION TMUX_MOCK_PANE_SESSION_ID TMUX_MOCK_PANE_VISIBLE TMUX_MOCK_SERVER_PID \
    TMUX_MOCK_FAIL_TARGETS \
    TMUX_MOCK_FAIL_REFRESH_CLIENT TMUX_MOCK_FAIL_RUN_SHELL \
    TMUX_MOCK_IF_SHELL_RESULT TMUX_MOCK_SHOW_HOOKS \
    TMUX_MOCK_PS_CHILDREN TMUX_MOCK_PS_COMM \
    AGENT_SESSION_PREFIX AGENT_DETECT_COMMANDS AGENT_DETECT_WRAPPERS TMUX_PANE \
    PICKER_NOW DAEMON_MOCK_FAIL_SEND
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
out="$(run_bash '. scripts/helpers.sh; agents_config "pi"')"
assert_eq 'agents_config defaults include direct pi/codex/claude commands' $'pi=pi\ncodex=codex\nclaude=claude' "$out"

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

# Repeating the list binding inside the internal picker client is a toggle, not
# permission to create a popup recursively inside the existing popup.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_TARGET_OPTIONS=$'7|@agent_picker_session=on'
TMUX_MOCK_LIST_CLIENTS=$'/dev/pts/picker\t7\t300'
run_bash "scripts/list.sh /dev/pts/picker" >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'prefix+u inside the picker closes its nested client' "$log_contents" $'detach-client\t-t\t/dev/pts/picker'
assert_not_contains 'prefix+u inside the picker never opens a nested popup' "$log_contents" $'display-popup\t'

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
TMUX_MOCK_LIST_SESSIONS="agent-pi	\$1	blocked	${picker_now}	${picker_home}/proj	pi	pi	1
other	\$2	done	${picker_now}	/tmp/x		bash	"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list emits managed session row identity' "$out" $'session\tagent-pi\t🔴 blocked\tproj\t0s'
assert_contains 'picker --list shortens home path and shows numbered tool' "$out" $'~/proj\tneeds input\tpi-1'
assert_not_contains 'picker --list ignores unmanaged sessions' "$out" $'session\tother'

# tmux metadata may contain row separators. Picker rows must sanitize those
# values before fzf sees them so action fields retain the real immutable ID.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
PICKER_NOW=100
TMUX_MOCK_LIST_SESSIONS=$'agent-injected\t$31\tidle\t100\t/tmp/with\tignored\tignored\t$99\tpi\tpi\t1'
injected_row="$(run_bash 'scripts/picker.sh --list')"
assert_eq 'picker sanitizes tab-containing metadata to the fixed row schema' '13' \
  "$(printf '%s\n' "$injected_row" | awk -F '\t' '{ print NF }')"
assert_eq 'picker tab-containing metadata retains the trusted session ID' "$(printf '$%s' 31)" \
  "$(printf '%s\n' "$injected_row" | cut -f11)"

# @acceptance-id:immutable-session-open
reset_mocks
TMUX_PANE='%90'
TMUX_MOCK_CLIENT_CONTEXT=$'test-client|$0|@38|%41\n/dev/pts/popup|$90|@90|%90'
FZF_MOCK_OUTPUT="$injected_row"
run_bash 'scripts/picker.sh test-client' >/dev/null
assert_contains 'picker Enter cannot open a session ID injected through metadata' "$(<"$TMUX_LOG")" $'switch-client\t-c\t/dev/pts/popup\t-t\t$31'
assert_not_contains 'picker Enter ignores an injected metadata session ID' "$(<"$TMUX_LOG")" $'switch-client\t-c\t/dev/pts/popup\t-t\t$99'

# A picker popup must keep one nested tmux client alive across the Enter
# transition. Starting a second client after fzf exits creates a terminal-mode
# gap where tmux's popup handles Escape itself instead of forwarding it.
reset_mocks
TMUX_PANE='%90'
TMUX_MOCK_CLIENT_CONTEXT=$'/dev/pts/outer|$0|@38|%41\n/dev/pts/popup|$90|@90|%90'
FZF_MOCK_OUTPUT="$injected_row"
run_bash 'scripts/picker.sh /dev/pts/outer' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker Enter reuses the popup tmux client without an input handoff gap' "$log_contents" $'switch-client\t-c\t/dev/pts/popup\t-t\t$31'
assert_not_contains 'picker Enter does not start a second tmux client after fzf exits' "$log_contents" $'attach-session\t-t\t$31'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t$31\tidle\t100\t/tmp/project\tpi\tpi\t1'
TMUX_PANE='%90'
TMUX_MOCK_CLIENT_CONTEXT=$'/dev/pts/1|$0|@38|%41\n/dev/pts/popup|$90|@90|%90'
FZF_MOCK_OUTPUT="$(run_bash 'PICKER_NOW=100 scripts/picker.sh --list')"
run_bash 'scripts/picker.sh /dev/pts/1' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker opening a managed session records the popup host client' "$log_contents" $'set-option\t-t\t$31\t@agent_popup_host_client\t/dev/pts/1'
assert_contains 'picker opening a managed session records the popup host topology' "$log_contents" $'@agent_popup_host_session_id\t$0\t;\tset-option\t-t\t$31\t@agent_popup_host_window_id\t@38\t;\tset-option\t-t\t$31\t@agent_popup_host_pane_id\t%41'
assert_contains 'picker opening a managed session marks the popup active' "$log_contents" $'set-option\t-t\t$31\t@agent_popup_active\ton'
assert_not_contains 'session switch leaves popup activity owned by the popup host' "$log_contents" $'set-option\t-u\t-t\t$31\t@agent_popup_active'
assert_not_contains 'closing the managed popup preserves its popup host preference' "$log_contents" $'set-option\t-u\t-t\t$31\t@agent_popup_host_client'

reset_mocks
TMUX_MOCK_NEW_SESSION_ID="$(printf '$%s' 90)"
TMUX_MOCK_LIST_SESSIONS=$'$31\t/dev/pts/1\ton'
run_bash 'scripts/picker_host.sh /dev/pts/1' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker host marks its internal session against recursive popups' "$log_contents" $'set-option\t-t\t$90\t@agent_picker_session\ton'
assert_contains 'picker host hides status in its internal session' "$log_contents" $'set-option\t-t\t$90\tstatus\toff'
assert_contains 'picker host attaches one nested client before fzf starts' "$log_contents" $'attach-session\t-t\t$90'
assert_contains 'picker host clears popup activity after its nested client exits' "$log_contents" $'set-option\t-u\t-t\t$31\t@agent_popup_active'
assert_contains 'picker host removes its temporary picker session' "$log_contents" $'kill-session\t-t\t$90'

reset_mocks
injected_kind="$(printf '%s\n' "$injected_row" | cut -f2)"
injected_target="$(printf '%s\n' "$injected_row" | cut -f3)"
injected_session_id="$(printf '%s\n' "$injected_row" | cut -f11)"
run_bash "scripts/picker.sh --kill '$injected_kind' '$injected_target' '$injected_session_id'" >/dev/null
assert_contains 'picker ctrl-x cannot kill a session ID injected through metadata' "$(<"$TMUX_LOG")" $'kill-session\t-t\t$31'
assert_not_contains 'picker ctrl-x ignores an injected metadata session ID' "$(<"$TMUX_LOG")" $'kill-session\t-t\t$99'

reset_mocks
matched_file="$TMP_ROOT/injected-matched-row"
printf '%s\n' "$injected_row" >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_bash "printf 'y\\n' | scripts/picker.sh --kill-matched '$matched_file'" >/dev/null
assert_contains 'picker ctrl-r cannot kill a session ID injected through metadata' "$(<"$TMUX_LOG")" $'kill-session\t-t\t$31'
assert_not_contains 'picker ctrl-r ignores an injected metadata session ID' "$(<"$TMUX_LOG")" $'kill-session\t-t\t$99'

# picker.sh age column scales seconds/minutes/hours/days.
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-a	\$1	blocked	$((now_ts - 45))	/tmp/a	pi	pi
agent-b	\$2	blocked	$((now_ts - 720))	/tmp/b	pi	pi
agent-c	\$3	blocked	$((now_ts - 10800))	/tmp/c	pi	pi
agent-d	\$4	blocked	$((now_ts - 172800))	/tmp/d	pi	pi"
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker --list age shows seconds' "$out" $'session\tagent-a\t🔴 blocked\ta\t45s'
assert_contains 'picker --list age shows minutes' "$out" $'session\tagent-b\t🔴 blocked\tb\t12m'
assert_contains 'picker --list age shows hours' "$out" $'session\tagent-c\t🔴 blocked\tc\t3h'
assert_contains 'picker --list age shows days' "$out" $'session\tagent-d\t🔴 blocked\td\t2d'
assert_eq 'picker live rows retain raw state for bulk protection' 'blocked' \
  "$(printf '%s\n' "$out" | cut -f10 | sort -u)"
assert_eq 'picker managed rows retain immutable tmux session IDs' "$(printf '$%s' 1)" \
  "$(printf '%s\n' "$out" | awk -F '\t' '$3 == "agent-a" { print $11 }')"

# Rows within the same rank must sort by real age (youngest first), not by the
# leading number of the humanized age string ("3h" is older than "45s").
reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
now_ts="$(date +%s)"
PICKER_NOW="$now_ts"
TMUX_MOCK_LIST_SESSIONS="agent-old	\$1	blocked	$((now_ts - 10800))	/tmp/old	pi	pi
agent-new	\$2	blocked	$((now_ts - 45))	/tmp/new	pi	pi"
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
TMUX_MOCK_LIST_SESSIONS="agent-old	\$1	blocked	$((now_ts - 10800))	/tmp/old	pi	pi
agent-noage	\$2	blocked		/tmp/noage	pi	pi
agent-new	\$3	blocked	$((now_ts - 45))	/tmp/new	pi	pi"
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

# launch.sh
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_HAS_SESSION='no'
run_bash 'scripts/launch.sh /tmp/project @9' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh creates numbered default session from path hash' "$log_contents" $'new-session\t-d\t-s\tagent-6533d8b9-1\t-c\t/tmp/project'
assert_contains 'launch.sh starts Pi directly without a state extension' "$log_contents" $'new-session\t-d\t-s\tagent-6533d8b9-1\t-c\t/tmp/project\tpi'
assert_not_contains 'launch.sh does not inject the removed Pi state extension' "$log_contents" 'tmux-state.ts'
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

# @acceptance-id:native-history-resume
reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=pi=pi --custom'
run_bash 'scripts/launch.sh --popup-client /dev/pts/popup /tmp @9 pi /tmp/pi-session.jsonl' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh resumes Pi history by file' "$log_contents" $'pi --custom --session /tmp/pi-session.jsonl'
assert_contains 'launch.sh records the resumed history reference' "$log_contents" $'@agent_history_id\t/tmp/pi-session.jsonl'
assert_contains 'launch.sh switches the existing picker client to resumed history' "$log_contents" $'switch-client\t-c\t/dev/pts/popup\t-t\tagent-pi-'
assert_not_contains 'launch.sh does not open a second popup for history' "$log_contents" $'display-popup\t'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=codex=codex --search\n@agent_multiple_instances=off'
run_bash 'scripts/launch.sh --popup-client /dev/pts/popup /tmp @9 codex 019f-codex' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'launch.sh resumes Codex history by session id' "$log_contents" $'codex --search resume 019f-codex'
assert_contains 'launch.sh forces a numbered session for selected history' "$log_contents" $'new-session\t-d\t-s\tagent-codex-'

reset_mocks
TMUX_MOCK_CURRENT_SESSION='work'
TMUX_MOCK_OPTIONS=$'@agent_agents=claude=claude'
run_bash 'scripts/launch.sh --popup-client /dev/pts/popup /tmp @9 claude claude-id' >/dev/null
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
run_bash "scripts/event.sh exited-sessions '\$11' '\$12'" >/dev/null
log_contents="$(<"$DAEMON_LOG")"
assert_contains 'event client batch reports the first exited session ID' "$log_contents" "\"session_id\":\"\$11\""
assert_contains 'event client batch reports the second exited session ID' "$log_contents" "\"session_id\":\"\$12\""
assert_not_contains 'event client no longer reports reusable session names' "$log_contents" '"session_name"'
assert_eq 'event client batch sends one request per session sequentially' '2' "$(grep -c '^send ' "$DAEMON_LOG")"

reset_mocks
run_bash 'scripts/picker.sh --kill pane %8' >/dev/null
assert_contains 'picker interrupt sends Ctrl-C to manual pane' "$(<"$TMUX_LOG")" $'send-keys\t-t\t%8\tC-c'
assert_not_contains 'picker interrupt does not report a still-running pane as exited' "$(<"$DAEMON_LOG")" '"type":"Exited"'

reset_mocks
test_session_id="$(printf '$%s' 9)"
run_bash "scripts/picker.sh --kill session agent-pi '$test_session_id'" >/dev/null
assert_contains 'picker managed-session kill targets the immutable session ID' "$(<"$TMUX_LOG")" $'kill-session\t-t\t$9'
assert_contains 'picker managed-session kill reports the immutable ID synchronously' "$(<"$DAEMON_LOG")" "\"session_id\":\"\$9\""
assert_not_contains 'picker managed-session kill does not report the reusable name' "$(<"$DAEMON_LOG")" '"session_name":"agent-pi"'

# ctrl-r bulk kill operates on the exact rows currently matched by fzf. The
# fzf {*f} placeholder writes every match to this file, including all visible
# rows when the query is empty.
reset_mocks
matched_file="$TMP_ROOT/matched-rows"
run_confirmed_bulk_kill() {
  run_bash "printf 'y\\n' | scripts/picker.sh --kill-matched '$matched_file'"
}

printf '%s\n' \
  $'2\tsession\tagent-cancelled\t🟢 idle   \tcancelled\t1m\t/tmp/cancelled\twaiting\tpi\tidle\t$10\t\tcancelled display' \
  >"$matched_file"
confirmation_output="$(run_bash "printf 'n\\n' | scripts/picker.sh --kill-matched '$matched_file'")"
assert_contains 'picker bulk kill asks for confirmation with the distinct matched-session count' "$confirmation_output" 'Kill eligible managed sessions among 1 currently matched session(s)?'
assert_not_contains 'picker bulk kill cancellation kills no sessions' "$(<"$TMUX_LOG")" 'kill-session'
assert_contains 'picker bulk kill reports cancellation' "$(<"$TMUX_LOG")" 'bulk kill cancelled'
assert_eq 'picker bulk kill cancellation does not request daemon state' '' "$(<"$DAEMON_LOG")"

reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-one\t🟢 idle   \tone\t1m\t/tmp/one\twaiting\tpi\tidle\t$11\t\tone display' \
  $'1\tsession\tagent-two\t🔵 done   \ttwo\t2m\t/tmp/two\tfinished\tpi\tdone\t$12\t\ttwo display' \
  $'2\tpane\t%9\t🟣 manual \tmanual\t-\t/tmp/manual\tpane running pi\tpi\t\t\t\tmanual display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_confirmed_bulk_kill >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker bulk kill clears the first managed session by immutable ID' "$log_contents" $'kill-session\t-t\t$11'
assert_contains 'picker bulk kill clears the second managed session by immutable ID' "$log_contents" $'kill-session\t-t\t$12'
assert_not_contains 'picker bulk kill never targets a reusable session name' "$log_contents" $'kill-session\t-t\t=agent-one'
assert_not_contains 'picker bulk kill ignores matched manual panes' "$log_contents" $'send-keys\t-t\t%9'
daemon_log_contents="$(<"$DAEMON_LOG")"
assert_contains 'picker bulk kill synchronously reports the first killed session ID' "$daemon_log_contents" "\"session_id\":\"\$11\""
assert_contains 'picker bulk kill synchronously reports the second killed session ID' "$daemon_log_contents" "\"session_id\":\"\$12\""
assert_not_contains 'picker bulk kill never reports reusable session names' "$daemon_log_contents" '"session_name"'
assert_not_contains 'picker bulk kill does not defer lifecycle reports to tmux' "$log_contents" 'event.sh exited-sessions'
assert_contains 'picker bulk kill reports the completed empty-query clear' "$log_contents" 'killed 2 matched session(s), skipped 0 working/blocked'

# Lifecycle reports identify the deleted tmux instance, so a same-name
# replacement can report concurrently without being confused with its predecessor.
replacement_request="{\"type\":\"Report\",\"tool\":\"pi\",\"pane_id\":\"%99\",\"process_generation\":\"new-generation\",\"sequence\":1,\"state\":\"idle\",\"session_id\":\"\$99\",\"session_name\":\"agent-one\"}"
run_bash "scripts/daemon.sh send '$replacement_request'" >/dev/null
assert_contains 'same-name replacement reports a distinct immutable ID' "$(<"$DAEMON_LOG")" "\"session_id\":\"\$99\",\"session_name\":\"agent-one\""

# A non-empty fzf query passes only its current matches, so sessions outside the
# filtered result are not considered even if they are otherwise idle.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-matched\t🟢 idle   \tmatched\t1m\t/tmp/matched\twaiting\tpi\tidle\t$13\t\tmatched display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_confirmed_bulk_kill >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker bulk kill kills a session in the filtered match set' "$log_contents" $'kill-session\t-t\t$13'
assert_not_contains 'picker bulk kill does not discover sessions outside the fzf match set' "$log_contents" 'list-sessions'

# A name can be reused while confirmation is open. If the original immutable
# ID no longer exists, the exact ID kill fails instead of deleting its same-name
# replacement.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-reused\t🟢 idle   \treused\t1m\t/tmp/reused\twaiting\tpi\tidle\t$30\t\treused display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
TMUX_MOCK_FAIL_TARGETS="$(printf '$%s' 30)"
run_confirmed_bulk_kill >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker bulk kill fails safely when the matched session ID has exited' '1' "$rc"
assert_contains 'picker bulk kill revalidates only the original immutable ID' "$log_contents" $'display-message\t-p\t-t\t$30\t#{@agent_state}'
assert_not_contains 'picker bulk kill does not issue a kill for an exited immutable ID' "$log_contents" $'kill-session\t-t\t$30'
assert_not_contains 'picker bulk kill never kills a same-name replacement' "$log_contents" $'kill-session\t-t\t=agent-reused'

# Both the status embedded in the displayed row and a fresh daemon snapshot can
# protect a session. Any working/blocked daemon record protects the whole
# session when it owns several agent records.
# @acceptance-id:protected-bulk-kill
reset_mocks
printf '%s\n' \
  $'3\tsession\tagent-visible-working\t🟡 working\tvisible\t1m\t/tmp/visible\trunning\tpi\tworking\t$14\t\tvisible display' \
  $'2\tsession\tagent-current-blocked\t🟢 idle   \tcurrent\t1m\t/tmp/current\twaiting\tpi\tidle\t$15\t\tcurrent display' \
  $'2\tsession\tagent-safe\t⚪ unknown\tsafe\t-\t/tmp/safe\tunknown\tpi\t\t$16\t\tsafe display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-visible-working\037$14\037%1\037idle\037100\nrenamed-current\037$15\037%2\037idle\037100\nrenamed-current\037$15\037%3\037blocked\037200'
run_confirmed_bulk_kill >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'picker bulk kill keeps a session displayed as working' "$log_contents" $'kill-session\t-t\t$14'
assert_not_contains 'picker bulk kill keeps a renamed session with a current blocked daemon record' "$log_contents" $'kill-session\t-t\t$15'
assert_contains 'picker bulk kill allows a matched session with unknown state' "$log_contents" $'kill-session\t-t\t$16'
assert_contains 'picker bulk kill reports protected working and blocked sessions' "$log_contents" 'killed 1 matched session(s), skipped 2 working/blocked'

# Pi updates the tmux mirror before sending its daemon event. Revalidate that
# mirror immediately before deletion so the intervening working transition is
# protected even while both the row and daemon snapshot are still idle.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-transitioning\t🟢 idle   \ttransitioning\t1m\t/tmp/transitioning\twaiting\tpi\tidle\t$25\t\ttransitioning display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-transitioning\037$25\037%1\037idle\037100'
TMUX_MOCK_TARGET_OPTIONS=$'$25|@agent_state=working'
run_confirmed_bulk_kill >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker bulk kill reads the current session mirror immediately before termination' "$log_contents" $'display-message\t-p\t-t\t$25\t#{@agent_state}'
assert_not_contains 'picker bulk kill protects a working tmux-mirror transition' "$log_contents" $'kill-session\t-t\t$25'
assert_contains 'picker bulk kill reports the mirror-protected transition' "$log_contents" 'killed 0 matched session(s), skipped 1 working/blocked'

# Screen detection owns pi/codex/claude state and never writes the session tmux
# mirror, so launch.sh's initial "idle" mirror stays idle for the whole session
# lifetime. The final protection check must therefore consult the authoritative
# daemon state again, not that permanently stale mirror.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-screen-working\t\xf0\x9f\x9f\xa2 idle   \tscreen\t1m\t/tmp/screen\twaiting\tpi\tidle\t$26\t\tscreen display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-screen-working\037$26\037%1\037idle\037100'
DAEMON_SNAPSHOT_ROWS_AFTER_FIRST=$'agent-screen-working\037$26\037%1\037working\037200'
TMUX_MOCK_TARGET_OPTIONS=$'$26|@agent_state=idle'
run_confirmed_bulk_kill >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'picker bulk kill protects a session that started working after the pre-confirmation snapshot' "$log_contents" $'kill-session\t-t\t$26'
assert_contains 'picker bulk kill reports the screen-detected working session as skipped' "$log_contents" 'killed 0 matched session(s), skipped 1 working/blocked'

# The stale session mirror must not be the authority that permits a deletion.
# A session whose only "idle" evidence is that mirror, while authoritative
# state is unavailable for revalidation, must not be killed.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-stale-mirror\t\xf0\x9f\x9f\xa2 idle   \tstale\t1m\t/tmp/stale\twaiting\tpi\tidle\t$27\t\tstale display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-stale-mirror\037$27\037%1\037idle\037100'
DAEMON_SNAPSHOT_ROWS_AFTER_FIRST='__unparseable daemon row__'
TMUX_MOCK_TARGET_OPTIONS=$'$27|@agent_state=idle'
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails when state cannot be revalidated before deletion' '1' "$rc"
assert_not_contains 'picker bulk kill does not fall back to the stale session mirror' "$(<"$TMUX_LOG")" $'kill-session\t-t\t$27'

# Duplicate fzf rows must never produce duplicate kill attempts or lifecycle
# events for the same session.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-duplicate\t🟢 idle   \tduplicate\t1m\t/tmp/a\twaiting\tpi\tidle\t$17\t\tduplicate a display' \
  $'2\tsession\tagent-duplicate\t🟢 idle   \tduplicate\t1m\t/tmp/b\twaiting\tpi\tidle\t$17\t\tduplicate b display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
run_confirmed_bulk_kill >/dev/null
assert_eq 'picker bulk kill de-duplicates matched session rows by immutable ID' '1' "$(grep -c $'^kill-session\t-t\t\$17$' "$TMUX_LOG")"

# Manual/history-only matches are a successful no-op and do not require daemon
# state, because neither row represents a managed live session.
reset_mocks
printf '%s\n' \
  $'2\tpane\t%9\t🟣 manual \tmanual\t-\t/tmp/manual\tpane running pi\tpi\t\t\t\tmanual display' \
  $'4\thistory\t/tmp/session.jsonl\t📜 history\tproject\t1d\t/tmp/project\ttitle\tpi\t\t/tmp/project\tresume-id\thistory display' \
  >"$matched_file"
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
run_confirmed_bulk_kill >/dev/null
rc="$?"
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"
assert_eq 'picker bulk kill treats manual and history matches as a no-op' '0' "$rc"
assert_not_contains 'picker bulk kill never kills from manual or history rows' "$(<"$TMUX_LOG")" 'kill-session'
assert_contains 'picker bulk kill reports when the match set has no managed sessions' "$(<"$TMUX_LOG")" 'no managed agent sessions in the current match set'

# Malformed fzf data aborts the entire destructive action before daemon state
# is requested or any valid session in the same match set is killed.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-valid\t🟢 idle   \tvalid\t1m\t/tmp/valid\twaiting\tpi\tidle\t$18\t\tvalid display' \
  $'2\tsession\tagent-truncated' \
  >"$matched_file"
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails on a truncated matched row' '1' "$rc"
assert_not_contains 'picker bulk kill kills nothing when one matched row is truncated' "$(<"$TMUX_LOG")" 'kill-session'
assert_contains 'picker bulk kill reports malformed matched rows' "$(<"$TMUX_LOG")" 'matched picker rows are malformed'

reset_mocks
printf '%s\n' $'2\tsession\tagent-missing-id\t🟢 idle   \tmissing\t1m\t/tmp/missing\twaiting\tpi\tidle\t\t\tmissing display' >"$matched_file"
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill rejects a managed row without an immutable session ID' '1' "$rc"
assert_not_contains 'picker bulk kill does not fall back to a reusable session name' "$(<"$TMUX_LOG")" 'kill-session'

reset_mocks
printf '%s\n' $'2\tsession\tagent-tab-shifted\t🟢 idle   \tshifted\t1m\t/tmp/with\ttab\twaiting\tpi\tworking\t$19\t\ttab-shifted display' >"$matched_file"
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails when a tab shifts matched row fields' '1' "$rc"
assert_not_contains 'picker bulk kill cannot bypass protected state through a tab-shifted path' "$(<"$TMUX_LOG")" 'kill-session'

reset_mocks
printf '%s\n' $'2\tsession\tagent-newline-shifted\t🟢 idle   \tshifted\t1m\t/tmp/with\nnewline\twaiting\tpi\tworking\t$20\t\tnewline-shifted display' >"$matched_file"
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails when a newline splits a matched row' '1' "$rc"
assert_not_contains 'picker bulk kill cannot bypass protected state through a newline-split path' "$(<"$TMUX_LOG")" 'kill-session'

# Current state is a destructive-operation boundary: unavailable or malformed
# daemon output aborts before any matched session is killed.
reset_mocks
printf '%s\n' $'2\tsession\tagent-safe\t🟢 idle   \tsafe\t1m\t/tmp/safe\twaiting\tpi\tidle\t$21\t\tsafe display' >"$matched_file"
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
run_confirmed_bulk_kill >/dev/null
rc="$?"
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"
assert_eq 'picker bulk kill fails when current daemon state is unavailable' '1' "$rc"
assert_not_contains 'picker bulk kill kills nothing when daemon state is unavailable' "$(<"$TMUX_LOG")" 'kill-session'

# @acceptance-id:malformed-state-fails-closed
reset_mocks
printf '%s\n' $'2\tsession\tagent-safe\t🟢 idle   \tsafe\t1m\t/tmp/safe\twaiting\tpi\tidle\t$21\t\tsafe display' >"$matched_file"
DAEMON_SNAPSHOT_ROWS=$'agent-safe\037$21\037%1\037working\037not-a-timestamp'
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails on malformed daemon state' '1' "$rc"
assert_not_contains 'picker bulk kill kills nothing on malformed daemon state' "$(<"$TMUX_LOG")" 'kill-session'
assert_contains 'picker bulk kill reports malformed daemon state' "$(<"$TMUX_LOG")" 'daemon state could not be validated'

# Partial tmux failure is reported accurately, and only successful kills are
# included in the synchronous lifecycle batch.
reset_mocks
printf '%s\n' \
  $'2\tsession\tagent-fail\t🟢 idle   \tfail\t1m\t/tmp/fail\twaiting\tpi\tidle\t$22\t\tfail display' \
  $'2\tsession\tagent-ok\t🟢 idle   \tok\t1m\t/tmp/ok\twaiting\tpi\tidle\t$23\t\tok display' \
  >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
TMUX_MOCK_FAIL_TARGETS="$(printf '$%s' 22)"
run_confirmed_bulk_kill >/dev/null
rc="$?"
log_contents="$(<"$TMUX_LOG")"
assert_eq 'picker bulk kill fails when a matched session could not be killed' '1' "$rc"
assert_contains 'picker bulk kill continues after one tmux kill failure' "$log_contents" $'kill-session\t-t\t$23'
assert_contains 'picker bulk kill reports the partial failure' "$log_contents" 'killed 1 matched session(s), skipped 0 working/blocked, 1 could not be killed'
exit_report_log="$(<"$DAEMON_LOG")"
assert_contains 'picker bulk kill reports successful session IDs to the daemon' "$exit_report_log" "\"session_id\":\"\$23\""
assert_not_contains 'picker bulk kill does not report a failed kill as exited' "$exit_report_log" "\"session_id\":\"\$22\""

# A lifecycle failure occurs after irreversible tmux operations, so the command
# returns an explicit boundary error and reports that the kill still completed.
reset_mocks
printf '%s\n' $'2\tsession\tagent-report-unavailable\t🟢 idle   \treport\t1m\t/tmp/report\twaiting\tpi\tidle\t$24\t\treport display' >"$matched_file"
DAEMON_SNAPSHOT_ROWS=''
DAEMON_MOCK_FAIL_SEND=1
run_confirmed_bulk_kill >/dev/null
rc="$?"
assert_eq 'picker bulk kill fails when synchronous lifecycle reporting fails after a kill' '1' "$rc"
assert_contains 'picker bulk kill reports completed kill and lifecycle failure' "$(<"$TMUX_LOG")" 'killed 1 matched session(s), skipped 0 working/blocked; daemon exit report failed'

reset_mocks
run_bash 'scripts/picker.sh test-client' >/dev/null
fzf_arguments="$(<"$FZF_LOG")"
assert_contains 'picker binds ctrl-r to an interactive confirmation action' "$fzf_arguments" 'ctrl-r:execute('
assert_not_contains 'picker bulk confirmation is not hidden by execute-silent' "$fzf_arguments" 'ctrl-r:execute-silent('
assert_contains 'picker bulk binding passes all matched rows through an fzf temporary file' "$fzf_arguments" '--kill-matched {*f}'
assert_contains 'picker single-session kill passes the immutable session ID' "$fzf_arguments" '--kill {2} {3} {11}'
assert_contains 'picker preview passes the immutable session ID' "$fzf_arguments" '--preview {2} {3} {9} {11}'
assert_contains 'picker ctrl-r binding reloads rows after bulk kill' "$fzf_arguments" '+reload('
assert_contains 'picker header explains confirmation and protected states' "$fzf_arguments" 'confirm bulk kill except working/blocked'

reset_mocks
TMUX_PANE='%90'
TMUX_MOCK_CLIENT_CONTEXT=$'test-client|$0|@38|%41\n/dev/pts/popup|$90|@90|%90'
FZF_MOCK_OUTPUT=$'2\tsession\tstale-reused-name\t🟢 idle   \tproject\t1m\t/tmp/project\twaiting\tpi\tidle\t$44\t\tdisplay'
run_bash 'scripts/picker.sh test-client' >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'picker opens the selected managed session by immutable ID' "$log_contents" $'switch-client\t-c\t/dev/pts/popup\t-t\t$44'
assert_not_contains 'picker never opens a same-name replacement' "$log_contents" $'switch-client\t-c\t/dev/pts/popup\t-t\tstale-reused-name'

# A missing daemon snapshot must retain the tmux recovery mirror in the picker.
reset_mocks
AGENT_DAEMON_BINARY="$TMP_ROOT/missing-daemon"
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
PICKER_NOW=100
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t$1\tdone\t100\t/tmp/project\tpi\tpi\t1'
out="$(run_bash 'scripts/picker.sh --list')"
assert_contains 'picker falls back to managed tmux mirror when daemon is unavailable' "$out" $'session\tagent-pi\t🔵 done'
AGENT_DAEMON_BINARY="$MOCK_BIN/state-daemon"

reset_mocks
PICKER_NOW=100
TMUX_MOCK_OPTIONS=$'@agent_session_prefix=agent-'
TMUX_MOCK_LIST_SESSIONS=$'agent-pi\t$1\tdone\t90\t/tmp/project\tpi\tpi\t1'
DAEMON_SNAPSHOT_ROWS=$'renamed-agent-pi\037$1\037%1\037working\037100\n'
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
assert_not_contains 'entrypoint does not add an unreliable pane lifecycle hook' "$log_contents" $'set-hook\t-ag\tafter-kill-pane'
assert_not_contains 'entrypoint does not add a name-based session lifecycle hook' "$log_contents" $'set-hook\t-ag\tsession-closed'

reset_mocks
TMUX_MOCK_SHOW_HOOKS=$'session-closed[0] run-shell "user hook"'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_not_contains 'entrypoint preserves unrelated user lifecycle hooks' "$log_contents" $'set-hook\t-gu\tsession-closed[0]'

reset_mocks
TMUX_MOCK_SHOW_HOOKS="session-closed[3] run-shell \"$ROOT/scripts/event.sh exited-session '#{hook_session_name}'\""
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint removes its obsolete name-based lifecycle hook' "$log_contents" $'set-hook\t-gu\tsession-closed[3]'
assert_not_contains 'entrypoint does not replace it with another unreliable hook' "$log_contents" $'set-hook\t-ag\tsession-closed'

reset_mocks
TMUX_MOCK_OPTIONS=$'@agent_status=off'
run_entrypoint >/dev/null
log_contents="$(<"$TMUX_LOG")"
assert_contains 'entrypoint clears a stale launch badge when status is disabled' "$log_contents" $'set-option\t-g\t@agent_launch_badge\t'
assert_contains 'entrypoint clears a stale summary badge when status is disabled' "$log_contents" $'set-option\t-g\t@agent_summary_badge\t'
assert_contains 'entrypoint clears a stale detach badge when status is disabled' "$log_contents" $'set-option\t-g\t@agent_detach_badge\t'
assert_contains 'entrypoint clears the status cache when status is disabled' "$log_contents" $'set-option\t-g\t@agent_status_cache\t'

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

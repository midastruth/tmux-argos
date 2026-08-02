#!/usr/bin/env bash
# Send lifecycle/discovery events to the state daemon.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

json_string() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '"%s"' "$value"
}

send_request() {
  local request="$1"
  "$DIR/daemon.sh" send "$request" >/dev/null
}

kind="${1:-}"
case "$kind" in
seen-pane)
  [ -n "${2:-}" ] || exit 1
  request="{\"type\":\"Seen\",\"pane_id\":$(json_string "$2")}"
  ;;
exited-pane)
  [ -n "${2:-}" ] || exit 1
  request="{\"type\":\"Exited\",\"pane_id\":$(json_string "$2"),\"session_id\":null}"
  ;;
exited-session)
  [[ "${2:-}" =~ ^\$[0-9]+$ ]] || exit 1
  request="{\"type\":\"Exited\",\"pane_id\":null,\"session_id\":$(json_string "$2")}"
  ;;
exited-sessions)
  shift
  [ "$#" -gt 0 ] || exit 1
  for session_id in "$@"; do
    [[ "$session_id" =~ ^\$[0-9]+$ ]] || exit 1
    request="{\"type\":\"Exited\",\"pane_id\":null,\"session_id\":$(json_string "$session_id")}"
    send_request "$request" || exit 1
  done
  exit 0
  ;;
*) exit 1 ;;
esac
send_request "$request"

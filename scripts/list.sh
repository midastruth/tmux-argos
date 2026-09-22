#!/usr/bin/env bash
# Open the agent session picker in a popup.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Avoid reading the same tmux option once per client while locating host/nested
# sessions.
AGENT_SESSION_PREFIX="$(agent_session_prefix)"
export AGENT_SESSION_PREFIX

# The client that invoked the binding (#{client_name}). Prefer hosting the
# popup here so it always opens on the terminal the user pressed the key in,
# even when several clients are attached to the same session.
invoking_client="${1:-}"

w="$(get_tmux_option @agent_popup_width '90%')"
h="$(get_tmux_option @agent_popup_height '90%')"

# A popup command is spawned below the tmux server, so the client created by
# `tmux attach-session` inside it has the server pid in its process ancestry. A
# client attached directly from a terminal does not. Session name alone cannot
# distinguish them: choose-tree can switch a regular client into a managed
# session, and detaching that client would kick the user out of tmux.
is_server_spawned_client() {
  local client="$1" pid server_pid parent_pid
  pid="$(tmux list-clients -F '#{client_name}	#{client_pid}' 2>/dev/null |
    awk -F '\t' -v me="$client" '$1 == me { print $2; exit }')"
  server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null)"

  case "$pid:$server_pid" in
  *[!0-9:]*|:*|*:) return 1 ;;
  esac

  while [ "$pid" -gt 1 ] 2>/dev/null; do
    parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ "$parent_pid" = "$server_pid" ] && return 0
    if [ -z "$parent_pid" ] || [ "$parent_pid" = "$pid" ]; then
      break
    fi
    pid="$parent_pid"
  done
  return 1
}

client_session() {
  local wanted="$1" client session
  tmux list-clients -F '#{client_name}	#{session_name}' 2>/dev/null |
    while IFS=$'\t' read -r client session; do
      [ "$client" = "$wanted" ] && { printf '%s\n' "$session"; break; }
    done
}

client_exists() {
  local wanted="$1"
  tmux list-clients -F '#{client_name}' 2>/dev/null |
    awk -v me="$wanted" '$0 == me { found=1 } END { exit !found }'
}

# Pick an ordinary client to host the picker after a nested client detaches.
# tmux exposes no popup-owner format, so exact parent selection would require
# an explicit mapping recorded when the popup is created.
host_client() {
  local client session
  tmux list-clients -F '#{client_name}	#{session_name}' 2>/dev/null |
    while IFS=$'\t' read -r client session; do
      is_managed_session "$session" || { printf '%s\n' "$client"; break; }
    done
}

my_session=''
[ -n "$invoking_client" ] && my_session="$(client_session "$invoking_client")"
host=''

# The picker itself owns one nested client. Treat the same binding there as a
# close toggle; opening another popup on that client would recurse indefinitely.
picker_session_marker=''
if [ -n "$my_session" ]; then
  picker_session_marker="$(tmux show-options -qv -t "$my_session" @agent_picker_session 2>/dev/null || true)"
fi
if [ "$picker_session_marker" = on ]; then
  tmux detach-client -t "$invoking_client"
  exit $?
fi

if [ -n "$my_session" ] && is_managed_session "$my_session" &&
  is_server_spawned_client "$invoking_client"; then
  # This is an actual nested client, not a regular client switched into the
  # managed session via choose-tree. Find its outer client before detaching it.
  host="$(host_client)"
  if [ -n "$host" ]; then
    # Detach only this client. `-s <session>` would detach every client viewing
    # the managed session, including unrelated terminals.
    tmux detach-client -t "$invoking_client"
    for _ in $(seq 1 20); do
      client_exists "$invoking_client" || break
      sleep 0.05
    done
  fi
elif [ -n "$my_session" ]; then
  # Normal pane, including a direct choose-tree switch into a managed session.
  host="$invoking_client"
fi

# If the invoking client disappeared or could not be resolved, retain the old
# best-effort fallback to another ordinary client.
[ -n "$host" ] || host="$(host_client)"

# Host the picker on the outer client. The host script attaches one nested tmux
# client before starting fzf; Enter can then switch that existing client without
# exposing a terminal-mode gap where the popup itself would consume Escape.
picker_host_q=$(printf '%q' "$DIR/picker_host.sh")
host_q=$(printf '%q' "$host")
if [ -n "$host" ]; then
  tmux display-popup -c "$host" -w "$w" -h "$h" -E "$picker_host_q $host_q"
else
  tmux display-popup -w "$w" -h "$h" -E "$picker_host_q"
fi

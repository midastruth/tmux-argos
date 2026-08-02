#!/usr/bin/env bash
# Thin client for the per-tmux-server Rust state daemon.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

if [ -n "${AGENT_DAEMON_BINARY:-}" ]; then
  binary="$AGENT_DAEMON_BINARY"
else
  binary="$(get_tmux_option @agent_daemon_binary "$ROOT/daemon/target/release/tmux-argos-state-daemon")"
fi
if [ ! -x "$binary" ]; then
  tmux display-message "tmux-argos: daemon binary missing; run cargo build --release --manifest-path $ROOT/daemon/Cargo.toml" 2>/dev/null || true
  exit 1
fi
exec "$binary" "$@"

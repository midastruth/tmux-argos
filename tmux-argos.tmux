#!/usr/bin/env bash
# tmux-argos plugin entrypoint.
set -uo pipefail
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @agent_launch_key 'y')"
list_key="$(get_tmux_option @agent_list_key 'u')"
daemon_binary="$(get_tmux_option @agent_daemon_binary "$CURRENT_DIR/daemon/target/release/tmux-argos-state-daemon")"
tmux set-option -gq @agent_daemon_binary "$daemon_binary"

launch_menu_q=$(printf '%q' "$CURRENT_DIR/scripts/launch_menu.sh")
tmux bind-key "$launch_key" run-shell "$launch_menu_q '#{pane_current_path}' '#{window_id}'"
list_q=$(printf '%q' "$CURRENT_DIR/scripts/list.sh")
tmux bind-key "$list_key" run-shell "$list_q '#{client_name}'"

status_enabled="$(get_tmux_option @agent_status 'on')"
status_mouse="$(get_tmux_option @agent_status_mouse 'on')"
if [ "$status_enabled" = on ]; then
  # Publish two independently-placeable status fragments instead of injecting
  # status-right. Place either fragment anywhere in your own status-left or
  # status-right, wrapping the summary in #{E:...} because tmux expands status
  # formats only one level and the summary fragment nests the daemon-updated
  # #{@agent_status_cache}:
  #   set -g status-right '#{E:@agent_launch_badge} #{E:@agent_summary_badge}'
  launch_label="$(get_tmux_option @agent_status_launch_label '[+]')"
  detach_label="$(get_tmux_option @agent_status_detach_label '[x]')"
  # The detach badge is a click-to-close affordance for the agent popup. It must
  # only appear while the drawing client sits in a managed agent session, so gate
  # it on the session name matching @agent_session_prefix. Embed the literal
  # prefix here because the format is evaluated per-client at draw time. The
  # #{?...}/#{m:...} test is native, so this stays zero-fork.
  session_prefix="$(agent_session_prefix)"
  if [ "$status_mouse" = on ]; then
    # Wrap each fragment in its own user-defined status range so tmux reports
    # which part was clicked via #{mouse_status_range}. The launch badge is a
    # stable click target even when no agents run; the summary range has zero
    # width while @agent_status_cache is empty. Range markers add no #()
    # expansion, so referencing these fragments stays zero-fork.
    tmux set-option -g @agent_launch_badge "#[range=user|agent_launch]${launch_label}#[norange]"
    tmux set-option -g @agent_summary_badge '#[range=user|agent_list]#{@agent_status_cache}#[norange]'
    tmux set-option -g @agent_detach_badge "#{?#{m:${session_prefix}*,#{session_name}},#[range=user|agent_detach]${detach_label}#[norange],}"
  else
    tmux set-option -g @agent_launch_badge "$launch_label"
    tmux set-option -g @agent_summary_badge '#{@agent_status_cache}'
    # Without mouse support the detach badge has no click target and would only
    # show a misleading close glyph, so publish it empty.
    tmux set-option -g @agent_detach_badge ''
  fi
else
  # A reload must remove fragments published by an earlier enabled run.
  tmux set-option -g @agent_launch_badge ''
  tmux set-option -g @agent_summary_badge ''
  tmux set-option -g @agent_detach_badge ''
  tmux set-option -g @agent_status_cache ''
fi

# Left-clicking the launch/list badges routes to the same scripts as the
# prefix+y / prefix+u bindings. Overriding MouseDown1Status replaces the default
# window-switch click, so restore it in the else branch for clicks outside our
# ranges. Requires `set -g mouse on`; without it tmux delivers no status clicks.
if [ "$status_enabled" = on ] && [ "$status_mouse" = on ]; then
  status_click_q=$(printf '%q' "$CURRENT_DIR/scripts/status_click.sh")
  clicked_agent_range='#{||:#{==:#{mouse_status_range},agent_detach},#{||:#{==:#{mouse_status_range},agent_list},#{==:#{mouse_status_range},agent_launch}}}'
  dispatch_click="run-shell \"$status_click_q '#{mouse_status_range}' '#{client_name}' '#{pane_current_path}' '#{window_id}'\""
  tmux bind-key -T root MouseDown1Status if-shell -F "$clicked_agent_range" "$dispatch_click" "switch-client -t ="
else
  # A previous reload with mouse support enabled may have left our dispatcher
  # bound. Restore tmux's default MouseDown1Status (switch-client -t =) so
  # disabling @agent_status_mouse fully reverts to stock click behavior.
  tmux bind-key -T root MouseDown1Status switch-client -t =
fi

# tmux's session-closed hook exposes only the reusable session name, not the
# immutable session ID. The daemon reconciles its records against live pane and
# session IDs instead. Remove obsolete hooks owned by this checkout without
# touching user hooks.
existing_hook="$(tmux show-hooks -g session-closed 2>/dev/null || true)"
while IFS= read -r hook_line; do
  if [[ "$hook_line" == session-closed\[* ]] &&
    [[ "$hook_line" == *"$CURRENT_DIR/scripts/event.sh"* ]]; then
    hook_slot="${hook_line%% *}"
    tmux set-hook -gu "$hook_slot"
  fi
done <<< "$existing_hook"

# ensure is idempotent and starts one daemon per tmux server. ReloadConfig keeps
# a running daemon while atomically retaining its old config on validation error.
daemon_q=$(printf '%q' "$CURRENT_DIR/scripts/daemon.sh")
tmux run-shell -b "$daemon_q ensure >/dev/null 2>&1 && $daemon_q reload >/dev/null 2>&1"

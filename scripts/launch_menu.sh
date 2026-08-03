#!/usr/bin/env bash
# Choose which agent to launch for the current directory, then hand off to
# launch.sh. With a single configured agent (or @agent_launch_menu off)
# it skips the menu and launches directly, preserving the original prefix+y behaviour.
# Args: [--select <output-file>] <dir> [origin-window-id]
#   <dir> / [origin-window-id] are expanded by run-shell in the binding.

# macOS still ships bash 3.2 as /bin/bash, which lacks features this menu relies
# on (notably `read -t` with fractional seconds for arrow keys). If we're running
# under an old bash, re-exec with a newer one from PATH (e.g. Homebrew bash).
if [ -z "${AGENT_MENU_REEXEC:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  for _bash in /opt/homebrew/bin/bash /usr/local/bin/bash bash; do
    _bin="$(command -v "$_bash" 2>/dev/null)" || continue
    # shellcheck disable=SC2016 # expansion must happen in the re-exec'd bash
    _ver="$("$_bin" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
    if [ "${_ver:-0}" -ge 4 ] 2>/dev/null; then
      export AGENT_MENU_REEXEC=1
      exec "$_bin" "${BASH_SOURCE[0]}" "$@"
    fi
  done
fi

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

select_out=''
if [ "${1:-}" = '--select' ]; then
  # --select requires an output file. Without one there is nowhere to report
  # the chosen agent, and `shift 2` would fail leaving '--select' in $1 to be
  # misread as the directory. Only used internally, but fail cleanly anyway.
  [ -n "${2:-}" ] || exit 0
  select_out="$2"
  shift 2
fi

path="${1:-$PWD}"
window="${2:-}"
default_cmd='pi'

# Collect configured agent names. Avoid bash 4's `mapfile` so this keeps working
# on macOS's default /bin/bash 3.2.
names=()
while IFS= read -r _name; do
  [ -n "$_name" ] && names+=("$_name")
done < <(agent_names "$default_cmd")

show_menu="$(get_tmux_option @agent_launch_menu 'on')"

# A single configured agent: launch it directly because there is nothing to
# choose. Menu disabled with multiple agents: keep the default launch path.
if [ -z "$select_out" ]; then
  if [ "${#names[@]}" -le 1 ]; then
    if [ "${#names[@]}" -eq 1 ]; then
      exec "$DIR/launch.sh" "$path" "$window" "${names[0]}"
    fi
    exec "$DIR/launch.sh" "$path" "$window"
  fi
  if [ "$show_menu" != on ]; then
    exec "$DIR/launch.sh" "$path" "$window"
  fi
fi

repeat_char() {
  local char="$1" count="$2" out=''
  while [ "$count" -gt 0 ]; do
    out="$out$char"
    count=$((count - 1))
  done
  printf '%s' "$out"
}

render_menu() {
  local selected="$1" i label title label_width inner_width title_width pad_right
  local top bottom line
  title=' Launch agent '
  label_width=0
  for i in "${!names[@]}"; do
    label=$(printf '%-8s (%d)' "${names[$i]}" "$((i + 1))")
    [ "${#label}" -gt "$label_width" ] && label_width=${#label}
  done
  title_width=${#title}
  inner_width=$((label_width + 2))
  [ "$inner_width" -lt "$title_width" ] && inner_width=$title_width

  pad_right=$((inner_width - title_width))
  top="┌${title}$(repeat_char '─' "$pad_right")┐"
  bottom="└$(repeat_char '─' "$inner_width")┘"

  printf '\033[2J\033[H\033[?25l'
  printf '%s\n' "$top"
  for i in "${!names[@]}"; do
    label=$(printf '%-8s (%d)' "${names[$i]}" "$((i + 1))")
    line=$(printf ' %-*s ' "$label_width" "$label")
    # If the title forced the menu wider than the labels, pad the entry too.
    line=$(printf '%-*s' "$inner_width" "$line")
    if [ "$i" -eq "$selected" ]; then
      printf '│\033[7m%s\033[0m│\n' "$line"
    else
      printf '│%s│\n' "$line"
    fi
  done
  printf '%s' "$bottom"
}

# The menu is drawn with the top border on terminal row 1, so entry i (0-based)
# occupies row i+2. Convert an SGR mouse row back to an entry index; prints the
# index when the row lands on an entry, otherwise returns non-zero.
mouse_row_to_index() {
  local row="$1" count="$2" idx
  [[ "$row" =~ ^[0-9]+$ ]] || return 1
  idx=$((row - 2))
  [ "$idx" -ge 0 ] && [ "$idx" -lt "$count" ] || return 1
  printf '%s' "$idx"
}

choose_agent() {
  local selected_index="$1"
  printf '%s' "${names[$selected_index]}" >"$select_out"
  exit 0
}

handle_mouse_selection() {
  local count="$1" payload='' final='' character button coordinates row selected_index
  while IFS= read -rsn1 -t 0.1 character; do
    case "$character" in
    M|m) final="$character"; break ;;
    *) payload="$payload$character" ;;
    esac
  done
  button="${payload%%;*}"
  coordinates="${payload#*;}"
  row="${coordinates#*;}"
  [ "$button" = '0' ] || return 0
  [ "$final" = 'M' ] || return 0
  selected_index="$(mouse_row_to_index "$row" "$count")" || return 0
  choose_agent "$selected_index"
}

handle_escape_sequence() {
  local count="$1" intro kind
  IFS= read -rsn1 -t 0.03 intro || exit 0
  [ "$intro" = '[' ] || exit 0
  IFS= read -rsn1 -t 0.03 kind || exit 0
  case "$kind" in
  A) selected=$(((selected + count - 1) % count)) ;;
  B) selected=$(((selected + 1) % count)) ;;
  '<') handle_mouse_selection "$count" ;;
  esac
}

handle_menu_key() {
  local key="$1" count="$2" selected_index
  case "$key" in
  $'\x0e') selected=$(((selected + 1) % count)) ;;
  $'\x10') selected=$(((selected + count - 1) % count)) ;;
  ''|$'\r'|$'\n') choose_agent "$selected" ;;
  q|Q) exit 0 ;;
  $'\x1b') handle_escape_sequence "$count" ;;
  [1-9])
    selected_index=$((key - 1))
    [ "$selected_index" -lt "$count" ] && choose_agent "$selected_index"
    ;;
  esac
}

select_agent() {
  local selected=0 count key
  count=${#names[@]}
  [ "$count" -gt 0 ] || exit 0
  [ -n "$select_out" ] || exit 0
  while :; do
    render_menu "$selected"
    IFS= read -rsn1 key || exit 0
    handle_menu_key "$key" "$count"
  done
}

if [ -n "$select_out" ]; then
  # Enable SGR mouse reporting (1000: button events, 1006: SGR extended coords)
  # so clicks arrive as escape sequences. Restore the cursor and disable mouse
  # reporting on exit so the terminal is left in a clean state.
  printf '\033[?1000h\033[?1006h'
  trap 'printf "\033[?1000l\033[?1006l\033[?25h"' EXIT
  select_agent
fi

# Native tmux display-menu only supports Enter/Up/Down/q plus item shortcut
# keys; it cannot bind Ctrl+n/Ctrl+p for movement. Use a borderless popup that
# draws the same compact menu shape, then launch the selected agent after the
# selector exits so the agent still opens in the normal full-size popup.
tmp="$(mktemp "${TMPDIR:-/tmp}/agent-launch.XXXXXX")" || exit 0
trap 'rm -f "$tmp"' EXIT

label_width=0
for i in "${!names[@]}"; do
  label=$(printf '%-8s (%d)' "${names[$i]}" "$((i + 1))")
  [ "${#label}" -gt "$label_width" ] && label_width=${#label}
done
inner_width=$((label_width + 2))
[ "$inner_width" -lt 14 ] && inner_width=14
w=$((inner_width + 2))
h=$((${#names[@]} + 2))

self_q=$(printf '%q' "$DIR/launch_menu.sh")
tmp_q=$(printf '%q' "$tmp")
path_q=$(printf '%q' "$path")
window_q=$(printf '%q' "$window")

tmux display-popup -B -w "$w" -h "$h" -E "$self_q --select $tmp_q $path_q $window_q"

agent=''
[ -s "$tmp" ] && agent="$(<"$tmp")"
# exec replaces this process without running the EXIT trap, so remove the
# temp file explicitly first or every successful selection leaks one file.
rm -f "$tmp"
trap - EXIT
[ -n "$agent" ] || exit 0
exec "$DIR/launch.sh" "$path" "$window" "$agent"

# tmux-argos

Run many coding-agent sessions across your projects — [Pi](https://pi.dev),
[Codex](https://openai.com/codex/), [Claude Code](https://www.anthropic.com/claude-code),
or any CLI agent — each inside its own tmux session. Then list them, preview
them, see which ones are working vs. finished, and jump back to any session from
one popup.

This is a tmux plugin for people who launch coding agents per project directory.
It can keep multiple numbered nested sessions per directory/agent and gives you
a central picker for all of them. Out of the box it manages **pi, codex, and claude**; add
or swap agents via `@agent_agents`.

## Features

- 🔢 **Central picker** (`prefix` + `u`) listing every managed agent tmux session, plus panes where a known agent (pi/codex/claude) was started manually. A tool column shows which agent each row is.
- 🤖 **Multi-agent and multi-instance**: manage pi, codex, and claude side by side; each `prefix` + `y` launch creates a numbered instance such as `pi-1`, `pi-2`, and `pi-3` by default.
- 🟡 **Live status** per session: `blocked` / `working` / `done` / `idle`
  (Herdr-style Pi/Codex/Claude screen detection; no agent extension required).
- 👁️ **Live preview** of each session's screen in the picker.
- 📜 **Unified history**: press `Tab` in the picker to search saved Pi, Codex,
  and Claude conversations, preview recent messages, and resume one in a managed popup.
- 🎯 **Smart jump** back to the window where the session was launched.
- 🚀 **Launcher** (`prefix` + `y`) to open or attach an agent session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) from the picker, plus one-key bulk cleanup
  (`ctrl-r`) of every matched managed session except `working`/`blocked` ones.
- 📊 **Status-line summary**: a compact `agents 1● 2✦ 1✓` fragment counting
  blocked / working / done states from the daemon cache without forking from the
  status line. Place it anywhere in your own status line.
- 🖱️ **Clickable status badges** (requires `set -g mouse on`): left-click the
  `[+]` launch badge to open an agent for the current directory, or left-click
  the agent summary badge to open the picker — the same actions as `prefix` + `y`
  and `prefix` + `u`.

## Prerequisites

- **tmux ≥ 3.3** for borderless `display-popup` (`-B`)
- **fzf ≥ 0.63** for the picker UI and bulk-match `{*f}` actions
- **Pi** CLI (`pi` command) for the default Pi agent (other agents can be configured instead)
- bash and a Rust toolchain; macOS or Linux

For best Pi keyboard behavior inside tmux, Pi recommends:

```tmux
set -g extended-keys on
set -g extended-keys-format csi-u
```

`extended-keys-format csi-u` requires tmux 3.5+. On tmux 3.3–3.4, use only
`set -g extended-keys on`.

## Install

### Manual install

```sh
git clone <this-repo-url> ~/clone/path/tmux-argos
```

Build the bundled state daemon and history reader once:

```sh
cd ~/clone/path/tmux-argos
cargo build --release --manifest-path daemon/Cargo.toml
```

Add to `~/.tmux.conf`, then reload tmux:

```tmux
run-shell ~/clone/path/tmux-argos/tmux-argos.tmux
```

### tpm

After publishing/renaming the repo, use the normal tpm form:

```tmux
set -g @plugin 'yourname/tmux-argos'
```

Then press `prefix` + <kbd>I</kbd> and build the bundled binaries from the
installed plugin directory:

```sh
cd ~/.tmux/plugins/tmux-argos
cargo build --release --manifest-path daemon/Cargo.toml
```

## Usage

| Key            | Action                                                                   |
| -------------- | ------------------------------------------------------------------------ |
| `prefix` + `y` | Launch a numbered agent instance for the current directory; shows an agent menu when more than one is configured |
| `prefix` + `u` | Open the agent session picker                                            |

Inside the picker:

| Key                       | Action                                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `Tab`                     | Toggle between running sessions/panes and saved conversation history       |
| `enter`                   | Open a live target, or resume the selected historical conversation         |
| `ctrl-x`                  | Kill a managed session, or send `Ctrl-C` to a manual agent pane            |
| `ctrl-r`                  | Confirm, then kill all currently matched managed sessions except sessions that are `working` or `blocked` |
| `↑` / `↓`, type to filter | fzf navigation                                                             |

`ctrl-r` operates on the rows currently matched by fzf. Type part of a project,
tool, path, or session display name to narrow the list, then press `ctrl-r` to
kill every matched managed session in one action. With an empty query, every
managed session in the live list is considered, which provides a fast “clear
all” operation.

Before deleting anything, `ctrl-r` temporarily leaves the fzf interface and
asks for confirmation. Type `y` or `Y` to continue; any other input cancels the
operation. The prompt reports how many distinct managed sessions are currently
matched. The current fzf query remains the selection boundary.

Sessions displayed as `working` or `blocked` are protected. After confirmation,
the picker reads a fresh daemon snapshot so time spent at the prompt does not
make the decision depend on stale pre-confirmation state. Any current `working`
or `blocked` record protects the entire session even if another record for that
session is idle. Immediately before each deletion, the picker also reads the
session-scoped tmux mirror. This protects a Pi turn whose mirror has changed to
`working` before its daemon event has arrived. If daemon state is unavailable or
malformed, or any matched picker row does not have the complete expected schema,
the bulk kill aborts without killing anything. `idle`, `done`, and `unknown`
matched sessions are eligible.

Each managed row also carries tmux's immutable `session_id`. Opening, preview,
state protection, deletion, and lifecycle reporting all use that ID rather than
the reusable display name. Tabs, newlines, and carriage returns in display
metadata are replaced before constructing the fixed picker row, so metadata
cannot shift an action onto another ID. If the original session exits while the
picker is open and another client creates a new session with the same name,
actions still
refer only to the original tmux instance. Renaming a session also does not bypass
its current `working`/`blocked` protection.

Manual Agent panes and history rows are ignored because they are not managed
live sessions. Successful kills are reported to the daemon synchronously before
the picker becomes interactive again. The picker then reloads the current mode.

History mode reads the native local stores for Pi (`~/.pi/agent/sessions`),
Codex (`~/.codex/sessions`), and Claude (`~/.claude/projects`). Its preview
shows recent user/assistant messages. Resuming uses `pi --session <file>`,
`codex resume <id>`, or `claude --resume <id>` with the corresponding command
from `@agent_agents`. A selected history record always starts a new numbered
managed tmux session, even when `@agent_multiple_instances` is `off`.

Sessions marked `done` sort near the top so finished work is easy to find.
Manual panes are detected when their current tmux command is one of
`@agent_detect_commands` (default `pi codex claude`), so an agent started by typing
its command in a normal tmux pane is also found with `prefix` + `u`. For wrapped
CLIs such as Node-based launchers, only commands in `@agent_detect_wrappers` are
scanned for child agent processes to keep large tmux workspaces responsive.

## Managing pi, codex, and claude

The plugin manages multiple agents at once. The launchable agents are defined by
the `@agent_agents` registry (one `name=command` per line); the default is:

```tmux
set -g @agent_agents "pi=pi
codex=codex
claude=claude"
```

- `prefix` + `y` shows a compact tmux menu for these agents (pi/codex/claude),
  with entries like `pi (1)`, `codex (2)`, `claude (3)`. Use `Ctrl+n` /
  `Ctrl+p` or the arrow keys to move, number keys to jump, or click an
  entry with the mouse to launch it. With a single agent configured, or
  `@agent_launch_menu off`, it launches directly with no menu.
- Sessions are **namespaced and numbered per agent**
  (`agent-<agent>-<hash>-<instance>`), so the same directory can run pi, codex,
  and claude—or multiple copies of any one of them—without colliding.
- The picker shows a **tool column** with instance labels such as `pi-1` and
  `pi-2`. Set `@agent_multiple_instances off` to restore the legacy behavior:
  one reusable session per directory/agent.
- `@agent_detect_commands` controls which manually-started panes are auto-listed.
- `@agent_detect_wrappers` controls which wrapper commands (default `node bun npx npm pnpm yarn`) are allowed to trigger a child-process scan.

Make sure each agent's command is on your `PATH` (`pi`, `codex`, `claude`).
The daemon detects all three directly from their tmux pane process, terminal
title, and live screen text. Pi does not need a Pi extension or modified launch
command.

## Unified status daemon

A single-thread-owned Rust daemon is the authoritative runtime state center for
each tmux server. It uses a private mode-0600 Unix socket, periodically discovers
Pi/Codex/Claude processes, captures dirty live bottom screens, and applies
Herdr-style state rules keyed by immutable pane and tmux session IDs.

| Observed transition | State |
| --- | --- |
| agent waiting for input | `idle` |
| active turn signal | `working` |
| visible approval or answer prompt | `blocked` |
| `working`/`blocked` becomes idle while not watched | `done` |

Opening a `done` pane sends `Seen`; `done` remains until then. `working` and
`blocked` expire after `@agent_state_ttl`. Picker-initiated exits carry
`session_id`, so a delayed event cannot clear a
same-name replacement. For exits initiated elsewhere, the daemon reconciles
records against the live tmux pane and session IDs on its regular scan; tmux's
`session-closed` hook is not used because it exposes only the reusable name.
`after-kill-pane` is intentionally not used because tmux does not expose the
removed pane identity there. Existing hooks are never overwritten.

### Pi, Codex, and Claude screen detection

The daemon scans tmux pane metadata every `@agent_screen_interval_ms`. A pane is
a candidate when its configured `@agent_tool`, current command, or an allowed
wrapper descendant matches `pi`, `codex`, `claude`, or `claude-code`.

The daemon uses tmux's `#{window_activity}` timestamp to mark candidate panes
dirty and captures only new, recently active, or pending-confirmation panes. A
bounded full scan every `@agent_screen_full_scan_interval_ms` protects against a
missed or coarse timestamp. A control-mode `%output` client is intentionally not
used: control mode only emits pane output for its attached session, so monitoring
all independent agent sessions would require hidden attached clients that alter
`session_attached`, `destroy-unattached`, and pane sizing semantics.

For each dirty candidate pane the daemon reads:

- `#{pane_title}` for OSC title signals.
- `tmux capture-pane -p -J` for the live bottom screen without scrollback.

Following Herdr's Pi screen manifest, the exact visible literal `Working...` is
`working`; otherwise Pi is `idle`. Pi currently has no high-confidence visible
`blocked` rule.

Codex rules mirror Herdr's high-value signals: `Action Required` in the title is
`blocked`, a Braille-spinner title is `working`, approval/answer prompts after
the last `›` prompt are `blocked`, and a non-empty non-spinner title is `idle`.

Claude rules mirror Herdr's screen heuristics: a Braille-spinner title is
`working`, visible permission/menu prompts are `blocked`, a live `❯` prompt box
is `idle`, transcript/model-picker views are ignored, and a `✳` title is `idle`.

Following Herdr, a plain `working` to `idle` transition is confirmed with three
100ms rechecks, bounded to 700ms, so a transient TUI redraw does not publish a
false completion. A high-confidence visible idle signal bypasses the delay.
When Pi/Codex/Claude settles from `working` or `blocked` to `idle`, the daemon
publishes `done` if the pane is not currently visible; opening the pane sends
`Seen` and changes `done` to `idle`.

### Placing the status fragments

The plugin does not modify `status-left` or `status-right`. Instead it publishes
two placeable fragments that you reference wherever you want:

- `@agent_launch_badge` — the `[+]` launch button.
- `@agent_summary_badge` — the live agent summary (blocked / working / done).

Wrap each reference in `#{E:...}`. tmux expands a status format only one level,
and the summary fragment nests the daemon-updated `#{@agent_status_cache}`, so a
plain `#{@agent_summary_badge}` would show the literal inner format instead of
the counts. `#{E:...}` forces the extra expansion pass:

```tmux
set -g status-right '#{E:@agent_launch_badge} #{E:@agent_summary_badge} %H:%M'
```

Each fragment is independent, so you can split them — for example put the launch
button in `status-left` and the summary in `status-right`:

```tmux
set -g status-left  '#{E:@agent_launch_badge} '
set -g status-right '#{E:@agent_summary_badge} %H:%M'
```

#### Complete Solarized/Powerline example

This complete example places the launch, picker, and detach click targets in a
Powerline-style status bar. It assumes the default `agent-` session prefix and
a font that provides the Powerline and Nerd Font glyphs used below:

```tmux
# vim: ft=tmux
set -g mode-style "fg=#eee8d5,bg=#073642"

set -g message-style "fg=#eee8d5,bg=#073642"
set -g message-command-style "fg=#eee8d5,bg=#073642"

set -g pane-border-style "fg=#073642"
set -g pane-active-border-style "fg=#eee8d5"

set -g status "on"
set -g status-interval 1
set -g status-justify "left"

set -g status-style "fg=#586e75,bg=#073642"
set -g status-bg "#292a30"

set -g status-left-length "100"
set -g status-right-length "100"

set -g status-left-style NONE
set -g status-right-style NONE

set -g status-left "#[fg=#073642,bg=#eee8d5,bold] #S:#I.#P #[fg=#eee8d5,bg=#93a1a1,nobold,nounderscore,noitalics]#[fg=#15161E,bg=#93a1a1,bold] #(whoami) #[fg=#93a1a1,bg=#292a30]"
set -g status-right "#[fg=#586e75,bg=#292a30,nobold,nounderscore,noitalics]#[fg=#93a1a1,bg=#586e75]#[fg=#657b83,bg=#586e75,nobold,nounderscore,noitalics]#[fg=#93a1a1,bg=#657b83]#[fg=#93a1a1,bg=#657b83,nobold,nounderscore,noitalics]#[fg=#15161E,bg=#93a1a1,bold]#{?#{m:agent-*,#{session_name}},,#[range=user|agent_launch]  #[norange]丨} #[range=user|agent_list]#{?@agent_status_cache,#{@agent_status_cache},#h}#[norange] #{?#{m:agent-*,#{session_name}},丨#[range=user|agent_detach]   #[norange],}"

setw -g window-status-activity-style "underscore,fg=#839496,bg=#292a30"
setw -g window-status-separator ""
setw -g window-status-style "NONE,fg=#839496,bg=#292a30"
setw -g window-status-format '#[fg=#292a30,bg=#292a30]#[default] #I  #{b:pane_current_path} #[fg=#292a30,bg=#292a30,nobold,nounderscore,noitalics]'
setw -g window-status-current-format '#[fg=#292a30,bg=#eee8d5]#[fg=#b58900,bg=#eee8d5] #I #[fg=#eee8d5,bg=#b58900] #{b:pane_current_path} #[fg=#b58900,bg=#292a30,nobold]'
```

### Zero-fork animated status line

The status line expands only `#{@agent_status_cache}` and forks no process.
While `working > 0`, the daemon advances and publishes animation frames (default
one second). At `working = 0` it stops animation and resets the frame index.
The daemon publishes only when the final rendered summary changes. A publish
uses one tmux option update plus explicit refreshes for cached client names; the
status format itself remains zero-fork. Cache publication and redraw are
separate: a successful option update remains valid if an explicit client
refresh fails.

Animation frames are whitespace-separated; a frame itself cannot contain a
space. The daemon validates non-empty bounded frames, minimum 250ms animation
and screen-detection intervals, requires the full-scan interval to be at least
the regular screen interval, and accepts a non-negative TTL. Invalid reload
retains the old config; successful reload immediately reconciles state.

### Clickable status badges

With `@agent_status_mouse on` (the default) and tmux `set -g mouse on`, each
published fragment carries its own user-defined mouse range. The
`@agent_status_launch_label` badge (default `[+]`) is a stable click target even
when no agents are running; the agent summary range has zero width while the
cache is empty. Left-clicking the launch badge runs the launcher for the active
pane's directory (same as `prefix` + `y`), and left-clicking the summary badge
opens the picker (same as `prefix` + `u`).

The `@agent_detach_badge` fragment (default label `[x]` from
`@agent_status_detach_label`) is a click-to-close affordance for the agent
popup. It only renders while the drawing client is inside a managed agent
session (its name matches `@agent_session_prefix`), so it stays invisible on
ordinary panes. Left-clicking it detaches only the clicked client, closing the
popup while the agent session keeps running in the background (same effect as
`prefix` + `d`). Place it in the status line of managed sessions, for example
`set -g status-right '#{E:@agent_detach_badge} #{E:@agent_launch_badge} #{E:@agent_summary_badge}'`.

The plugin binds `MouseDown1Status` and dispatches only its own ranges; clicks
elsewhere on the status line fall back to tmux's default `switch-client`. The
range markers add no `#()` expansion, so referencing the fragments stays
zero-fork. Set `@agent_status_mouse off` to publish the fragments without the
clickable ranges. Setting `@agent_status off` and reloading the plugin clears all
previously published badge fragments and the cached summary.

## Options

Launcher and picker options:

```tmux
set -g @agent_launch_key     'y'
set -g @agent_list_key       'u'
set -g @agent_default_command 'pi'
set -g @agent_agents         '...'
set -g @agent_launch_menu    'on'
set -g @agent_multiple_instances 'on'
set -g @agent_detect_commands 'pi codex claude'
set -g @agent_detect_wrappers 'node bun npx npm pnpm yarn'
set -g @agent_session_prefix 'agent-'
set -g @agent_popup_width    '90%'
set -g @agent_popup_height   '90%'
set -g @agent_history_pi_dir     '~/.pi/agent/sessions'
set -g @agent_history_codex_dir  '~/.codex'
set -g @agent_history_claude_dir '~/.claude'
set -g @agent_history_binary '/path/to/daemon/target/release/tmux-argos-history'
```

The history directory options are useful when an agent's local data home is
customized. The plugin expands a leading `~/`. `@agent_history_binary` defaults
to the history reader built next to the state daemon.

Daemon/status options:

```tmux
set -g @agent_status                 'on'
set -g @agent_status_mouse           'on'
set -g @agent_status_launch_label    '[+]'
set -g @agent_status_detach_label    '[x]'
set -g @agent_status_animate_working 'on'
set -g @agent_status_show_idle       'off'
set -g @agent_status_sigil           'agents'
set -g @agent_status_icon_blocked    '●'
set -g @agent_status_icon_working    '✦'
set -g @agent_status_icon_done       '✓'
set -g @agent_status_icon_idle       '·'
set -g @agent_status_anim_frames     '✦ ✷ ✹ ✴'
set -g @agent_animation_interval_ms  '1000'
set -g @agent_screen_interval_ms           '1000'
set -g @agent_screen_full_scan_interval_ms '30000'
set -g @agent_state_ttl                    '259200'
set -g @agent_daemon_binary '/path/to/daemon/target/release/tmux-argos-state-daemon'
```

The plugin sets `@agent_daemon_binary` to its release build by default. It does
not install a toolchain or build code during tmux startup. Plugin reload sends
`ReloadConfig`; explicit inspection/reload is also available:

```sh
scripts/daemon.sh snapshot
scripts/daemon.sh reload
```

After rebuilding the daemon binary while the same tmux server is still running,
restart that daemon process, then reload the plugin entrypoint:

```sh
scripts/daemon.sh shutdown
tmux run-shell /path/to/tmux-argos/tmux-argos.tmux
```

## How it works

- The **launcher** picks an agent from `@agent_agents` (or launches the default),
  creates a detached `agent-<agent>-<hash-of-dir>-<instance>` tmux session running
  that agent, records the origin window, agent, and instance, then attaches to it
  in a popup. With `@agent_multiple_instances off`, it instead opens or reuses the
  unnumbered session.
- The **daemon** discovers Pi, Codex, and Claude panes and derives their state from the live bottom screen without agent extensions.
- The **picker** lists tmux sessions matching the prefix and non-prefixed panes
  whose current command is in `@agent_detect_commands` (or a configured wrapper
  whose child process matches), reads state for managed sessions, shows a live
  `capture-pane` preview and a per-row tool column, and jumps to the selected
  session or pane. Pressing `Tab` reloads it with records parsed by the bundled
  `tmux-argos-history` binary; history previews are plain conversation text and
  Enter launches the agent's native resume command. This is where process and
  history discovery happen.
- The **daemon** owns live state, agent screen polling, TTL and animation, and publishes a cache-only zero-fork status segment.
- Pressing `prefix` + `u` from inside an agent popup first detaches that popup,
  then reopens the picker on the outer tmux client.

## Naming

Configuration uses the `@agent_*` option namespace (for example
`@agent_state`). Old Pi-prefixed option names are not read or written.

## Acknowledgements

This project was originally forked from
[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager.git).
Many thanks to [Takuya Matsuyama (craftzdog)](https://github.com/craftzdog) for creating and open-sourcing the original project.

## Development

Tests are treated as executable falsifiers: a failure rejects the current code
hypothesis, while a pass means only that no covered counterexample was found.
Run the complete fast constitutional gate with:

```sh
bash tests/verify.sh
```

The executable evidence is divided by the kind of claim it tries to refute:

- **Known requirements:** Rust/Bash behavior tests plus Gherkin scenarios in
  `spec/features/`. `tests/gherkin_contract.py` requires every scenario to map
  to an executable acceptance test.
- **Unknown counterexamples:** generated identifier properties cover 10,000
  cases and deterministic protocol fuzzing mutates 100,000 payloads.
- **Tests of the tests:** `tests/meta.sh` seeds gate and policy faults;
  `tests/suite_contract.py` rejects disconnected or relaxed gates;
  `tests/bash_mutation.sh` requires Bash tests to kill the reviewed fault corpus,
  while `tests/mutation.sh` requires every viable critical Rust mutant to be killed.
  Behavior tests may be refactored or renamed as long as these capabilities remain.
- **Composition and environment:** `tests/system.sh` exercises a real isolated
  tmux server, 100 concurrent clients, 20 daemon restart cycles, and 16/32MiB
  idle/pressure RSS budgets on Linux and macOS.
- **Regression:** named regression tests preserve every security and lifecycle
  counterexample already found; screen heuristics use stable fixture strings.

The fast gate is deliberately strict: files are limited to 400 lines, functions
to 60 lines, cyclomatic complexity to 10, Rust cognitive complexity to 15, and
8-line duplicate windows to 1%. ShellCheck and Clippy allow zero warnings. The
whole fast feedback loop must complete within 30 seconds.

Additional gates are run separately and by CI:

```sh
bash tests/perf_smoke.sh  # 100+100 item p95 <=200ms; growth <=2.5x
bash tests/system.sh      # real tmux E2E, concurrency, memory, chaos
bash tests/mutation.sh      # requires cargo-mutants 27.1.0
bash tests/bash_mutation.sh # reviewed Bash/tmux fault corpus
bash tests/security.sh      # requires cargo-audit 0.22.2
bash tests/flaky.sh       # twenty consecutive Rust and Bash runs
```

Performance thresholds and repetition counts are part of the human-owned
constitution and cannot be disabled or raised through environment variables.

### Human-owned executable specification

The constitutional boundary protects the capability layer rather than every test
implementation: mutation corpora, gate contracts and thresholds, `spec/**`, CI,
`CODEOWNERS`, fixtures, `AGENTS.md`, and the Pi protection extension. Ordinary
Bash/Rust behavior tests may be refactored, split, or renamed without approval,
but CI requires them to keep killing the same reviewed Bash and Rust faults.

`.pi/extensions/test-constitution.ts` intercepts mutations to the protected
capability files and common shell mutation paths, then shows a default-reject
choice between rejecting the operation and allowing that single mutation.
Cancellation or a run mode without interactive UI blocks the operation. Approval
is never remembered. This local hook is defense in depth, not a security boundary:
enable GitHub branch protection, require every CI gate, and require CODEOWNER
review for the final external decision. A human must approve changes to the
capability contract or intended behavior, but not behavior-preserving test refactors.




/// Latest top-level OSC 7501 report relayed from one pane. `Clear` is never
/// stored: it withdraws the report so the pane falls back to screen detection.
#[derive(Clone, Debug, PartialEq, Eq)]
struct PaneProgramStatus {
    app: Option<String>,
    state: ProgramState,
    kind: Option<BlockedKind>,
    /// `done`/`error` mark one finished turn. The report stays stored after it
    /// is applied, so the completion must be consumed exactly once; otherwise a
    /// later scan would re-flag an already seen turn as unseen.
    completion_pending: bool,
}

/// Only tools that emit OSC 7501 inside tmux receive a relay. Pi reports when
/// `PI_PROGRAM_STATUS=1`; Claude Code reports only after a support-query reply
/// that tmux cannot deliver before its own device-attributes answer, and Codex
/// does not implement the protocol. Relaying them would occupy the pane's
/// single pipe-pane slot for nothing.
fn tool_emits_program_status_in_tmux(tool: &str) -> bool {
    tool == "pi"
}

/// A report without `app` belongs to whatever the pane runs; a named report must
/// come from the tool resolved for that pane, so a nested program cannot
/// impersonate the agent.
fn program_app_matches_tool(app: Option<&str>, tool: &str) -> bool {
    match app {
        None => true,
        Some(name) => canonical_screen_tool(name).as_deref() == Some(tool),
    }
}

/// Unlike screen heuristics, the program says when a turn finished. `done` and
/// `error` therefore mark an unseen completion even when no scan observed the
/// preceding `working` report, while `idle` (start-up or a cancelled run) never
/// does. An existing `done` persists until the pane is seen.
fn program_display_state(
    state: ProgramState,
    completion: bool,
    previous_state: Option<AgentState>,
    pane_visible: bool,
) -> AgentState {
    match state {
        ProgramState::Working => return AgentState::Working,
        ProgramState::Blocked => return AgentState::Blocked,
        _ => {}
    }
    if previous_state == Some(AgentState::Done) {
        return AgentState::Done;
    }
    if completion && !pane_visible {
        return AgentState::Done;
    }
    AgentState::Idle
}

/// Builds one tmux invocation that attaches the relay to every listed pane.
/// `if-shell -F` re-checks `pane_pipe` inside tmux's command queue, so a pipe
/// opened after the pane listing is never replaced. The relay executes the
/// plugin-published `@agent_daemon_binary`, expanded with `#{q:}`, so no path
/// byte is parsed by tmux or the shell and an in-place rebuild keeps working.
fn program_status_relay_arguments(server_socket: &str, pane_ids: &[&str]) -> Vec<String> {
    let mut arguments: Vec<String> = vec!["-S".into(), server_socket.into()];
    for (index, pane_id) in pane_ids.iter().enumerate() {
        if index > 0 {
            arguments.push(";".into());
        }
        let relay_command = format!(
            "pipe-pane -O -t {pane_id} \"TMUX=#{{q:socket_path}},#{{pid}},0 exec \
             #{{q:@agent_daemon_binary}} program-status-relay #{{pane_id}}\""
        );
        arguments.extend([
            "if-shell".into(),
            "-F".into(),
            "-t".into(),
            (*pane_id).into(),
            "#{?pane_pipe,,1}".into(),
            relay_command,
        ]);
    }
    arguments
}

/// A relay that cannot exec closes its pipe at once, so attaching it anyway
/// would fork tmux and a shell for every Pi pane on every scan.
fn validate_relay_binary(daemon_binary: Option<&Path>) -> Result<(), String> {
    let path = daemon_binary.ok_or("program status relay requires @agent_daemon_binary")?;
    let metadata = fs::metadata(path).map_err(|error| {
        format!("program status relay binary {} is unavailable: {error}", path.display())
    })?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(format!(
            "program status relay binary {} is not an executable file",
            path.display()
        ));
    }
    Ok(())
}

fn run_relay_attachment(arguments: &[String]) -> Result<(), String> {
    let output = Command::new("tmux")
        .args(arguments)
        .output()
        .map_err(|error| format!("program status relay attachment failed to run tmux: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "program status relay attachment failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

impl StateCenter {
    fn apply_program_status(
        &mut self,
        pane_id: String,
        app: Option<String>,
        state: ProgramState,
        kind: Option<BlockedKind>,
        now: Instant,
    ) {
        if !self.config.program_status_enabled {
            return;
        }
        if state == ProgramState::Clear {
            self.program_statuses.remove(&pane_id);
        } else {
            let status = PaneProgramStatus {
                app,
                state,
                kind,
                completion_pending: matches!(state, ProgramState::Done | ProgramState::Error),
            };
            self.program_statuses.insert(pane_id, status);
        }
        // Publish the structured change on the next reconciliation instead of
        // waiting for the regular screen interval.
        self.screen_deadline = Some(now);
    }

    fn has_program_status(&self, pane_id: &str, tool: &str) -> bool {
        self.config.program_status_enabled
            && self
                .program_statuses
                .get(pane_id)
                .is_some_and(|status| program_app_matches_tool(status.app.as_deref(), tool))
    }

    /// A report is valid only while its agent still runs in the pane and the
    /// relay that produced it is still piped. tmux clears `pane_pipe` when the
    /// relay dies, so a crashed relay or agent falls back to screen detection
    /// instead of freezing the last structured state.
    fn prune_program_statuses(&mut self, resolved: &[(PaneRow, String)]) {
        let reporting_panes: HashSet<&str> = resolved
            .iter()
            .filter(|(row, _)| row.pipe_open)
            .map(|(row, _)| row.pane_id.as_str())
            .collect();
        self.program_statuses
            .retain(|pane_id, _| reporting_panes.contains(pane_id.as_str()));
    }

    fn attach_program_status_relays(&mut self, resolved: &[(PaneRow, String)]) {
        if !self.config.program_status_enabled {
            return;
        }
        let pane_ids: Vec<&str> = resolved
            .iter()
            .filter(|(row, tool)| !row.pipe_open && tool_emits_program_status_in_tmux(tool))
            .map(|(row, _)| row.pane_id.as_str())
            .collect();
        if pane_ids.is_empty() {
            return;
        }
        let result = validate_relay_binary(self.config.daemon_binary.as_deref()).and_then(|()| {
            run_relay_attachment(&program_status_relay_arguments(&self.server_socket, &pane_ids))
        });
        self.record_relay_attach_result(result);
    }

    /// Screen detection keeps working while relays are unavailable, so the
    /// failure is reported once per distinct cause instead of on every scan.
    fn record_relay_attach_result(&mut self, result: Result<(), String>) {
        match result {
            Ok(()) => self.relay_attach_error = None,
            Err(error) => {
                if self.relay_attach_error.as_ref() != Some(&error) {
                    eprintln!("tmux-argos-state-daemon: {error}");
                }
                self.relay_attach_error = Some(error);
            }
        }
    }

    fn apply_program_detection(&mut self, row: PaneRow, tool: String) {
        let key = screen_key(&tool, &row.pane_id);
        let Some(status) = self.program_statuses.get_mut(&row.pane_id) else {
            return;
        };
        let completion = std::mem::take(&mut status.completion_pending);
        let program_state = status.state;
        let blocked_kind = status.kind;
        // Structured reports need no redraw confirmation.
        self.pending_idle_confirmations.remove(&key);
        let previous_state = self.agents.get(&key).map(|record| record.state);
        let state = program_display_state(program_state, completion, previous_state, row.visible);
        self.insert_pane_record(key, row, tool, state, blocked_kind);
    }
}

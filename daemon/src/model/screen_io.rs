fn should_capture_screen(
    has_previous_record: bool,
    has_pending_idle_confirmation: bool,
    full_scan: bool,
    window_activity: u64,
    previous_window_activity: Option<u64>,
    wall_clock_seconds: u64,
    activity_recency_grace: Duration,
) -> bool {
    if !has_previous_record || has_pending_idle_confirmation || full_scan {
        return true;
    }
    if window_activity == 0 || previous_window_activity != Some(window_activity) {
        return true;
    }
    wall_clock_seconds.saturating_sub(window_activity) <= activity_recency_grace.as_secs()
}

fn word_set(value: &str) -> HashSet<String> {
    value
        .split_whitespace()
        .filter(|word| !word.is_empty())
        .map(str::to_string)
        .collect()
}

fn decode_tmux_value(value: &str) -> String {
    if value == "''" {
        return String::new();
    }
    if value.starts_with('"') && value.ends_with('"') {
        if let Ok(decoded) = serde_json::from_str::<String>(value) {
            return decoded;
        }
        return value[1..value.len() - 1].to_string();
    }
    value.to_string()
}

fn event_key(tool: &str, pane: &str, generation: &str) -> String {
    format!("event:{tool}:{pane}:{generation}")
}

fn screen_key(tool: &str, pane: &str) -> String {
    format!("screen:{tool}:{pane}")
}

fn parse_state(value: &str) -> Option<AgentState> {
    match value {
        "blocked" => Some(AgentState::Blocked),
        "working" => Some(AgentState::Working),
        "done" => Some(AgentState::Done),
        "idle" => Some(AgentState::Idle),
        _ => None,
    }
}

fn state_label(state: AgentState) -> &'static str {
    match state {
        AgentState::Blocked => "blocked",
        AgentState::Working => "working",
        AgentState::Done => "done",
        AgentState::Idle => "idle",
    }
}

fn is_screen_detected_tool(tool: &str) -> bool {
    matches!(tool, "pi" | "claude" | "codex")
}

fn canonical_screen_tool(tool: &str) -> Option<String> {
    match tool {
        "pi" => Some("pi".to_string()),
        "claude" | "claude-code" | "claude.exe" => Some("claude".to_string()),
        "codex" => Some("codex".to_string()),
        _ => None,
    }
}

fn tmux_output(server_socket: &str, args: &[&str]) -> Option<String> {
    Command::new("tmux")
        .args(["-S", server_socket])
        .args(args)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn list_pane_rows(server_socket: &str) -> Option<Vec<PaneRow>> {
    let format = "#{session_name}\t#{session_id}\t#{window_id}\t#{window_activity}\t#{pane_id}\t#{pane_current_command}\t#{pane_pid}\t#{pane_title}\t#{@agent_tool}\t#{session_attached}\t#{window_active}\t#{pane_active}";
    let output = tmux_output(server_socket, &["list-panes", "-a", "-F", format])?;
    Some(
        output
            .lines()
            .filter_map(|line| {
                let mut fields = line.split('\t');
                let session_name = fields.next()?.to_string();
                let session_id = fields.next()?.to_string();
                let window_id = fields.next()?.to_string();
                let window_activity = fields.next()?.parse::<u64>().unwrap_or(0);
                let pane_id = fields.next()?.to_string();
                let command = fields.next()?.to_string();
                let pane_pid = fields.next()?.parse::<u32>().ok()?;
                let pane_title = fields.next().unwrap_or("").to_string();
                let configured_tool = fields.next().unwrap_or("").to_string();
                let session_attached = fields.next().unwrap_or("0");
                let window_active = fields.next().unwrap_or("0");
                let pane_active = fields.next().unwrap_or("0");
                let visible = session_attached != "0" && window_active == "1" && pane_active == "1";
                Some(PaneRow {
                    session_name,
                    session_id,
                    window_id,
                    window_activity,
                    pane_id,
                    command,
                    pane_pid,
                    pane_title,
                    configured_tool,
                    visible,
                })
            })
            .collect(),
    )
}

fn capture_pane(server_socket: &str, pane_id: &str) -> Option<String> {
    // Detection must inspect the live bottom screen, not stale status text in
    // scrollback from an already completed turn.
    tmux_output(server_socket, &["capture-pane", "-p", "-J", "-t", pane_id])
}

/// Captures every listed pane in a single tmux invocation by chaining
/// `capture-pane ; display-message` per pane and splitting on the marker.
/// tmux aborts the whole chain if any one target no longer exists (e.g. a
/// pane closed between listing and capture), so callers must treat `None`
/// as "fall back to capturing panes one at a time" rather than as data loss.
fn capture_panes_batch(
    server_socket: &str,
    marker: &str,
    pane_ids: &[&str],
) -> Option<HashMap<String, String>> {
    if pane_ids.is_empty() {
        return Some(HashMap::new());
    }
    let mut args: Vec<String> = vec!["-S".into(), server_socket.into()];
    for (index, pane_id) in pane_ids.iter().enumerate() {
        if index > 0 {
            args.push(";".into());
        }
        args.extend([
            "capture-pane".into(),
            "-p".into(),
            "-J".into(),
            "-t".into(),
            (*pane_id).into(),
            ";".into(),
            "display-message".into(),
            "-p".into(),
            marker.into(),
        ]);
    }
    let output = Command::new("tmux").args(&args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    let delimiter = format!("{marker}\n");
    let mut map = HashMap::with_capacity(pane_ids.len());
    let mut rest = text.as_str();
    for pane_id in pane_ids {
        let pos = rest.find(&delimiter)?;
        map.insert((*pane_id).to_string(), rest[..pos].to_string());
        rest = &rest[pos + delimiter.len()..];
    }
    Some(map)
}

fn process_table_snapshot() -> Option<String> {
    Command::new("ps")
        .args(["-axo", "pid=,ppid=,comm="])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn resolve_child_screen_tool(
    root_pid: u32,
    table: &str,
    detect_commands: &HashSet<String>,
) -> Option<String> {
    let mut commands = HashMap::<u32, String>::new();
    let mut children = HashMap::<u32, Vec<u32>>::new();
    for line in table.lines() {
        let mut fields = line.split_whitespace();
        let Some(pid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let Some(ppid) = fields.next().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let Some(command) = fields.next() else {
            continue;
        };
        commands.insert(pid, basename(command).to_string());
        children.entry(ppid).or_default().push(pid);
    }

    let mut queue = VecDeque::from([root_pid]);
    let mut seen = HashSet::from([root_pid]);
    while let Some(pid) = queue.pop_front() {
        if let Some(command) = commands.get(&pid) {
            if detect_commands.contains(command) {
                if let Some(tool) = canonical_screen_tool(command) {
                    return Some(tool);
                }
            }
        }
        for child in children.get(&pid).into_iter().flatten() {
            if seen.insert(*child) {
                queue.push_back(*child);
            }
        }
    }
    None
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

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

const PANE_FIELD_SEPARATOR: char = '\u{1f}';
const PANE_RECORD_SEPARATOR: char = '\u{1e}';

fn valid_tmux_id(value: &str, prefix: char) -> bool {
    value
        .strip_prefix(prefix)
        .is_some_and(|digits| !digits.is_empty() && digits.chars().all(|value| value.is_ascii_digit()))
}

fn parse_pane_flag(value: &str) -> Option<bool> {
    match value {
        "0" => Some(false),
        "1" => Some(true),
        _ => None,
    }
}

fn parse_pane_record(record: &str) -> Option<PaneRow> {
    let record = record.strip_prefix('\n').unwrap_or(record);
    let record = record.strip_prefix('\r').unwrap_or(record);
    let fields: Vec<&str> = record.split(PANE_FIELD_SEPARATOR).collect();
    if fields.len() != 16 {
        return None;
    }
    if fields[0].is_empty()
        || !valid_tmux_id(fields[1], '$')
        || !valid_tmux_id(fields[3], '@')
        || !valid_tmux_id(fields[8], '%')
    {
        return None;
    }
    let session_attached = fields[2].parse::<u32>().ok()? > 0;
    let window_active = parse_pane_flag(fields[7])?;
    let pane_active = parse_pane_flag(fields[15])?;
    Some(PaneRow {
        session_name: fields[0].into(),
        session_id: fields[1].into(),
        session_attached,
        window_id: fields[3].into(),
        window_index: fields[4].parse().ok()?,
        window_name: fields[5].into(),
        window_activity: fields[6].parse().ok()?,
        window_active,
        pane_id: fields[8].into(),
        pane_index: fields[9].parse().ok()?,
        command: fields[10].into(),
        current_path: fields[11].into(),
        pane_pid: fields[12].parse().ok()?,
        pane_title: fields[13].into(),
        configured_tool: fields[14].into(),
        pane_active,
        visible: session_attached && window_active && pane_active,
    })
}

fn list_pane_rows(server_socket: &str) -> Option<Vec<PaneRow>> {
    let format = concat!(
        "#{s|\x1f| |;s|\x1e| |:session_name}\x1f#{session_id}\x1f",
        "#{session_attached}\x1f#{window_id}\x1f#{window_index}\x1f",
        "#{s|\x1f| |;s|\x1e| |:window_name}\x1f#{window_activity}\x1f",
        "#{window_active}\x1f#{pane_id}\x1f#{pane_index}\x1f",
        "#{s|\x1f| |;s|\x1e| |:pane_current_command}\x1f",
        "#{s|\x1f| |;s|\x1e| |:pane_current_path}\x1f#{pane_pid}\x1f",
        "#{s|\x1f| |;s|\x1e| |:pane_title}\x1f",
        "#{s|\x1f| |;s|\x1e| |:@agent_tool}\x1f#{pane_active}\x1e"
    );
    let output = tmux_output(server_socket, &["list-panes", "-a", "-F", format])?;
    Some(
        output
            .split(PANE_RECORD_SEPARATOR)
            .filter_map(parse_pane_record)
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

use crate::protocol::{AgentState, Request};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_FRAMES: usize = 64;
const MAX_FRAME_BYTES: usize = 64;
const RETIRED_GENERATION_TTL: Duration = Duration::from_secs(300);
const MAX_RETIRED_GENERATIONS: usize = 4096;
const PENDING_IDLE_RECHECK: Duration = Duration::from_millis(100);
const PENDING_IDLE_CAP: Duration = Duration::from_millis(700);
const PENDING_IDLE_CONFIRMATIONS: u8 = 3;

#[derive(Clone, Debug)]
pub struct Config {
    pub prefix: String,
    pub status_enabled: bool,
    pub animate_working: bool,
    pub sigil: String,
    pub icon_blocked: String,
    pub icon_working: String,
    pub icon_done: String,
    pub icon_idle: String,
    pub show_idle: bool,
    pub frames: Vec<String>,
    pub animation_interval: Duration,
    pub screen_interval: Duration,
    pub screen_full_scan_interval: Duration,
    pub state_ttl: Duration,
    pub detect_commands: HashSet<String>,
    pub wrapper_commands: HashSet<String>,
}

impl Config {
    pub fn load(server_socket: &str) -> Result<Self, String> {
        let output = tmux_output(server_socket, &["show-options", "-g"])
            .ok_or("failed to read tmux global options")?;
        let mut values = HashMap::new();
        for line in output.lines() {
            if let Some((name, value)) = line.split_once(' ') {
                values.insert(name.to_string(), decode_tmux_value(value));
            }
        }
        Self::from_values(&values)
    }

    fn from_values(values: &HashMap<String, String>) -> Result<Self, String> {
        let get = |name: &str, default: &str| {
            values
                .get(name)
                .filter(|value| !value.is_empty())
                .map(String::as_str)
                .unwrap_or(default)
                .to_string()
        };
        let parse_u64 = |name: &str, default: u64, label: &str| -> Result<u64, String> {
            let raw = values.get(name).map(String::as_str).unwrap_or("");
            if raw.is_empty() {
                return Ok(default);
            }
            raw.parse::<u64>()
                .map_err(|_| format!("{label} must be an integer"))
        };

        let working_icon = get("@agent_status_icon_working", "✦");
        let default_frames = format!("{working_icon} ✷ ✹ ✴");
        let frame_text = get("@agent_status_anim_frames", &default_frames);
        let frames: Vec<String> = frame_text.split_whitespace().map(str::to_string).collect();
        if frames.is_empty()
            || frames.len() > MAX_FRAMES
            || frames.iter().any(|value| value.len() > MAX_FRAME_BYTES)
        {
            return Err("animation frames must contain 1..64 frames of at most 64 bytes".into());
        }

        let animation_ms = parse_u64("@agent_animation_interval_ms", 1000, "animation interval")?;
        if animation_ms < 250 {
            return Err("animation interval must be at least 250ms".into());
        }
        let screen_ms = parse_u64(
            "@agent_screen_interval_ms",
            1000,
            "screen detection interval",
        )?;
        if screen_ms < 250 {
            return Err("screen detection interval must be at least 250ms".into());
        }
        let full_scan_ms = parse_u64(
            "@agent_screen_full_scan_interval_ms",
            30000,
            "screen full scan interval",
        )?;
        if full_scan_ms < screen_ms {
            return Err(
                "screen full scan interval must not be shorter than the screen detection interval"
                    .into(),
            );
        }
        let ttl = parse_u64("@agent_state_ttl", 259200, "state TTL")?;

        Ok(Self {
            prefix: get("@agent_session_prefix", "agent-"),
            status_enabled: get("@agent_status", "on") == "on",
            animate_working: get("@agent_status_animate_working", "on") == "on",
            sigil: get("@agent_status_sigil", "agents"),
            icon_blocked: get("@agent_status_icon_blocked", "●"),
            icon_working: working_icon,
            icon_done: get("@agent_status_icon_done", "✓"),
            icon_idle: get("@agent_status_icon_idle", "·"),
            show_idle: get("@agent_status_show_idle", "off") == "on",
            frames,
            animation_interval: Duration::from_millis(animation_ms),
            screen_interval: Duration::from_millis(screen_ms),
            screen_full_scan_interval: Duration::from_millis(full_scan_ms),
            state_ttl: Duration::from_secs(ttl),
            detect_commands: word_set(&get("@agent_detect_commands", "pi codex claude")),
            wrapper_commands: word_set(&get(
                "@agent_detect_wrappers",
                "node bun npx npm pnpm yarn",
            )),
        })
    }

    #[cfg(test)]
    fn test() -> Self {
        Self {
            prefix: "agent-".into(),
            status_enabled: true,
            animate_working: true,
            sigil: "agents".into(),
            icon_blocked: "●".into(),
            icon_working: "✦".into(),
            icon_done: "✓".into(),
            icon_idle: "·".into(),
            show_idle: false,
            frames: vec!["a".into(), "b".into()],
            animation_interval: Duration::from_secs(1),
            screen_interval: Duration::from_secs(1),
            screen_full_scan_interval: Duration::from_secs(30),
            state_ttl: Duration::from_secs(60),
            detect_commands: word_set("pi codex claude"),
            wrapper_commands: word_set("node bun npx npm pnpm yarn"),
        }
    }
}

#[derive(Clone, Debug)]
struct AgentRecord {
    source: Source,
    tool: String,
    pane_id: Option<String>,
    session_id: String,
    session_name: String,
    process_generation: Option<String>,
    sequence: u64,
    state: AgentState,
    changed_at: SystemTime,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Source {
    Event,
    Screen,
}

#[derive(Clone, Debug)]
struct PaneRow {
    session_name: String,
    session_id: String,
    window_id: String,
    window_activity: u64,
    pane_id: String,
    command: String,
    pane_pid: u32,
    pane_title: String,
    configured_tool: String,
    // Captured in the same list-panes call so screen_display_state can decide a
    // finished turn is "done" vs "seen idle" without a per-pane display-message
    // fork on every screen scan.
    visible: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ScreenDetection {
    state: AgentState,
    skip_state_update: bool,
    visible_idle: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct PendingIdleConfirmation {
    started_at: Option<Instant>,
    confirmations: u8,
}

impl PendingIdleConfirmation {
    fn should_hold(
        &mut self,
        previous_state: AgentState,
        detection: ScreenDetection,
        now: Instant,
    ) -> bool {
        let plain_working_to_idle = previous_state == AgentState::Working
            && detection.state == AgentState::Idle
            && !detection.visible_idle;
        if !plain_working_to_idle {
            *self = Self::default();
            return false;
        }

        let Some(started_at) = self.started_at else {
            self.started_at = Some(now);
            self.confirmations = 0;
            return true;
        };
        if now.saturating_duration_since(started_at) >= PENDING_IDLE_CAP {
            *self = Self::default();
            return false;
        }

        self.confirmations = self.confirmations.saturating_add(1);
        if self.confirmations >= PENDING_IDLE_CONFIRMATIONS {
            *self = Self::default();
            return false;
        }
        true
    }
}

pub struct StateCenter {
    pub server_socket: String,
    config: Config,
    agents: HashMap<String, AgentRecord>,
    retired_event_generations: HashMap<String, Instant>,
    frame_index: usize,
    animation_deadline: Option<Instant>,
    expiry_deadline: Option<Instant>,
    screen_deadline: Option<Instant>,
    full_screen_scan_deadline: Instant,
    last_window_activity: HashMap<String, u64>,
    pending_idle_confirmations: HashMap<String, PendingIdleConfirmation>,
    published_summary: Option<String>,
    capture_marker: String,
}

impl StateCenter {
    pub fn new(server_socket: String, config: Config) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        Self {
            server_socket,
            config,
            agents: HashMap::new(),
            retired_event_generations: HashMap::new(),
            frame_index: 0,
            animation_deadline: None,
            expiry_deadline: None,
            screen_deadline: Some(Instant::now()),
            full_screen_scan_deadline: Instant::now(),
            last_window_activity: HashMap::new(),
            pending_idle_confirmations: HashMap::new(),
            published_summary: None,
            capture_marker: format!("--tmux-argos-daemon-split-{nanos:016x}--"),
        }
    }

    pub fn restore_once(&mut self) {
        let format = "#{session_name}\t#{session_id}\t#{pane_id}\t#{@agent_tool}\t#{@agent_state}\t#{@agent_state_at}\t#{@agent_process_generation}\t#{@agent_sequence}";
        let Some(output) = tmux_output(&self.server_socket, &["list-sessions", "-F", format])
        else {
            return;
        };
        for line in output.lines() {
            self.restore_mirror_row(line, true);
        }
        if let Some(panes) = tmux_output(&self.server_socket, &["list-panes", "-a", "-F", format]) {
            for line in panes.lines() {
                self.restore_mirror_row(line, false);
            }
        }
    }

    fn restore_mirror_row(&mut self, line: &str, managed_only: bool) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 8 {
            return;
        }
        let managed = fields[0].starts_with(&self.config.prefix);
        if managed_only != managed || fields[1].is_empty() || fields[3].is_empty() {
            return;
        }
        if is_screen_detected_tool(fields[3]) {
            return;
        }
        let Some(state) = parse_state(fields[4]) else {
            return;
        };
        let changed_at = fields[5]
            .parse::<u64>()
            .ok()
            .map(|seconds| UNIX_EPOCH + Duration::from_secs(seconds))
            .unwrap_or_else(SystemTime::now);
        let generation = if fields[6].is_empty() {
            format!("restore:{}", fields[2])
        } else {
            fields[6].to_string()
        };
        let sequence = fields[7].parse().unwrap_or(0);
        let key = event_key(fields[3], fields[2], &generation);
        self.agents.insert(
            key,
            AgentRecord {
                source: Source::Event,
                tool: fields[3].into(),
                pane_id: Some(fields[2].into()),
                session_id: fields[1].into(),
                session_name: fields[0].into(),
                process_generation: Some(generation),
                sequence,
                state,
                changed_at,
            },
        );
    }

    pub fn replace_config(&mut self, config: Config) {
        self.config = config;
        self.frame_index = 0;
        self.animation_deadline = None;
        self.screen_deadline = Some(Instant::now());
        self.full_screen_scan_deadline = Instant::now();
        self.last_window_activity.clear();
        self.pending_idle_confirmations.clear();
    }

    pub fn apply(&mut self, request: Request) -> Result<(), String> {
        let now = Instant::now();
        self.prune_retired_generations(now);
        match request {
            Request::Report {
                tool,
                pane_id,
                process_generation,
                sequence,
                state,
                session_id,
                session_name,
            } => {
                if is_screen_detected_tool(&tool) {
                    return Err(format!("{tool} state is owned by screen detection"));
                }
                let key = event_key(&tool, &pane_id, &process_generation);
                if self.retired_event_generations.contains_key(&key) {
                    return Ok(());
                }
                self.remove_reused_pane(&tool, &pane_id, &process_generation, now);
                if self
                    .agents
                    .get(&key)
                    .is_some_and(|record| sequence <= record.sequence)
                {
                    return Ok(());
                }
                self.agents.insert(
                    key,
                    AgentRecord {
                        source: Source::Event,
                        tool,
                        pane_id: Some(pane_id),
                        session_id,
                        session_name,
                        process_generation: Some(process_generation),
                        sequence,
                        state,
                        changed_at: SystemTime::now(),
                    },
                );
            }
            Request::Seen { pane_id } => {
                for record in self.agents.values_mut() {
                    if pane_id
                        .as_ref()
                        .is_some_and(|pane| record.pane_id.as_ref() == Some(pane))
                        && record.state == AgentState::Done
                    {
                        record.state = AgentState::Idle;
                        record.changed_at = SystemTime::now();
                    }
                }
            }
            Request::Exited {
                pane_id,
                session_id,
            } => {
                let retired: Vec<String> = self
                    .agents
                    .iter()
                    .filter(|(_, record)| {
                        (pane_id
                            .as_ref()
                            .is_some_and(|pane| record.pane_id.as_ref() == Some(pane))
                            || session_id
                                .as_ref()
                                .is_some_and(|session| &record.session_id == session))
                            && record.source == Source::Event
                    })
                    .map(|(identity, _)| identity.clone())
                    .collect();
                for identity in retired {
                    self.retire_event_generation(identity, now);
                }
                self.agents.retain(|_, record| {
                    !(pane_id
                        .as_ref()
                        .is_some_and(|pane| record.pane_id.as_ref() == Some(pane))
                        || session_id
                            .as_ref()
                            .is_some_and(|session| &record.session_id == session))
                });
            }
            _ => return Err("command is not a state event".into()),
        }
        Ok(())
    }

    fn remove_reused_pane(&mut self, tool: &str, pane: &str, generation: &str, now: Instant) {
        let reused: Vec<String> = self
            .agents
            .iter()
            .filter(|(_, record)| {
                record.source == Source::Event
                    && record.tool == tool
                    && record.pane_id.as_deref() == Some(pane)
                    && record.process_generation.as_deref() != Some(generation)
            })
            .map(|(identity, _)| identity.clone())
            .collect();
        for identity in reused {
            self.agents.remove(&identity);
            self.retire_event_generation(identity, now);
        }
    }

    fn retire_event_generation(&mut self, identity: String, now: Instant) {
        self.retired_event_generations.insert(identity, now);
        if self.retired_event_generations.len() <= MAX_RETIRED_GENERATIONS {
            return;
        }
        if let Some(oldest) = self
            .retired_event_generations
            .iter()
            .min_by_key(|(_, retired_at)| **retired_at)
            .map(|(identity, _)| identity.clone())
        {
            self.retired_event_generations.remove(&oldest);
        }
    }

    fn prune_retired_generations(&mut self, now: Instant) {
        self.retired_event_generations.retain(|_, retired_at| {
            now.saturating_duration_since(*retired_at) <= RETIRED_GENERATION_TTL
        });
    }

    pub fn process_deadlines(&mut self, now: Instant) {
        self.prune_retired_generations(now);
        if self
            .animation_deadline
            .is_some_and(|deadline| deadline <= now)
        {
            self.frame_index = (self.frame_index + 1) % self.config.frames.len();
            self.animation_deadline = Some(now + self.config.animation_interval);
        }
        self.expire_states();
        if self.screen_deadline.is_some_and(|deadline| deadline <= now) {
            let pending_idle_recheck = self.scan_screen_agents(now);
            let next_interval = if pending_idle_recheck {
                PENDING_IDLE_RECHECK
            } else {
                self.config.screen_interval
            };
            self.screen_deadline = Some(Instant::now() + next_interval);
        }
    }

    fn expire_states(&mut self) {
        if self.config.state_ttl.is_zero() {
            return;
        }
        let ttl = self.config.state_ttl;
        self.agents.retain(|_, record| match record.state {
            AgentState::Working | AgentState::Blocked => record
                .changed_at
                .elapsed()
                .map(|age| age <= ttl)
                .unwrap_or(true),
            _ => true,
        });
    }

    fn scan_screen_agents(&mut self, now: Instant) -> bool {
        let Some(rows) = list_pane_rows(&self.server_socket) else {
            return !self.pending_idle_confirmations.is_empty();
        };
        self.remove_exited_records(&rows, now);
        let full_scan = now >= self.full_screen_scan_deadline;
        if full_scan {
            self.full_screen_scan_deadline = now + self.config.screen_full_scan_interval;
        }
        let wall_clock_seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let mut process_table: Option<Option<String>> = None;
        let mut resolved = Vec::new();
        for row in rows {
            if let Some(tool) = self.resolve_screen_tool(&row, &mut process_table) {
                resolved.push((row, tool));
            }
        }

        let activity_recency_grace = self.config.screen_interval + Duration::from_secs(1);
        let mut active_keys = HashSet::new();
        let mut active_windows = HashSet::new();
        let mut dirty_pane_ids = Vec::new();
        for (row, tool) in &resolved {
            let key = screen_key(tool, &row.pane_id);
            active_keys.insert(key.clone());
            active_windows.insert(row.window_id.clone());
            let previous_activity = self.last_window_activity.get(&row.window_id).copied();
            let should_capture = should_capture_screen(
                self.agents.contains_key(&key),
                self.pending_idle_confirmations.contains_key(&key),
                full_scan,
                row.window_activity,
                previous_activity,
                wall_clock_seconds,
                activity_recency_grace,
            );
            self.last_window_activity
                .insert(row.window_id.clone(), row.window_activity);
            if should_capture {
                dirty_pane_ids.push(row.pane_id.as_str());
            }
        }
        self.last_window_activity
            .retain(|window_id, _| active_windows.contains(window_id));

        let mut screens =
            capture_panes_batch(&self.server_socket, &self.capture_marker, &dirty_pane_ids)
                .unwrap_or_else(|| {
                    dirty_pane_ids
                        .iter()
                        .filter_map(|pane_id| {
                            capture_pane(&self.server_socket, pane_id)
                                .map(|screen| (pane_id.to_string(), screen))
                        })
                        .collect()
                });

        for (row, tool) in resolved {
            let key = screen_key(&tool, &row.pane_id);
            let Some(screen) = screens.remove(&row.pane_id) else {
                continue;
            };
            let detection = match tool.as_str() {
                "pi" => detect_pi(&screen),
                "claude" => detect_claude(&row.pane_title, &screen),
                "codex" => detect_codex(&row.pane_title, &screen),
                _ => continue,
            };
            if detection.skip_state_update {
                self.pending_idle_confirmations.remove(&key);
                continue;
            }

            let previous = self.agents.get(&key).cloned();
            let hold_working = previous.as_ref().is_some_and(|record| {
                self.pending_idle_confirmations
                    .entry(key.clone())
                    .or_default()
                    .should_hold(record.state, detection, now)
            });
            if hold_working {
                continue;
            }
            self.pending_idle_confirmations.remove(&key);

            let state = self.screen_display_state(previous.as_ref(), detection.state, row.visible);
            let changed_at = previous
                .as_ref()
                .filter(|record| record.state == state && record.session_id == row.session_id)
                .map(|record| record.changed_at)
                .unwrap_or_else(SystemTime::now);
            self.agents.insert(
                key,
                AgentRecord {
                    source: Source::Screen,
                    tool,
                    pane_id: Some(row.pane_id),
                    session_id: row.session_id,
                    session_name: row.session_name,
                    process_generation: None,
                    sequence: 0,
                    state,
                    changed_at,
                },
            );
        }

        self.agents
            .retain(|key, record| record.source != Source::Screen || active_keys.contains(key));
        self.pending_idle_confirmations
            .retain(|key, _| active_keys.contains(key));
        !self.pending_idle_confirmations.is_empty()
    }

    fn remove_exited_records(&mut self, rows: &[PaneRow], now: Instant) {
        let live_panes: HashMap<&str, &PaneRow> =
            rows.iter().map(|row| (row.pane_id.as_str(), row)).collect();
        let live_sessions: HashSet<&str> = rows.iter().map(|row| row.session_id.as_str()).collect();

        // A pane can be moved between sessions without its agent process
        // exiting. Reconcile ownership from the pane snapshot before deciding
        // which generations exited so the old session's closure cannot retire
        // a still-running event generation.
        for record in self.agents.values_mut() {
            let Some(pane_id) = record.pane_id.as_deref() else {
                continue;
            };
            let Some(row) = live_panes.get(pane_id) else {
                continue;
            };
            record.session_id.clone_from(&row.session_id);
            record.session_name.clone_from(&row.session_name);
        }

        let exited: Vec<String> = self
            .agents
            .iter()
            .filter(|(_, record)| match record.pane_id.as_deref() {
                Some(pane_id) => !live_panes.contains_key(pane_id),
                None => !live_sessions.contains(record.session_id.as_str()),
            })
            .map(|(identity, _)| identity.clone())
            .collect();

        for identity in exited {
            if self
                .agents
                .remove(&identity)
                .is_some_and(|record| record.source == Source::Event)
            {
                self.retire_event_generation(identity, now);
            }
        }
    }

    fn resolve_screen_tool(
        &self,
        row: &PaneRow,
        process_table: &mut Option<Option<String>>,
    ) -> Option<String> {
        if row.session_name.starts_with(&self.config.prefix) {
            let configured = canonical_screen_tool(&row.configured_tool);
            if configured.is_some() {
                return configured;
            }
        }
        let command = basename(&row.command);
        if self.config.detect_commands.contains(command) {
            return canonical_screen_tool(command);
        }
        if !self.config.wrapper_commands.contains(command) {
            return None;
        }
        process_table
            .get_or_insert_with(process_table_snapshot)
            .as_deref()
            .and_then(|table| {
                resolve_child_screen_tool(row.pane_pid, table, &self.config.detect_commands)
            })
    }

    fn screen_display_state(
        &self,
        previous_record: Option<&AgentRecord>,
        detected_state: AgentState,
        pane_visible: bool,
    ) -> AgentState {
        if detected_state != AgentState::Idle {
            return detected_state;
        }
        let Some(record) = previous_record else {
            return AgentState::Idle;
        };
        if record.state == AgentState::Done {
            return AgentState::Done;
        }
        if !matches!(record.state, AgentState::Working | AgentState::Blocked) {
            return AgentState::Idle;
        }
        if pane_visible {
            AgentState::Idle
        } else {
            AgentState::Done
        }
    }

    pub fn reconcile(&mut self, now: Instant) {
        let working = self
            .agents
            .values()
            .filter(|record| record.state == AgentState::Working)
            .count();
        if self.config.status_enabled && self.config.animate_working && working > 0 {
            if self.animation_deadline.is_none() {
                self.animation_deadline = Some(now + self.config.animation_interval);
            }
        } else {
            self.animation_deadline = None;
            self.frame_index = 0;
        }
        self.expiry_deadline = self.next_expiry(now);
        let summary = if self.config.status_enabled {
            self.render()
        } else {
            String::new()
        };
        if self.published_summary.as_ref() == Some(&summary) {
            return;
        }
        if self.publish(&summary) {
            self.published_summary = Some(summary);
        }
    }

    fn next_expiry(&self, now: Instant) -> Option<Instant> {
        if self.config.state_ttl.is_zero() {
            return None;
        }
        let wall_clock_now = SystemTime::now();
        self.agents
            .values()
            .filter(|record| matches!(record.state, AgentState::Working | AgentState::Blocked))
            .filter_map(|record| {
                let age = wall_clock_now.duration_since(record.changed_at).ok()?;
                Some(now + self.config.state_ttl.saturating_sub(age))
            })
            .min()
    }

    pub fn next_wait(&self, now: Instant) -> Duration {
        [
            self.animation_deadline,
            self.expiry_deadline,
            self.screen_deadline,
        ]
        .into_iter()
        .flatten()
        .map(|deadline| deadline.saturating_duration_since(now))
        .min()
        .unwrap_or(Duration::from_secs(60))
    }

    fn render(&self) -> String {
        let mut blocked = 0;
        let mut working = 0;
        let mut done = 0;
        let mut idle = 0;
        for record in self.agents.values() {
            match record.state {
                AgentState::Blocked => blocked += 1,
                AgentState::Working => working += 1,
                AgentState::Done => done += 1,
                AgentState::Idle => idle += 1,
            }
        }
        let mut segments = Vec::new();
        if blocked > 0 {
            segments.push(format!("{blocked}{}", self.config.icon_blocked));
        }
        if working > 0 {
            let icon = if self.config.animate_working {
                &self.config.frames[self.frame_index]
            } else {
                &self.config.icon_working
            };
            segments.push(format!("{working}{icon}"));
        }
        if done > 0 {
            segments.push(format!("{done}{}", self.config.icon_done));
        }
        if self.config.show_idle && idle > 0 {
            segments.push(format!("{idle}{}", self.config.icon_idle));
        }
        if segments.is_empty() {
            String::new()
        } else {
            format!("{} {}", self.config.sigil, segments.join(" "))
        }
    }

    fn publish(&mut self, summary: &str) -> bool {
        let status = Command::new("tmux")
            .args([
                "-S",
                &self.server_socket,
                "set-option",
                "-g",
                "@agent_status_cache",
                summary,
            ])
            .status();
        if !status.is_ok_and(|status| status.success()) {
            return false;
        }

        let clients = tmux_output(
            &self.server_socket,
            &["list-clients", "-F", "#{client_name}"],
        )
        .unwrap_or_default();
        let clients: Vec<&str> = clients
            .lines()
            .filter(|client| !client.is_empty())
            .collect();
        if !clients.is_empty() {
            let mut args: Vec<String> = vec!["-S".into(), self.server_socket.clone()];
            for (index, client) in clients.iter().enumerate() {
                if index > 0 {
                    args.push(";".into());
                }
                args.extend([
                    "refresh-client".into(),
                    "-S".into(),
                    "-t".into(),
                    (*client).into(),
                ]);
            }
            let _ = Command::new("tmux").args(args).status();
        }
        true
    }

    pub fn snapshot(&self) -> Value {
        let records: Vec<Value> = self
            .agents
            .iter()
            .map(|(identity, record)| {
                json!({
                    "identity": identity,
                    "tool": record.tool,
                    "paneId": record.pane_id,
                    "sessionId": record.session_id,
                    "sessionName": record.session_name,
                    "state": state_label(record.state),
                    "changedAt": record.changed_at.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
                })
            })
            .collect();
        let summary = if self.config.status_enabled {
            self.render()
        } else {
            String::new()
        };
        json!({
            "summary": summary,
            "agents": self.agents.len(),
            "records": records,
            "working": self.agents.values().filter(|record| record.state == AgentState::Working).count(),
            "frameIndex": self.frame_index
        })
    }
}

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
    // Detection must inspect the live bottom screen, not scrollback. Otherwise
    // Pi's old `Working...` line can keep a completed turn marked as working.
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

fn detect_pi(screen: &str) -> ScreenDetection {
    // Pi renders this literal status while a turn is running. This is the same
    // high-confidence screen rule used by Herdr's bundled Pi manifest.
    if screen.contains("Working...") {
        return detection(AgentState::Working);
    }
    detection(AgentState::Idle)
}

fn detect_codex(title: &str, screen: &str) -> ScreenDetection {
    let title_lowercase = title.to_ascii_lowercase();
    if title_lowercase.contains("action required") {
        return detection(AgentState::Blocked);
    }
    if starts_with_braille_spinner(title) {
        return detection(AgentState::Working);
    }
    let after_prompt = after_last_codex_prompt(screen);
    let after_prompt_lowercase = after_prompt.to_ascii_lowercase();
    if contains_all(
        &after_prompt_lowercase,
        &[
            "↑/↓ to scroll",
            "pgup/pgdn to",
            "home/end to jump",
            "q to quit",
        ],
    ) && (after_prompt_lowercase.contains("esc to edit prev")
        || after_prompt_lowercase.contains("esc/← to edit prev"))
    {
        return skip_detection();
    }
    if contains_any(
        &after_prompt_lowercase,
        &[
            "press enter to confirm or esc to cancel",
            "enter to submit answer",
            "enter to submit all",
            "allow command?",
        ],
    ) {
        return detection(AgentState::Blocked);
    }
    let screen_lowercase = screen.to_ascii_lowercase();
    if weak_blocker(screen, &screen_lowercase) {
        return detection(AgentState::Blocked);
    }
    if !title.trim().is_empty() && !starts_with_braille_spinner(title) {
        return visible_idle_detection();
    }
    detection(AgentState::Idle)
}

fn detect_claude(title: &str, screen: &str) -> ScreenDetection {
    if starts_with_braille_spinner(title) {
        return detection(AgentState::Working);
    }
    let screen_lowercase = screen.to_ascii_lowercase();
    let bottom_lowercase = bottom_non_empty_lines(&screen_lowercase, 3);
    if bottom_lowercase.contains("showing detailed transcript")
        && contains_any(
            bottom_lowercase,
            &["ctrl+o", "ctrl+e", "↑↓ scroll", "? for shortcuts"],
        )
    {
        return skip_detection();
    }
    let after_rule_lowercase = after_last_horizontal_rule(&screen_lowercase);
    if contains_all(after_rule_lowercase, &["enter to select", "esc to cancel"])
        && contains_any(
            after_rule_lowercase,
            &[
                "tab/arrow keys to navigate",
                "arrow keys to navigate",
                "arrows to navigate",
                "↑/↓ to navigate",
                "↑↓ to navigate",
            ],
        )
    {
        return detection(AgentState::Blocked);
    }
    if contains_all(
        &screen_lowercase,
        &["run a dynamic workflow?", "esc to cancel"],
    ) {
        return detection(AgentState::Blocked);
    }
    let prompt_body = prompt_box_body(screen);
    let prompt_body_lowercase = prompt_body.to_ascii_lowercase();
    if has_claude_prompt_line(prompt_body)
        && !contains_any(
            &prompt_body_lowercase,
            &[
                "enter to select",
                "esc to cancel",
                "tab/arrow keys",
                "arrow keys to navigate",
                "↑/↓ to navigate",
            ],
        )
    {
        return visible_idle_detection();
    }
    if contains_all(
        &screen_lowercase,
        &["select model", "enter to set as default", "esc to cancel"],
    ) && !screen_lowercase.contains("do you want to proceed?")
        && !screen_lowercase.contains("enter to select")
    {
        return skip_detection();
    }
    if screen_lowercase.contains("do you want to proceed?")
        && contains_any(
            &screen_lowercase,
            &[
                "bash command",
                "bash(",
                "contains expansion",
                "tab to amend",
                "ctrl+e to explain",
            ],
        )
        && contains_any(&screen_lowercase, &["yes", "1. yes", "2. no"])
    {
        return detection(AgentState::Blocked);
    }
    if contains_all(
        after_rule_lowercase,
        &["do you want to proceed?", "esc to cancel"],
    ) && contains_any(
        after_rule_lowercase,
        &["1. yes", "2. yes", "2. no", "3. no"],
    ) {
        return detection(AgentState::Blocked);
    }
    if legacy_claude_blocker(screen, &screen_lowercase) {
        return detection(AgentState::Blocked);
    }
    if title.trim_start().starts_with('✳') {
        return visible_idle_detection();
    }
    detection(AgentState::Idle)
}

fn detection(state: AgentState) -> ScreenDetection {
    ScreenDetection {
        state,
        skip_state_update: false,
        visible_idle: false,
    }
}

fn visible_idle_detection() -> ScreenDetection {
    ScreenDetection {
        state: AgentState::Idle,
        skip_state_update: false,
        visible_idle: true,
    }
}

fn skip_detection() -> ScreenDetection {
    ScreenDetection {
        state: AgentState::Idle,
        skip_state_update: true,
        visible_idle: false,
    }
}

fn starts_with_braille_spinner(value: &str) -> bool {
    value
        .trim_start()
        .chars()
        .next()
        .is_some_and(|ch| ('\u{2800}'..='\u{28ff}').contains(&ch))
}

fn contains_all(haystack_lowercase: &str, needles_lowercase: &[&str]) -> bool {
    needles_lowercase
        .iter()
        .all(|needle| haystack_lowercase.contains(needle))
}

fn contains_any(haystack_lowercase: &str, needles_lowercase: &[&str]) -> bool {
    needles_lowercase
        .iter()
        .any(|needle| haystack_lowercase.contains(needle))
}

fn weak_blocker(screen: &str, screen_lowercase: &str) -> bool {
    screen_lowercase.contains("[y/n]")
        || screen_lowercase.contains("yes (y)")
        || ((screen_lowercase.contains("do you want to")
            || screen_lowercase.contains("would you like to"))
            && (screen_lowercase.contains("yes") || screen.contains('❯')))
}

fn legacy_claude_blocker(screen: &str, screen_lowercase: &str) -> bool {
    let prompt_alone = screen.lines().any(|line| line.trim() == "❯");
    if prompt_alone {
        return false;
    }
    weak_blocker(screen, screen_lowercase)
        || contains_any(
            screen_lowercase,
            &[
                "waiting for permission",
                "do you want to allow this connection?",
                "tab to amend",
                "ctrl+e to explain",
                "do you want to proceed?",
                "review your answers",
                "skip interview and plan immediately",
            ],
        )
}

fn after_last_codex_prompt(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(index) = lines
        .iter()
        .rposition(|line| *line == "›" || line.starts_with("› "))
    else {
        return content;
    };
    slice_from_line_index(content, &lines, index + 1)
}

fn bottom_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(start_index) = lines
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map(|(index, _)| index)
    else {
        return "";
    };
    slice_from_line_index(content, &lines, start_index)
}

fn after_last_horizontal_rule(content: &str) -> &str {
    let mut last_rule_end = 0usize;
    let mut offset = 0usize;
    for line in content.lines() {
        let next_offset = offset + line.len() + 1;
        if is_horizontal_rule(line) {
            last_rule_end = next_offset.min(content.len());
        }
        offset = next_offset;
    }
    &content[last_rule_end..]
}

fn prompt_box_body(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(top) = prompt_box_top_border_index(&lines) else {
        return "";
    };
    let start = line_start_offset(content, &lines, top + 1);
    let end_index = lines[top + 1..]
        .iter()
        .position(|line| is_horizontal_rule(line))
        .map(|relative| top + 1 + relative)
        .unwrap_or(lines.len());
    let end = line_start_offset(content, &lines, end_index);
    &content[start.min(content.len())..end.min(content.len())]
}

fn has_claude_prompt_line(content: &str) -> bool {
    content
        .lines()
        .any(|line| line.trim_start().starts_with('❯'))
}

fn prompt_box_top_border_index(lines: &[&str]) -> Option<usize> {
    let mut border_count = 0;
    for index in (0..lines.len()).rev() {
        if is_horizontal_rule(lines[index]) {
            border_count += 1;
            if border_count == 2 {
                return Some(index);
            }
        }
    }
    None
}

fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let rule_chars = trimmed.chars().take_while(|ch| *ch == '─').count();
    if rule_chars == 0 {
        return false;
    }
    let rule_bytes = trimmed
        .char_indices()
        .nth(rule_chars)
        .map(|(index, _)| index)
        .unwrap_or(trimmed.len());
    let suffix = trimmed[rule_bytes..].trim_start();
    suffix.is_empty() || rule_chars >= 3
}

fn slice_from_line_index<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    let byte_offset = line_start_offset(content, lines, index);
    &content[byte_offset.min(content.len())..]
}

fn line_start_offset(content: &str, lines: &[&str], index: usize) -> usize {
    lines[..index.min(lines.len())]
        .iter()
        .map(|line| line.len() + 1)
        .sum::<usize>()
        .min(content.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn center() -> StateCenter {
        StateCenter::new("/nonexistent".into(), Config::test())
    }

    #[test]
    fn config_defaults_to_a_bounded_periodic_full_scan() {
        let config = Config::from_values(&HashMap::new()).unwrap();
        assert_eq!(config.screen_full_scan_interval, Duration::from_secs(30));
    }

    #[test]
    fn config_rejects_a_full_scan_faster_than_regular_detection() {
        let mut values = HashMap::new();
        values.insert("@agent_screen_interval_ms".into(), "1000".into());
        values.insert("@agent_screen_full_scan_interval_ms".into(), "500".into());
        assert!(Config::from_values(&values).is_err());
    }

    #[test]
    fn startup_restore_accepts_event_owned_custom_mirrors() {
        let mut state = center();
        state.restore_mirror_row(
            "work\t$1\t%2\tcustom\tdone\t123\tmanual-generation\t7",
            false,
        );
        assert_eq!(state.agents.len(), 1);
        let restored = state.agents.values().next().unwrap();
        assert_eq!(restored.pane_id.as_deref(), Some("%2"));
        assert_eq!(restored.state, AgentState::Done);
        assert_eq!(restored.sequence, 7);
    }

    #[test]
    fn startup_restore_ignores_screen_detected_pi_mirrors() {
        let mut state = center();
        state.restore_mirror_row("work\t$1\t%2\tpi\tdone\t123\tg\t7", false);
        assert!(state.agents.is_empty());
    }

    #[test]
    fn startup_restore_ignores_screen_owned_codex_mirrors() {
        let mut state = center();
        state.restore_mirror_row("work\t$1\t%2\tcodex\tdone\t123\tg\t7", false);
        assert!(state.agents.is_empty());
    }

    #[test]
    fn idle_detection_on_unwatched_working_pane_becomes_done() {
        // A turn that finishes while the user is not looking at the pane must be
        // marked done so the badge flags an unseen result. Visibility is now read
        // from the batched list-panes flag instead of a per-pane fork.
        let state = center();
        let previous = AgentRecord {
            source: Source::Screen,
            tool: "codex".into(),
            pane_id: Some("%1".into()),
            session_id: "$1".into(),
            session_name: "work".into(),
            process_generation: None,
            sequence: 0,
            state: AgentState::Working,
            changed_at: SystemTime::now(),
        };
        assert_eq!(
            state.screen_display_state(Some(&previous), AgentState::Idle, false),
            AgentState::Done
        );
        assert_eq!(
            state.screen_display_state(Some(&previous), AgentState::Idle, true),
            AgentState::Idle
        );
    }

    #[test]
    fn old_sequence_does_not_replace_new() {
        let mut state = center();
        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%1".into(),
                process_generation: "g".into(),
                sequence: 2,
                state: AgentState::Working,
                session_id: "$1".into(),
                session_name: "work".into(),
            })
            .unwrap();
        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%1".into(),
                process_generation: "g".into(),
                sequence: 1,
                state: AgentState::Done,
                session_id: "$1".into(),
                session_name: "work".into(),
            })
            .unwrap();
        assert_eq!(
            state.agents.values().next().unwrap().state,
            AgentState::Working
        );
    }

    #[test]
    fn reports_are_rejected_for_screen_detected_tools() {
        for tool in ["pi", "codex", "claude"] {
            let mut state = center();
            let result = state.apply(Request::Report {
                tool: tool.into(),
                pane_id: "%1".into(),
                process_generation: "g".into(),
                sequence: 1,
                state: AgentState::Working,
                session_id: "$1".into(),
                session_name: "work".into(),
            });
            assert!(result.is_err());
            assert!(state.agents.is_empty());
        }
    }

    #[test]
    fn pane_reuse_drops_old_generation() {
        let mut state = center();
        for generation in ["a", "b"] {
            state
                .apply(Request::Report {
                    tool: "custom".into(),
                    pane_id: "%1".into(),
                    process_generation: generation.into(),
                    sequence: 1,
                    state: AgentState::Idle,
                    session_id: "$1".into(),
                    session_name: "work".into(),
                })
                .unwrap();
        }
        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%1".into(),
                process_generation: "a".into(),
                sequence: 2,
                state: AgentState::Done,
                session_id: "$1".into(),
                session_name: "work".into(),
            })
            .unwrap();
        assert_eq!(state.agents.len(), 1);
        assert_eq!(
            state
                .agents
                .values()
                .next()
                .unwrap()
                .process_generation
                .as_deref(),
            Some("b")
        );
    }

    #[test]
    fn seen_only_clears_done() {
        let mut state = center();
        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%1".into(),
                process_generation: "g".into(),
                sequence: 1,
                state: AgentState::Done,
                session_id: "$1".into(),
                session_name: "work".into(),
            })
            .unwrap();
        state
            .apply(Request::Seen {
                pane_id: Some("%1".into()),
            })
            .unwrap();
        assert_eq!(
            state.agents.values().next().unwrap().state,
            AgentState::Idle
        );
    }

    #[test]
    fn session_exit_does_not_remove_same_name_replacement() {
        let mut state = center();
        for (pane, generation, session_id) in [("%1", "old", "$1"), ("%2", "new", "$2")] {
            state
                .apply(Request::Report {
                    tool: "custom".into(),
                    pane_id: pane.into(),
                    process_generation: generation.into(),
                    sequence: 1,
                    state: AgentState::Working,
                    session_id: session_id.into(),
                    session_name: "agent-reused".into(),
                })
                .unwrap();
        }

        state
            .apply(Request::Exited {
                pane_id: None,
                session_id: Some("$1".into()),
            })
            .unwrap();
        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%2".into(),
                process_generation: "new".into(),
                sequence: 2,
                state: AgentState::Done,
                session_id: "$2".into(),
                session_name: "agent-reused".into(),
            })
            .unwrap();

        assert_eq!(state.agents.len(), 1);
        let replacement = state.agents.values().next().unwrap();
        assert_eq!(replacement.session_id, "$2");
        assert_eq!(replacement.state, AgentState::Done);
    }

    #[test]
    fn live_reconciliation_removes_only_the_exited_session_instance() {
        let mut state = center();
        for (pane, generation, session_id) in [("%1", "old", "$1"), ("%2", "new", "$2")] {
            state
                .apply(Request::Report {
                    tool: "custom".into(),
                    pane_id: pane.into(),
                    process_generation: generation.into(),
                    sequence: 1,
                    state: AgentState::Working,
                    session_id: session_id.into(),
                    session_name: "agent-reused".into(),
                })
                .unwrap();
        }
        let replacement = PaneRow {
            session_name: "agent-reused".into(),
            session_id: "$2".into(),
            window_id: "@2".into(),
            window_activity: 1,
            pane_id: "%2".into(),
            command: "pi".into(),
            pane_pid: 2,
            pane_title: String::new(),
            configured_tool: "pi".into(),
            visible: false,
        };

        state.remove_exited_records(&[replacement], Instant::now());

        assert_eq!(state.agents.len(), 1);
        assert_eq!(state.agents.values().next().unwrap().session_id, "$2");
    }

    #[test]
    fn live_reconciliation_moves_an_event_generation_with_its_pane() {
        let mut state = center();
        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%1".into(),
                process_generation: "generation".into(),
                sequence: 1,
                state: AgentState::Working,
                session_id: "$1".into(),
                session_name: "agent-old".into(),
            })
            .unwrap();
        let moved_pane = PaneRow {
            session_name: "agent-new".into(),
            session_id: "$2".into(),
            window_id: "@1".into(),
            window_activity: 1,
            pane_id: "%1".into(),
            command: "pi".into(),
            pane_pid: 1,
            pane_title: String::new(),
            configured_tool: "pi".into(),
            visible: false,
        };

        state.remove_exited_records(&[moved_pane], Instant::now());

        let moved_record = state.agents.values().next().unwrap();
        assert_eq!(moved_record.session_id, "$2");
        assert_eq!(moved_record.session_name, "agent-new");
        assert!(state.retired_event_generations.is_empty());

        state
            .apply(Request::Report {
                tool: "custom".into(),
                pane_id: "%1".into(),
                process_generation: "generation".into(),
                sequence: 2,
                state: AgentState::Done,
                session_id: "$2".into(),
                session_name: "agent-new".into(),
            })
            .unwrap();
        assert_eq!(
            state.agents.values().next().unwrap().state,
            AgentState::Done
        );
    }

    #[test]
    fn retired_generations_are_bounded_and_expire() {
        let mut state = center();
        let now = Instant::now();
        for index in 0..(MAX_RETIRED_GENERATIONS + 100) {
            state.retire_event_generation(format!("event:{index}"), now);
        }
        assert_eq!(
            state.retired_event_generations.len(),
            MAX_RETIRED_GENERATIONS
        );

        state.prune_retired_generations(now + RETIRED_GENERATION_TTL + Duration::from_secs(1));
        assert!(state.retired_event_generations.is_empty());
    }

    #[test]
    fn dirty_screen_selection_skips_old_unchanged_windows() {
        let grace = Duration::from_secs(2);
        assert!(!should_capture_screen(
            true,
            false,
            false,
            100,
            Some(100),
            200,
            grace,
        ));
        assert!(should_capture_screen(
            true,
            false,
            false,
            101,
            Some(100),
            200,
            grace,
        ));
    }

    #[test]
    fn dirty_screen_selection_keeps_recent_and_safety_scans() {
        let grace = Duration::from_secs(2);
        assert!(should_capture_screen(
            true,
            false,
            false,
            100,
            Some(100),
            102,
            grace,
        ));
        assert!(should_capture_screen(
            true,
            false,
            true,
            100,
            Some(100),
            200,
            grace,
        ));
        assert!(should_capture_screen(
            true,
            true,
            false,
            100,
            Some(100),
            200,
            grace,
        ));
        assert!(should_capture_screen(
            false,
            false,
            false,
            100,
            Some(100),
            200,
            grace,
        ));
    }

    #[test]
    fn plain_working_to_idle_requires_stable_confirmations() {
        let mut pending = PendingIdleConfirmation::default();
        let now = Instant::now();
        let idle = detection(AgentState::Idle);
        assert!(pending.should_hold(AgentState::Working, idle, now));
        assert!(pending.should_hold(AgentState::Working, idle, now + PENDING_IDLE_RECHECK));
        assert!(pending.should_hold(AgentState::Working, idle, now + PENDING_IDLE_RECHECK * 2));
        assert!(!pending.should_hold(AgentState::Working, idle, now + PENDING_IDLE_RECHECK * 3));
        assert_eq!(pending, PendingIdleConfirmation::default());
    }

    #[test]
    fn visible_idle_signal_bypasses_stability_delay() {
        let mut pending = PendingIdleConfirmation::default();
        assert!(!pending.should_hold(
            AgentState::Working,
            visible_idle_detection(),
            Instant::now(),
        ));
    }

    #[test]
    fn plain_idle_confirmation_has_a_bounded_delay() {
        let mut pending = PendingIdleConfirmation::default();
        let now = Instant::now();
        let idle = detection(AgentState::Idle);
        assert!(pending.should_hold(AgentState::Working, idle, now));
        assert!(!pending.should_hold(AgentState::Working, idle, now + PENDING_IDLE_CAP,));
    }

    #[test]
    fn pi_screen_detects_working_literal_and_idle_fallback() {
        assert_eq!(detect_pi("Working...").state, AgentState::Working);
        assert_eq!(detect_pi("tokens 1.2k  working...").state, AgentState::Idle);
        assert_eq!(detect_pi("Ready for input").state, AgentState::Idle);
    }

    #[test]
    fn canonical_screen_tools_include_pi() {
        assert_eq!(canonical_screen_tool("pi").as_deref(), Some("pi"));
        assert!(is_screen_detected_tool("pi"));
    }

    #[test]
    fn codex_title_detects_states() {
        assert_eq!(
            detect_codex("Action Required", "").state,
            AgentState::Blocked
        );
        assert_eq!(detect_codex("⠋ thinking", "").state, AgentState::Working);
        assert_eq!(detect_codex("Codex", "").state, AgentState::Idle);
    }

    #[test]
    fn codex_screen_detects_blocker_after_prompt() {
        let screen = "old\n› hello\nallow command?\n";
        assert_eq!(detect_codex("", screen).state, AgentState::Blocked);
    }

    #[test]
    fn claude_title_and_prompt_detect_states() {
        assert_eq!(detect_claude("⠋ thinking", "").state, AgentState::Working);
        assert_eq!(detect_claude("✳ ready", "").state, AgentState::Idle);
        let screen = "────────\nbody\n────────\n ❯\n";
        assert_eq!(detect_claude("", screen).state, AgentState::Idle);
    }

    #[test]
    fn claude_permission_detects_blocked() {
        let screen = "Do you want to proceed?\nBash command\n1. Yes\n2. No";
        assert_eq!(detect_claude("", screen).state, AgentState::Blocked);
    }

    #[test]
    fn animation_stops_and_resets() {
        let mut state = center();
        state.frame_index = 1;
        state.animation_deadline = Some(Instant::now());
        state.published_summary = Some(String::new());
        state.reconcile(Instant::now());
        assert_eq!(state.frame_index, 0);
        assert!(state.animation_deadline.is_none());
    }
}

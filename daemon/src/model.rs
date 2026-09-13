use crate::protocol::{AgentState, Request};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_FRAMES: usize = 64;
const MAX_FRAME_BYTES: usize = 64;
const RETIRED_GENERATION_TTL: Duration = Duration::from_secs(300);
const MAX_RETIRED_GENERATIONS: usize = 4096;
const PENDING_IDLE_RECHECK: Duration = Duration::from_millis(100);
const PENDING_IDLE_CAP: Duration = Duration::from_millis(700);
const PENDING_IDLE_CONFIRMATIONS: u8 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExposureMode {
    Off,
    File,
    Socket,
    Both,
}

impl ExposureMode {
    fn file_enabled(self) -> bool {
        matches!(self, Self::File | Self::Both)
    }

    fn socket_enabled(self) -> bool {
        matches!(self, Self::Socket | Self::Both)
    }
}

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
    pub state_exposure: ExposureMode,
    pub state_file: Option<PathBuf>,
}

fn config_value(values: &HashMap<String, String>, name: &str, default: &str) -> String {
    values
        .get(name)
        .filter(|value| !value.is_empty())
        .map(String::as_str)
        .unwrap_or(default)
        .to_string()
}

fn config_u64(
    values: &HashMap<String, String>,
    name: &str,
    default: u64,
    label: &str,
) -> Result<u64, String> {
    let raw = values.get(name).map(String::as_str).unwrap_or("");
    if raw.is_empty() {
        return Ok(default);
    }
    raw.parse::<u64>()
        .map_err(|_| format!("{label} must be an integer"))
}

fn config_frames(
    values: &HashMap<String, String>,
    working_icon: &str,
) -> Result<Vec<String>, String> {
    let defaults = format!("{working_icon} ✷ ✹ ✴");
    let text = config_value(values, "@agent_status_anim_frames", &defaults);
    let frames: Vec<String> = text.split_whitespace().map(str::to_string).collect();
    let invalid_count = frames.is_empty() || frames.len() > MAX_FRAMES;
    let oversized = frames.iter().any(|value| value.len() > MAX_FRAME_BYTES);
    if invalid_count || oversized {
        return Err("animation frames must contain 1..64 frames of at most 64 bytes".into());
    }
    Ok(frames)
}

fn config_intervals(values: &HashMap<String, String>) -> Result<(u64, u64, u64), String> {
    let animation = config_u64(
        values,
        "@agent_animation_interval_ms",
        1000,
        "animation interval",
    )?;
    let screen = config_u64(
        values,
        "@agent_screen_interval_ms",
        1000,
        "screen detection interval",
    )?;
    let full_scan = config_u64(
        values,
        "@agent_screen_full_scan_interval_ms",
        30000,
        "screen full scan interval",
    )?;
    if animation < 250 {
        return Err("animation interval must be at least 250ms".into());
    }
    if screen < 250 {
        return Err("screen detection interval must be at least 250ms".into());
    }
    if full_scan < screen {
        return Err(
            "screen full scan interval must not be shorter than the screen detection interval"
                .into(),
        );
    }
    Ok((animation, screen, full_scan))
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
        let working_icon = config_value(values, "@agent_status_icon_working", "✦");
        let frames = config_frames(values, &working_icon)?;
        let (animation_ms, screen_ms, full_scan_ms) = config_intervals(values)?;
        let ttl = config_u64(values, "@agent_state_ttl", 259200, "state TTL")?;
        let (state_exposure, state_file) = exposure_config(values)?;
        Ok(Self {
            prefix: config_value(values, "@agent_session_prefix", "agent-"),
            status_enabled: config_value(values, "@agent_status", "on") == "on",
            animate_working: config_value(values, "@agent_status_animate_working", "on") == "on",
            sigil: config_value(values, "@agent_status_sigil", "agents"),
            icon_blocked: config_value(values, "@agent_status_icon_blocked", "●"),
            icon_working: working_icon,
            icon_done: config_value(values, "@agent_status_icon_done", "✓"),
            icon_idle: config_value(values, "@agent_status_icon_idle", "·"),
            show_idle: config_value(values, "@agent_status_show_idle", "off") == "on",
            frames,
            animation_interval: Duration::from_millis(animation_ms),
            screen_interval: Duration::from_millis(screen_ms),
            screen_full_scan_interval: Duration::from_millis(full_scan_ms),
            state_ttl: Duration::from_secs(ttl),
            detect_commands: word_set(&config_value(
                values,
                "@agent_detect_commands",
                "pi codex claude",
            )),
            wrapper_commands: word_set(&config_value(
                values,
                "@agent_detect_wrappers",
                "node bun npx npm pnpm yarn",
            )),
            state_exposure,
            state_file,
        })
    }

    #[cfg(test)]
    pub(crate) fn test() -> Self {
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
            state_exposure: ExposureMode::Off,
            state_file: None,
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
    session_attached: bool,
    window_id: String,
    window_index: u32,
    window_name: String,
    window_activity: u64,
    window_active: bool,
    pane_id: String,
    pane_index: u32,
    command: String,
    current_path: String,
    pane_pid: u32,
    pane_title: String,
    configured_tool: String,
    pane_active: bool,
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
    pane_rows: Vec<PaneRow>,
    published_exposure_payload: Option<String>,
    published_file_path: Option<PathBuf>,
    exposure_publish_error: Option<String>,
    capture_marker: String,
}

include!("model/state_exposure.rs");
include!("model/state_events.rs");
include!("model/state_scan.rs");
include!("model/state_output.rs");
include!("model/screen_io.rs");
include!("model/screen_detection.rs");
include!("model/screen_detection_tools.rs");

#[cfg(test)]
mod tests {
    use super::*;

    include!("model/tests_config.rs");
    include!("model/tests_state.rs");
    include!("model/tests_exposure.rs");
    include!("model/tests_detection.rs");
}

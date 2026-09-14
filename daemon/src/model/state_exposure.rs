use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

fn exposure_config(
    values: &HashMap<String, String>,
) -> Result<(ExposureMode, Option<PathBuf>), String> {
    let mode = match config_value(values, "@agent_state_exposure", "both").as_str() {
        "off" => ExposureMode::Off,
        "file" => ExposureMode::File,
        "socket" => ExposureMode::Socket,
        "both" => ExposureMode::Both,
        _ => return Err("state exposure must be off, file, socket, or both".into()),
    };
    if !mode.file_enabled() {
        return Ok((mode, None));
    }
    let configured = config_value(
        values,
        "@agent_state_file",
        "~/.cache/tmux-argos/state.json",
    );
    let path = expand_state_file(&configured)?;
    Ok((mode, Some(path)))
}

fn expand_state_file(configured: &str) -> Result<PathBuf, String> {
    let path = if configured.starts_with("~/") {
        let home = std::env::var_os("HOME").ok_or("HOME is required for @agent_state_file")?;
        let suffix = configured.strip_prefix("~/").unwrap_or_default();
        PathBuf::from(home).join(suffix)
    } else {
        PathBuf::from(configured)
    };
    if !path.is_absolute() || path.file_name().is_none() {
        return Err("@agent_state_file must resolve to an absolute file path".into());
    }
    Ok(path)
}

fn atomic_write_private(path: &Path, contents: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or("@agent_state_file has no parent directory")?;
    let parent_was_missing = !parent.exists();
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    if parent_was_missing {
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("@agent_state_file has an invalid file name")?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(".{file_name}.{}.{}.tmp", std::process::id(), nonce));
    let result = write_and_replace(&temporary, path, contents);
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn write_and_replace(temporary: &Path, path: &Path, contents: &[u8]) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(temporary)
        .map_err(|error| error.to_string())?;
    file.write_all(contents).map_err(|error| error.to_string())?;
    drop(file);
    fs::rename(temporary, path).map_err(|error| error.to_string())
}

impl StateCenter {
    fn pane_agent_record(&self, pane_id: &str) -> Option<&AgentRecord> {
        self.agents
            .iter()
            .filter(|(_, record)| record.pane_id.as_deref() == Some(pane_id))
            .max_by(|(left_key, left), (right_key, right)| {
                left.changed_at
                    .cmp(&right.changed_at)
                    .then_with(|| left_key.cmp(right_key))
            })
            .map(|(_, record)| record)
    }

    fn recognized_agent<'a>(
        &'a self,
        row: &'a PaneRow,
        record: Option<&'a AgentRecord>,
    ) -> Option<&'a str> {
        if let Some(record) = record {
            return Some(&record.tool);
        }
        if !row.configured_tool.is_empty() {
            return Some(&row.configured_tool);
        }
        let command = basename(&row.command);
        if self.config.detect_commands.contains(command) {
            return Some(command);
        }
        None
    }

    fn exposed_panes(&self) -> Vec<Value> {
        self.pane_rows
            .iter()
            .map(|row| {
                let record = self.pane_agent_record(&row.pane_id);
                let agent = self.recognized_agent(row, record);
                let agent_state = record.map(|value| state_label(value.state));
                let changed_at = record.map(|value| {
                    value
                        .changed_at
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs()
                });
                let active = matches!(
                    record.map(|value| value.state),
                    Some(AgentState::Working | AgentState::Blocked)
                );
                let popup_host = row.popup_host.as_ref().map(|host| {
                    json!({
                        "client": host.client,
                        "sessionId": host.session_id,
                        "windowId": host.window_id,
                        "paneId": host.pane_id
                    })
                });
                json!({
                    "sessionId": row.session_id,
                    "sessionName": row.session_name,
                    "sessionAttached": row.session_attached,
                    "windowId": row.window_id,
                    "windowIndex": row.window_index,
                    "windowName": row.window_name,
                    "windowActive": row.window_active,
                    "paneId": row.pane_id,
                    "paneIndex": row.pane_index,
                    "panePid": row.pane_pid,
                    "paneTitle": row.pane_title,
                    "paneActive": row.pane_active,
                    "visible": row.visible,
                    "popupHost": popup_host,
                    "popupActive": row.popup_active,
                    "command": row.command,
                    "currentPath": row.current_path,
                    "agent": agent,
                    "activity": if active { "active" } else { "idle" },
                    "agentState": agent_state,
                    "changedAt": changed_at
                })
            })
            .collect()
    }

    fn exposure_snapshot_from(&self, panes: Vec<Value>) -> Value {
        let generated_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        json!({
            "schemaVersion": 2,
            "generatedAt": generated_at,
            "panes": panes
        })
    }

    pub fn inspect(&self) -> Result<Value, String> {
        if !self.config.state_exposure.socket_enabled() {
            return Err("socket state exposure is disabled".into());
        }
        Ok(self.exposure_snapshot_from(self.exposed_panes()))
    }

    fn publish_exposure_file(&mut self) -> Result<bool, String> {
        if !self.config.state_exposure.file_enabled() {
            return Ok(false);
        }
        let path = self
            .config
            .state_file
            .clone()
            .ok_or("file state exposure has no configured path")?;
        let panes = self.exposed_panes();
        let payload = serde_json::to_string(&panes).map_err(|error| error.to_string())?;
        let unchanged = self.published_file_path.as_ref() == Some(&path)
            && self.published_exposure_payload.as_deref() == Some(&payload);
        if unchanged {
            return Ok(false);
        }
        let mut output = serde_json::to_vec(&self.exposure_snapshot_from(panes))
            .map_err(|error| error.to_string())?;
        output.push(b'\n');
        atomic_write_private(&path, &output)?;
        self.published_exposure_payload = Some(payload);
        self.published_file_path = Some(path);
        Ok(true)
    }

    fn reconcile_exposure(&mut self) {
        match self.publish_exposure_file() {
            Ok(_) => self.exposure_publish_error = None,
            Err(error) => {
                if self.exposure_publish_error.as_ref() != Some(&error) {
                    eprintln!("tmux-argos-state-daemon: state file exposure failed: {error}");
                }
                self.exposure_publish_error = Some(error);
            }
        }
    }

    pub fn remove_exposure_file(&mut self) {
        if let Some(path) = self.published_file_path.take() {
            let _ = fs::remove_file(path);
        }
        self.published_exposure_payload = None;
        self.exposure_publish_error = None;
    }

    fn prepare_exposure_config_replacement(&mut self, next: &Config) {
        if next.state_exposure == ExposureMode::Off {
            self.pane_rows = Vec::new();
        }
        let next_path = if next.state_exposure.file_enabled() {
            next.state_file.as_ref()
        } else {
            None
        };
        if self.published_file_path.as_ref() != next_path {
            self.remove_exposure_file();
        }
    }
}

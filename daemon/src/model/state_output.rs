#[derive(Default)]
struct StateCounts {
    blocked: usize,
    working: usize,
    done: usize,
    idle: usize,
}

impl StateCenter {
    fn state_counts(&self) -> StateCounts {
        let mut counts = StateCounts::default();
        for record in self.agents.values() {
            match record.state {
                AgentState::Blocked => counts.blocked += 1,
                AgentState::Working => counts.working += 1,
                AgentState::Done => counts.done += 1,
                AgentState::Idle => counts.idle += 1,
            }
        }
        counts
    }

    fn working_segment(&self, count: usize) -> Option<String> {
        if count == 0 {
            return None;
        }
        let icon = match self.config.animate_working {
            true => &self.config.frames[self.frame_index],
            false => &self.config.icon_working,
        };
        Some(format!("{count}{icon}"))
    }

    fn render(&self) -> String {
        let counts = self.state_counts();
        let mut segments = Vec::new();
        if counts.blocked > 0 {
            segments.push(format!("{}{}", counts.blocked, self.config.icon_blocked));
        }
        if let Some(segment) = self.working_segment(counts.working) {
            segments.push(segment);
        }
        if counts.done > 0 {
            segments.push(format!("{}{}", counts.done, self.config.icon_done));
        }
        if self.config.show_idle && counts.idle > 0 {
            segments.push(format!("{}{}", counts.idle, self.config.icon_idle));
        }
        match segments.is_empty() {
            true => String::new(),
            false => format!("{} {}", self.config.sigil, segments.join(" ")),
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

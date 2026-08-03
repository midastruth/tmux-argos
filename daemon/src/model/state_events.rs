fn record_matches_exit(
    record: &AgentRecord,
    pane_id: Option<&str>,
    session_id: Option<&str>,
) -> bool {
    let same_pane = pane_id.is_some_and(|pane| record.pane_id.as_deref() == Some(pane));
    let same_session = session_id.is_some_and(|session| record.session_id == session);
    same_pane || same_session
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

    fn apply_report(&mut self, record: AgentRecord, now: Instant) -> Result<(), String> {
        if is_screen_detected_tool(&record.tool) {
            return Err(format!("{} state is owned by screen detection", record.tool));
        }
        let pane_id = record.pane_id.as_deref().unwrap_or_default();
        let generation = record.process_generation.as_deref().unwrap_or_default();
        let key = event_key(&record.tool, pane_id, generation);
        if self.retired_event_generations.contains_key(&key) {
            return Ok(());
        }
        self.remove_reused_pane(&record.tool, pane_id, generation, now);
        if self
            .agents
            .get(&key)
            .is_some_and(|current| record.sequence <= current.sequence)
        {
            return Ok(());
        }
        self.agents.insert(key, record);
        Ok(())
    }

    fn apply_seen(&mut self, pane_id: Option<String>) {
        for record in self.agents.values_mut() {
            let same_pane = pane_id
                .as_ref()
                .is_some_and(|pane| record.pane_id.as_ref() == Some(pane));
            if same_pane && record.state == AgentState::Done {
                record.state = AgentState::Idle;
                record.changed_at = SystemTime::now();
            }
        }
    }

    fn apply_exit(&mut self, pane_id: Option<String>, session_id: Option<String>, now: Instant) {
        let retired: Vec<String> = self
            .agents
            .iter()
            .filter(|(_, record)| {
                record.source == Source::Event
                    && record_matches_exit(record, pane_id.as_deref(), session_id.as_deref())
            })
            .map(|(identity, _)| identity.clone())
            .collect();
        for identity in retired {
            self.retire_event_generation(identity, now);
        }
        self.agents
            .retain(|_, record| !record_matches_exit(record, pane_id.as_deref(), session_id.as_deref()));
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
            } => self.apply_report(
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
                now,
            ),
            Request::Seen { pane_id } => {
                self.apply_seen(pane_id);
                Ok(())
            }
            Request::Exited {
                pane_id,
                session_id,
            } => {
                self.apply_exit(pane_id, session_id, now);
                Ok(())
            }
            _ => Err("command is not a state event".into()),
        }
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

}

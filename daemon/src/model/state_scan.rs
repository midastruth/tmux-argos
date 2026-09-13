impl StateCenter {
    fn resolve_screen_rows(&self, rows: Vec<PaneRow>) -> Vec<(PaneRow, String)> {
        let mut process_table: Option<Option<String>> = None;
        rows.into_iter()
            .filter_map(|row| {
                let tool = self.resolve_screen_tool(&row, &mut process_table)?;
                Some((row, tool))
            })
            .collect()
    }

    fn select_dirty_panes(
        &mut self,
        resolved: &[(PaneRow, String)],
        full_scan: bool,
        wall_clock_seconds: u64,
    ) -> (HashSet<String>, Vec<String>) {
        let grace = self.config.screen_interval + Duration::from_secs(1);
        let mut active_keys = HashSet::new();
        let mut active_windows = HashSet::new();
        let mut dirty_panes = Vec::new();
        for (row, tool) in resolved {
            let key = screen_key(tool, &row.pane_id);
            active_keys.insert(key.clone());
            active_windows.insert(row.window_id.clone());
            let previous_activity = self.last_window_activity.get(&row.window_id).copied();
            if should_capture_screen(
                self.agents.contains_key(&key),
                self.pending_idle_confirmations.contains_key(&key),
                full_scan,
                row.window_activity,
                previous_activity,
                wall_clock_seconds,
                grace,
            ) {
                dirty_panes.push(row.pane_id.clone());
            }
            self.last_window_activity
                .insert(row.window_id.clone(), row.window_activity);
        }
        self.last_window_activity
            .retain(|window_id, _| active_windows.contains(window_id));
        (active_keys, dirty_panes)
    }

    fn capture_dirty_panes(&self, pane_ids: &[String]) -> HashMap<String, String> {
        let pane_refs: Vec<&str> = pane_ids.iter().map(String::as_str).collect();
        capture_panes_batch(&self.server_socket, &self.capture_marker, &pane_refs).unwrap_or_else(
            || {
                pane_ids
                    .iter()
                    .filter_map(|pane_id| {
                        capture_pane(&self.server_socket, pane_id)
                            .map(|screen| (pane_id.clone(), screen))
                    })
                    .collect()
            },
        )
    }

    fn apply_screen_detection(&mut self, row: PaneRow, tool: String, screen: &str, now: Instant) {
        let key = screen_key(&tool, &row.pane_id);
        let detection = match tool.as_str() {
            "pi" => detect_pi(screen),
            "claude" => detect_claude(&row.pane_title, screen),
            "codex" => detect_codex(&row.pane_title, screen),
            _ => return,
        };
        if detection.skip_state_update {
            self.pending_idle_confirmations.remove(&key);
            return;
        }
        let previous = self.agents.get(&key).cloned();
        let hold_working = previous.as_ref().is_some_and(|record| {
            self.pending_idle_confirmations
                .entry(key.clone())
                .or_default()
                .should_hold(record.state, detection, now)
        });
        if hold_working {
            return;
        }
        self.pending_idle_confirmations.remove(&key);
        let state = self.screen_display_state(previous.as_ref(), detection.state, row.visible);
        let unchanged = previous
            .as_ref()
            .filter(|record| record.state == state && record.session_id == row.session_id);
        let changed_at = unchanged.map_or_else(SystemTime::now, |record| record.changed_at);
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

    fn prune_inactive_screens(&mut self, active_keys: &HashSet<String>) {
        self.agents
            .retain(|key, record| record.source != Source::Screen || active_keys.contains(key));
        self.pending_idle_confirmations
            .retain(|key, _| active_keys.contains(key));
    }

    /// Drops confirmations that can no longer resolve and reports whether any
    /// live confirmation still justifies the fast recheck interval.
    fn retain_resolvable_idle_confirmations(&mut self, now: Instant) -> bool {
        self.pending_idle_confirmations.retain(|_, confirmation| {
            let Some(started_at) = confirmation.started_at else {
                return true;
            };
            now.saturating_duration_since(started_at) < PENDING_IDLE_CAP
        });
        !self.pending_idle_confirmations.is_empty()
    }

    fn scan_screen_agents(&mut self, now: Instant) -> bool {
        let Some(rows) = list_pane_rows(&self.server_socket) else {
            // Without a pane list no capture can advance or expire a pending
            // confirmation, so an expired one must not keep asking for a
            // 100ms recheck forever.
            return self.retain_resolvable_idle_confirmations(now);
        };
        if self.config.state_exposure != ExposureMode::Off {
            self.pane_rows.clone_from(&rows);
        }
        self.remove_exited_records(&rows, now);
        let full_scan = now >= self.full_screen_scan_deadline;
        if full_scan {
            self.full_screen_scan_deadline = now + self.config.screen_full_scan_interval;
        }
        let wall_clock_seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let resolved = self.resolve_screen_rows(rows);
        let (active_keys, dirty_panes) =
            self.select_dirty_panes(&resolved, full_scan, wall_clock_seconds);
        let mut screens = self.capture_dirty_panes(&dirty_panes);
        for (row, tool) in resolved {
            if let Some(screen) = screens.remove(&row.pane_id) {
                self.apply_screen_detection(row, tool, &screen, now);
            }
        }
        self.prune_inactive_screens(&active_keys);
        self.retain_resolvable_idle_confirmations(now)
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
        if self.published_summary.as_ref() != Some(&summary) && self.publish(&summary) {
            self.published_summary = Some(summary);
        }
        self.reconcile_exposure();
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

}

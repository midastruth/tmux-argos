    fn program_pane(pane_id: &str, visible: bool, pipe_open: bool) -> PaneRow {
        PaneRow {
            session_name: "agent-pi-1".into(),
            session_id: "$1".into(),
            session_attached: visible,
            window_id: "@1".into(),
            window_index: 0,
            window_name: "pi".into(),
            window_activity: 1,
            window_active: visible,
            pane_id: pane_id.into(),
            pane_index: 0,
            command: "pi".into(),
            current_path: "/tmp".into(),
            pane_pid: 1,
            pane_title: String::new(),
            configured_tool: "pi".into(),
            pane_active: visible,
            pipe_open,
            visible,
            popup_host: None,
            popup_active: false,
        }
    }

    fn program_status(state: ProgramState, kind: Option<BlockedKind>) -> Request {
        Request::ProgramStatus {
            pane_id: "%1".into(),
            app: Some("pi".into()),
            state,
            kind,
        }
    }

    /// Applies a relayed report and the scan that follows it.
    fn report_then_scan(state: &mut StateCenter, request: Request, visible: bool) -> AgentState {
        state.apply(request).unwrap();
        let row = program_pane("%1", visible, true);
        let resolved = vec![(row.clone(), "pi".to_string())];
        state.prune_program_statuses(&resolved);
        if state.has_program_status("%1", "pi") {
            state.apply_program_detection(row, "pi".into());
        }
        pi_record(state).state
    }

    fn pi_record(state: &StateCenter) -> &AgentRecord {
        &state.agents[&screen_key("pi", "%1")]
    }

    // @acceptance-id:program-status-authority
    #[test]
    fn relayed_pi_program_status_owns_state_and_marks_unseen_completion() {
        let mut state = center();
        let blocked = program_status(ProgramState::Blocked, Some(BlockedKind::Permission));
        assert_eq!(report_then_scan(&mut state, blocked, true), AgentState::Blocked);
        assert_eq!(pi_record(&state).blocked_kind, Some(BlockedKind::Permission));

        let working = program_status(ProgramState::Working, None);
        assert_eq!(report_then_scan(&mut state, working, false), AgentState::Working);
        assert_eq!(pi_record(&state).blocked_kind, None);

        let done = program_status(ProgramState::Done, None);
        assert_eq!(report_then_scan(&mut state, done, false), AgentState::Done);

        // The completion is consumed once: seeing the pane clears it and later
        // scans of the same stored report do not re-flag it.
        state.apply(Request::Seen { pane_id: Some("%1".into()) }).unwrap();
        state.apply_program_detection(program_pane("%1", false, true), "pi".into());
        assert_eq!(pi_record(&state).state, AgentState::Idle);
    }

    #[test]
    fn watched_completion_and_program_idle_do_not_create_done() {
        let mut state = center();
        let done = program_status(ProgramState::Error, None);
        assert_eq!(report_then_scan(&mut state, done, true), AgentState::Idle);

        let mut state = center();
        let working = program_status(ProgramState::Working, None);
        report_then_scan(&mut state, working, false);
        let cancelled = program_status(ProgramState::Idle, None);
        assert_eq!(report_then_scan(&mut state, cancelled, false), AgentState::Idle);
    }

    #[test]
    fn unseen_done_persists_until_seen_under_later_idle_reports() {
        let mut state = center();
        report_then_scan(&mut state, program_status(ProgramState::Done, None), false);
        let idle = program_status(ProgramState::Idle, None);
        assert_eq!(report_then_scan(&mut state, idle, true), AgentState::Done);
    }

    #[test]
    fn completion_reported_before_any_scan_is_not_lost() {
        let mut state = center();
        state.apply(program_status(ProgramState::Working, None)).unwrap();
        let done = program_status(ProgramState::Done, None);
        assert_eq!(report_then_scan(&mut state, done, false), AgentState::Done);
    }

    #[test]
    fn clear_mismatched_app_or_closed_relay_falls_back_to_screen_detection() {
        let mut state = center();
        state.apply(program_status(ProgramState::Working, None)).unwrap();
        assert!(state.has_program_status("%1", "pi"));
        assert!(!state.has_program_status("%1", "codex"));

        state.apply(program_status(ProgramState::Clear, None)).unwrap();
        assert!(!state.has_program_status("%1", "pi"));

        state.apply(program_status(ProgramState::Working, None)).unwrap();
        let closed_relay = vec![(program_pane("%1", false, false), "pi".to_string())];
        state.prune_program_statuses(&closed_relay);
        assert!(!state.has_program_status("%1", "pi"));

        state.apply(program_status(ProgramState::Working, None)).unwrap();
        let agent_exited: Vec<(PaneRow, String)> = Vec::new();
        state.prune_program_statuses(&agent_exited);
        assert!(state.program_statuses.is_empty());

        let unnamed = Request::ProgramStatus {
            pane_id: "%1".into(),
            app: None,
            state: ProgramState::Working,
            kind: None,
        };
        state.apply(unnamed).unwrap();
        assert!(state.has_program_status("%1", "pi"));
        let impersonating = Request::ProgramStatus {
            pane_id: "%1".into(),
            app: Some("claude-code".into()),
            state: ProgramState::Working,
            kind: None,
        };
        state.apply(impersonating).unwrap();
        assert!(!state.has_program_status("%1", "pi"));
        assert!(state.has_program_status("%1", "claude"));
    }

    #[test]
    fn program_status_reports_request_an_immediate_scan() {
        let mut state = center();
        let later = Instant::now() + Duration::from_secs(60);
        state.screen_deadline = Some(later);
        state.apply(program_status(ProgramState::Working, None)).unwrap();
        assert!(state.screen_deadline.unwrap() < later);
    }

    #[test]
    fn disabled_program_status_ignores_reports_and_relays() {
        let mut config = Config::test();
        config.program_status_enabled = false;
        let mut state = StateCenter::new("/nonexistent".into(), config);
        let later = Instant::now() + Duration::from_secs(60);
        state.screen_deadline = Some(later);
        state.apply(program_status(ProgramState::Working, None)).unwrap();
        assert!(state.program_statuses.is_empty());
        assert_eq!(state.screen_deadline, Some(later));

        let mut enabled = center();
        enabled.apply(program_status(ProgramState::Working, None)).unwrap();
        let mut disabled = Config::test();
        disabled.program_status_enabled = false;
        enabled.replace_config(disabled);
        assert!(!enabled.has_program_status("%1", "pi"));
        assert!(enabled.program_statuses.is_empty());
    }

    #[test]
    fn program_status_config_defaults_on_and_accepts_off() {
        assert!(Config::from_values(&HashMap::new()).unwrap().program_status_enabled);
        let values = config_values(&[("@agent_program_status", "off".into())]);
        assert!(!Config::from_values(&values).unwrap().program_status_enabled);
    }

    #[test]
    fn program_panes_skip_capture_but_stay_active() {
        let mut state = center();
        let resolved = vec![
            (program_pane("%1", false, true), "pi".to_string()),
            (program_pane("%2", false, true), "pi".to_string()),
        ];
        let program_panes = HashSet::from(["%1".to_string()]);
        let (active_keys, dirty_panes) =
            state.select_dirty_panes(&resolved, &program_panes, true, 100);
        assert_eq!(dirty_panes, vec!["%2".to_string()]);
        assert!(active_keys.contains(&screen_key("pi", "%1")));
    }

    #[test]
    fn pane_parser_reads_the_pipe_flag_and_rejects_non_boolean_values() {
        let mut fields = [
            "work", "$1", "0", "@2", "0", "pi", "100", "1", "%3", "1", "pi", "/tmp", "123",
            "title", "pi", "1", "", "", "", "", "", "1",
        ];
        let separator = PANE_FIELD_SEPARATOR.to_string();
        assert!(parse_pane_record(&fields.join(&separator)).unwrap().pipe_open);
        fields[21] = "0";
        assert!(!parse_pane_record(&fields.join(&separator)).unwrap().pipe_open);
        fields[21] = "yes";
        assert!(parse_pane_record(&fields.join(&separator)).is_none());
    }

    #[test]
    fn only_pi_panes_receive_a_program_status_relay() {
        assert!(tool_emits_program_status_in_tmux("pi"));
        for tool in ["claude", "codex", "custom"] {
            assert!(!tool_emits_program_status_in_tmux(tool));
        }
        assert!(program_app_matches_tool(Some("pi"), "pi"));
        assert!(!program_app_matches_tool(Some("pi"), "codex"));
    }

    #[test]
    fn blocked_kind_is_exposed_only_for_blocked_records() {
        let mut state = StateCenter::new(
            "/nonexistent".into(),
            exposure_config(ExposureMode::Socket, None),
        );
        state.pane_rows = vec![program_pane("%1", false, true)];
        let blocked = program_status(ProgramState::Blocked, Some(BlockedKind::Question));
        report_then_scan(&mut state, blocked, false);
        assert_eq!(state.inspect().unwrap()["panes"][0]["blockedKind"], "question");
        for (kind, label) in [(BlockedKind::Permission, "permission"), (BlockedKind::Auth, "auth")] {
            report_then_scan(&mut state, program_status(ProgramState::Blocked, Some(kind)), false);
            assert_eq!(state.inspect().unwrap()["panes"][0]["blockedKind"], label);
        }

        report_then_scan(&mut state, program_status(ProgramState::Working, None), false);
        assert!(state.inspect().unwrap()["panes"][0]["blockedKind"].is_null());
    }

    #[test]
    fn a_new_blocking_reason_restarts_the_state_age() {
        let mut state = center();
        let permission = program_status(ProgramState::Blocked, Some(BlockedKind::Permission));
        report_then_scan(&mut state, permission, false);
        let first_change = UNIX_EPOCH + Duration::from_secs(1);
        state.agents.get_mut(&screen_key("pi", "%1")).unwrap().changed_at = first_change;
        report_then_scan(&mut state, program_status(ProgramState::Blocked, Some(BlockedKind::Permission)), false);
        assert_eq!(pi_record(&state).changed_at, first_change);
        report_then_scan(&mut state, program_status(ProgramState::Blocked, Some(BlockedKind::Auth)), false);
        assert_ne!(pi_record(&state).changed_at, first_change);
    }

    #[test]
    fn relay_attachment_never_replaces_an_existing_pipe_on_real_tmux() {
        let server = IsolatedTmuxServer::start("program-relay");
        let directory = server.socket_path.parent().unwrap().join("relay dir#'x");
        fs::create_dir_all(&directory).unwrap();
        let relay = directory.join("relay bin");
        // The marker stays outside the hostile directory so the generated
        // script needs no quoting; only the relay path exercises escaping.
        let marker = server.socket_path.parent().unwrap().join("started");
        let script = format!(
            "#!/bin/sh\nprintf '%s|%s|%s' \"$1\" \"$2\" \"$TMUX\" > '{}'\nexec cat >/dev/null\n",
            marker.display()
        );
        fs::write(&relay, script).unwrap();
        fs::set_permissions(&relay, fs::Permissions::from_mode(0o755)).unwrap();
        let relayed_pane = server.run(&["display-message", "-p", "#{pane_id}"]);
        let user_pane = server.run(&["split-window", "-d", "-P", "-F", "#{pane_id}"]);
        let user_pipe = server.socket_path.parent().unwrap().join("user");
        let user_command = format!("cat > '{}'", user_pipe.display());
        server.run(&["pipe-pane", "-O", "-t", &user_pane, &user_command]);

        let arguments =
            program_status_relay_arguments(server.socket(), &relay, &[&relayed_pane, &user_pane]);
        let output = Command::new("tmux").args(&arguments).output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));

        for _ in 0..50 {
            if marker.exists() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let started = fs::read_to_string(&marker).unwrap();
        let server_pid = server.run(&["display-message", "-p", "#{pid}"]);
        let expected = format!("program-status-relay|{relayed_pane}|{},{server_pid},0", server.socket());
        assert_eq!(started, expected);
        assert_eq!(server.run(&["display-message", "-p", "-t", &user_pane, "#{pane_pipe}"]), "1");
        server.run(&["send-keys", "-t", &user_pane, "echo still-user-pipe", "Enter"]);
        for _ in 0..50 {
            if fs::read_to_string(&user_pipe).unwrap_or_default().contains("still-user-pipe") {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        panic!("the user's pipe-pane command was replaced");
    }

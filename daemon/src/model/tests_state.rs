    fn center() -> StateCenter {
        StateCenter::new("/nonexistent".into(), Config::test())
    }

    fn report(
        tool: &str,
        pane_id: &str,
        generation: &str,
        sequence: u64,
        state: AgentState,
        session_id: &str,
        session_name: &str,
    ) -> Request {
        Request::Report {
            tool: tool.into(),
            pane_id: pane_id.into(),
            process_generation: generation.into(),
            sequence,
            state,
            session_id: session_id.into(),
            session_name: session_name.into(),
        }
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

    // @acceptance-id:unseen-completion
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
            .apply(report("custom", "%1", "g", 2, AgentState::Working, "$1", "work"))
            .unwrap();
        state
            .apply(report("custom", "%1", "g", 1, AgentState::Done, "$1", "work"))
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
            let result = state.apply(report(tool, "%1", "g", 1, AgentState::Working, "$1", "work"));
            assert!(result.is_err());
            assert!(state.agents.is_empty());
        }
    }

    #[test]
    fn pane_reuse_drops_old_generation() {
        let mut state = center();
        for generation in ["a", "b"] {
            state
                .apply(report("custom", "%1", generation, 1, AgentState::Idle, "$1", "work"))
                .unwrap();
        }
        state
            .apply(report("custom", "%1", "a", 2, AgentState::Done, "$1", "work"))
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
            .apply(report("custom", "%1", "g", 1, AgentState::Done, "$1", "work"))
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
                .apply(report("custom", pane, generation, 1, AgentState::Working, session_id, "agent-reused"))
                .unwrap();
        }

        state
            .apply(Request::Exited {
                pane_id: None,
                session_id: Some("$1".into()),
            })
            .unwrap();
        state
            .apply(report("custom", "%2", "new", 2, AgentState::Done, "$2", "agent-reused"))
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
                .apply(report("custom", pane, generation, 1, AgentState::Working, session_id, "agent-reused"))
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
            .apply(report("custom", "%1", "generation", 1, AgentState::Working, "$1", "agent-old"))
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
            .apply(report("custom", "%1", "generation", 2, AgentState::Done, "$2", "agent-new"))
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

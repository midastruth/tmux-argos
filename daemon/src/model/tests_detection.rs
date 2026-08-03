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
        let golden = include_str!("../../fixtures/golden/pi-working.txt");
        assert_eq!(detect_pi(golden).state, AgentState::Working);
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
        let golden = include_str!("../../fixtures/golden/codex-blocked.txt");
        assert_eq!(detect_codex("", golden).state, AgentState::Blocked);
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
        let golden = include_str!("../../fixtures/golden/claude-blocked.txt");
        assert_eq!(detect_claude("", golden).state, AgentState::Blocked);
    }

    #[test]
    fn empty_state_snapshot_matches_the_reviewed_contract() {
        let expected: Value = serde_json::from_str(include_str!(
            "../../fixtures/snapshots/empty-state.json"
        ))
        .unwrap();
        assert_eq!(center().snapshot(), expected);
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

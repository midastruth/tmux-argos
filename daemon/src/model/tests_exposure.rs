    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    fn exposure_pane() -> PaneRow {
        PaneRow {
            session_name: "agent-pi-project-1".into(),
            session_id: "$1".into(),
            session_attached: true,
            window_id: "@2".into(),
            window_index: 0,
            window_name: "editor\tmain".into(),
            window_activity: 100,
            window_active: true,
            pane_id: "%3".into(),
            pane_index: 1,
            command: "pi".into(),
            current_path: "/tmp/project\nname".into(),
            pane_pid: 123,
            pane_title: "agent \"title\"".into(),
            configured_tool: "pi".into(),
            pane_active: true,
            visible: true,
            popup_host: None,
            popup_active: false,
        }
    }

    fn exposure_config(mode: ExposureMode, path: Option<PathBuf>) -> Config {
        let mut config = Config::test();
        config.status_enabled = false;
        config.state_exposure = mode;
        config.state_file = path;
        config
    }

    #[test]
    fn state_exposure_defaults_both_and_validates_modes_and_file_paths() {
        let default = Config::from_values(&HashMap::new()).unwrap();
        assert_eq!(default.state_exposure, ExposureMode::Both);

        for (text, expected) in [
            ("off", ExposureMode::Off),
            ("file", ExposureMode::File),
            ("socket", ExposureMode::Socket),
            ("both", ExposureMode::Both),
        ] {
            let values = config_values(&[
                ("@agent_state_exposure", text.into()),
                ("@agent_state_file", "/tmp/argos-state.json".into()),
            ]);
            assert_eq!(Config::from_values(&values).unwrap().state_exposure, expected);
        }

        let invalid_mode = config_values(&[("@agent_state_exposure", "push".into())]);
        assert!(Config::from_values(&invalid_mode).is_err());
        let relative_file = config_values(&[
            ("@agent_state_exposure", "file".into()),
            ("@agent_state_file", "relative/state.json".into()),
        ]);
        assert!(Config::from_values(&relative_file).is_err());
    }

    #[test]
    fn pane_parser_preserves_common_separators_and_rejects_boundary_injection() {
        let separator = PANE_FIELD_SEPARATOR;
        let mut fields = [
            "work",
            "$1",
            "1",
            "@2",
            "0",
            "editor\tmain",
            "100",
            "1",
            "%3",
            "1",
            "pi",
            "/tmp/project\nname",
            "123",
            "title",
            "pi",
            "1",
            "",
            "",
            "",
            "",
            "",
        ];
        let record = fields.join(&separator.to_string());
        let pane = parse_pane_record(&record).unwrap();
        assert_eq!(pane.window_name, "editor\tmain");
        assert_eq!(pane.current_path, "/tmp/project\nname");
        assert!(pane.visible);
        assert!(pane.popup_host.is_none());
        assert!(!pane.popup_active);

        fields[16] = "/dev/pts/1";
        fields[17] = "$0";
        fields[18] = "@38";
        fields[19] = "%41";
        fields[20] = "on";
        let popup_pane = parse_pane_record(&fields.join(&separator.to_string())).unwrap();
        assert!(popup_pane.popup_active);
        let popup_host = popup_pane.popup_host.unwrap();
        assert_eq!(popup_host.client, "/dev/pts/1");
        assert_eq!(popup_host.session_id, "$0");
        assert_eq!(popup_host.window_id, "@38");
        assert_eq!(popup_host.pane_id, "%41");

        let injected = record.replacen("editor\tmain", "bad\u{1f}field", 1);
        assert!(parse_pane_record(&injected).is_none());
        let invalid_identity = record.replacen("%3", "$3", 1);
        assert!(parse_pane_record(&invalid_identity).is_none());
    }

    #[test]
    fn inspect_exposes_structured_tmux_topology_and_authoritative_agent_state() {
        let mut state = StateCenter::new(
            "/nonexistent".into(),
            exposure_config(ExposureMode::Socket, None),
        );
        state.pane_rows = vec![exposure_pane()];
        state
            .apply(report(
                "pi-helper",
                "%3",
                "generation",
                1,
                AgentState::Working,
                "$1",
                "agent-pi-project-1",
            ))
            .unwrap();

        let snapshot = state.inspect().unwrap();
        let pane = &snapshot["panes"][0];
        assert_eq!(snapshot["schemaVersion"], 2);
        assert_eq!(pane["sessionName"], "agent-pi-project-1");
        assert_eq!(pane["windowName"], "editor\tmain");
        assert_eq!(pane["paneIndex"], 1);
        assert_eq!(pane["command"], "pi");
        assert_eq!(pane["currentPath"], "/tmp/project\nname");
        assert_eq!(pane["agent"], "pi-helper");
        assert_eq!(pane["activity"], "active");
        assert_eq!(pane["agentState"], "working");
        assert_eq!(pane["visible"], true);
        assert!(pane["popupHost"].is_null());
        assert_eq!(pane["popupActive"], false);
        assert!(serde_json::to_string(&snapshot).unwrap().contains("editor\\tmain"));
    }

    #[test]
    fn state_exposure_distinguishes_active_and_background_popup_agents() {
        let mut state = StateCenter::new(
            "/nonexistent".into(),
            exposure_config(ExposureMode::Socket, None),
        );
        let mut pane = exposure_pane();
        pane.popup_host = Some(PopupHost {
            client: "/dev/pts/1".into(),
            session_id: "$0".into(),
            window_id: "@38".into(),
            pane_id: "%41".into(),
        });
        state.pane_rows = vec![pane];

        let background = state.inspect().unwrap();
        assert_eq!(background["panes"][0]["popupActive"], false);
        state.pane_rows[0].popup_active = true;
        let active = state.inspect().unwrap();
        assert_eq!(active["panes"][0]["popupActive"], true);
        let popup_host = &active["panes"][0]["popupHost"];
        assert_eq!(popup_host["client"], "/dev/pts/1");
        assert_eq!(popup_host["sessionId"], "$0");
        assert_eq!(popup_host["windowId"], "@38");
        assert_eq!(popup_host["paneId"], "%41");
    }

    #[test]
    fn inspect_distinguishes_recognized_agents_without_state_from_non_agents() {
        let mut state = StateCenter::new(
            "/nonexistent".into(),
            exposure_config(ExposureMode::Socket, None),
        );
        state.pane_rows = vec![exposure_pane()];
        let recognized = state.inspect().unwrap();
        assert_eq!(recognized["panes"][0]["agent"], "pi");
        assert!(recognized["panes"][0]["agentState"].is_null());
        assert_eq!(recognized["panes"][0]["activity"], "idle");

        state.pane_rows[0].session_name = "work".into();
        state.pane_rows[0].command = "bash".into();
        state.pane_rows[0].configured_tool.clear();
        let non_agent = state.inspect().unwrap();
        assert!(non_agent["panes"][0]["agent"].is_null());
        assert!(non_agent["panes"][0]["agentState"].is_null());
        assert_eq!(non_agent["panes"][0]["activity"], "idle");
    }

    #[test]
    fn detailed_agent_states_map_to_stable_active_and_idle_activity() {
        for (agent_state, expected_activity) in [
            (AgentState::Blocked, "active"),
            (AgentState::Working, "active"),
            (AgentState::Done, "idle"),
            (AgentState::Idle, "idle"),
        ] {
            let mut state = StateCenter::new(
                "/nonexistent".into(),
                exposure_config(ExposureMode::Socket, None),
            );
            state.pane_rows = vec![exposure_pane()];
            state
                .apply(report(
                    "custom",
                    "%3",
                    "generation",
                    1,
                    agent_state,
                    "$1",
                    "agent-pi-project-1",
                ))
                .unwrap();
            assert_eq!(
                state.inspect().unwrap()["panes"][0]["activity"],
                expected_activity
            );
        }
    }

    #[test]
    fn socket_inspection_is_available_only_for_socket_exposure_modes() {
        for mode in [ExposureMode::Off, ExposureMode::File] {
            let state = StateCenter::new("/nonexistent".into(), exposure_config(mode, None));
            assert!(state.inspect().is_err());
        }
        for mode in [ExposureMode::Socket, ExposureMode::Both] {
            let state = StateCenter::new("/nonexistent".into(), exposure_config(mode, None));
            assert!(state.inspect().is_ok());
        }
    }

    #[test]
    fn file_exposure_is_private_atomic_and_skips_unchanged_snapshots() {
        let directory = std::env::temp_dir().join(format!(
            "tmux-argos-exposure-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = directory.join("state.json");
        let mut state = StateCenter::new(
            "/nonexistent".into(),
            exposure_config(ExposureMode::File, Some(path.clone())),
        );
        state.pane_rows = vec![exposure_pane()];

        assert!(state.publish_exposure_file().unwrap());
        let first = fs::read_to_string(&path).unwrap();
        assert!(!state.publish_exposure_file().unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), first);
        #[cfg(unix)]
        {
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
            assert_eq!(
                fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        assert!(fs::read_dir(&directory)
            .unwrap()
            .all(|entry| entry.unwrap().path() == path));

        state.pane_rows[0].window_name = "renamed".into();
        assert!(state.publish_exposure_file().unwrap());
        let updated: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(updated["panes"][0]["windowName"], "renamed");

        state.replace_config(exposure_config(ExposureMode::Socket, None));
        assert!(!path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

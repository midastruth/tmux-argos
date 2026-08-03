    fn config_values(entries: &[(&str, String)]) -> HashMap<String, String> {
        entries
            .iter()
            .map(|(name, value)| ((*name).to_string(), value.clone()))
            .collect()
    }

    #[test]
    fn config_values_use_defaults_only_for_missing_or_empty_entries() {
        let values = config_values(&[
            ("present", "configured".into()),
            ("empty", String::new()),
        ]);
        assert_eq!(config_value(&values, "present", "default"), "configured");
        assert_eq!(config_value(&values, "empty", "default"), "default");
        assert_eq!(config_value(&values, "missing", "default"), "default");
    }

    #[test]
    fn animation_frame_count_and_byte_boundaries_are_enforced() {
        let sixty_four_frames = (0..MAX_FRAMES)
            .map(|index| format!("f{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        let valid = config_values(&[("@agent_status_anim_frames", sixty_four_frames)]);
        assert_eq!(config_frames(&valid, "x").unwrap().len(), MAX_FRAMES);

        let too_many_frames = (0..=MAX_FRAMES)
            .map(|index| format!("f{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        let invalid_count = config_values(&[("@agent_status_anim_frames", too_many_frames)]);
        assert!(config_frames(&invalid_count, "x").is_err());

        let maximum_bytes = config_values(&[("@agent_status_anim_frames", "x".repeat(MAX_FRAME_BYTES))]);
        assert_eq!(config_frames(&maximum_bytes, "x").unwrap(), vec!["x".repeat(MAX_FRAME_BYTES)]);
        let oversized = config_values(&[("@agent_status_anim_frames", "x".repeat(MAX_FRAME_BYTES + 1))]);
        assert!(config_frames(&oversized, "x").is_err());
        let empty = config_values(&[("@agent_status_anim_frames", " ".into())]);
        assert!(config_frames(&empty, "x").is_err());
    }

    #[test]
    fn interval_boundaries_accept_minimums_and_reject_values_below_them() {
        let minimums = config_values(&[
            ("@agent_animation_interval_ms", "250".into()),
            ("@agent_screen_interval_ms", "250".into()),
            ("@agent_screen_full_scan_interval_ms", "250".into()),
        ]);
        assert_eq!(config_intervals(&minimums).unwrap(), (250, 250, 250));

        for option in ["@agent_animation_interval_ms", "@agent_screen_interval_ms"] {
            let below_minimum = config_values(&[(option, "249".into())]);
            assert!(config_intervals(&below_minimum).is_err());
        }
        let faster_full_scan = config_values(&[
            ("@agent_screen_interval_ms", "251".into()),
            ("@agent_screen_full_scan_interval_ms", "250".into()),
        ]);
        assert!(config_intervals(&faster_full_scan).is_err());
    }

    #[test]
    fn boolean_config_flags_have_exact_on_semantics() {
        let values = config_values(&[
            ("@agent_status", "off".into()),
            ("@agent_status_animate_working", "off".into()),
            ("@agent_status_show_idle", "on".into()),
        ]);
        let config = Config::from_values(&values).unwrap();
        assert!(!config.status_enabled);
        assert!(!config.animate_working);
        assert!(config.show_idle);
    }

    fn temporary_file(name: &str, content: &str) -> PathBuf {
        let directory = env::temp_dir().join(format!(
            "tmux-argos-history-test-{}-{}",
            std::process::id(),
            name
        ));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("session.jsonl");
        let mut file = File::create(&path).unwrap();
        file.write_all(content.as_bytes()).unwrap();
        path
    }

    #[test]
    fn parses_pi_session_name_and_metadata() {
        let path = temporary_file(
            "pi",
            "{\"type\":\"session\",\"id\":\"pi-id\",\"cwd\":\"/tmp/pi\"}\n{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"first prompt\"}}\n{\"type\":\"session_info\",\"name\":\"Named work\"}\n",
        );
        let record = parse_pi_record(&path).unwrap();
        assert_eq!(record.session_id, "pi-id");
        assert_eq!(record.cwd, "/tmp/pi");
        assert_eq!(record.title, "Named work");
    }

    #[test]
    fn parses_codex_event_prompt() {
        let path = temporary_file(
            "codex",
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"codex-id\",\"cwd\":\"/tmp/codex\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"ship it\"}}\n",
        );
        let record = parse_codex_record(&path).unwrap();
        assert_eq!(record.session_id, "codex-id");
        assert_eq!(record.title, "ship it");
    }

    #[test]
    fn parses_claude_user_prompt() {
        let path = temporary_file(
            "claude",
            "{\"type\":\"user\",\"sessionId\":\"claude-id\",\"cwd\":\"/tmp/claude\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"review this\"}]}}\n",
        );
        let record = parse_claude_record(&path).unwrap();
        assert_eq!(record.session_id, "claude-id");
        assert_eq!(record.title, "review this");
    }

    #[test]
    fn compacts_multiline_titles() {
        assert_eq!(compact_text("  one\n two\tthree  ", 100), "one two three");
    }

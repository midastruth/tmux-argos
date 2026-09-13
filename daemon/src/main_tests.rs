    #[test]
    fn event_batch_is_bounded_and_checks_deadlines() {
        assert_eq!(EVENT_BATCH_LIMIT, 64);
        let deadline_check_stride = DEADLINE_CHECK_STRIDE;
        assert!(deadline_check_stride > 0);
        assert!(deadline_check_stride < EVENT_BATCH_LIMIT);
    }

    #[test]
    fn inspect_cli_selects_the_public_topology_request() {
        assert!(matches!(state_read_request("inspect"), Request::Inspect));
        assert!(matches!(state_read_request("snapshot"), Request::Snapshot));
    }

    #[test]
    fn inspect_socket_response_rejects_oversized_snapshots_without_truncation() {
        let small = bounded_response(serde_json::json!({"panes": []}));
        assert!(small.ok);

        let large = bounded_response(serde_json::json!({
            "panes": ["x".repeat(protocol::MAX_MESSAGE_BYTES)]
        }));
        assert!(!large.ok);
        assert_eq!(
            large.error.as_deref(),
            Some("inspect snapshot exceeds 64 KiB; use file exposure")
        );
    }

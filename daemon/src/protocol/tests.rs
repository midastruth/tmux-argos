    #[test]
    fn inspect_request_round_trips_as_a_bounded_protocol_message() {
        let encoded = serde_json::to_vec(&Request::Inspect).unwrap();
        assert!(encoded.len() < MAX_MESSAGE_BYTES);
        let decoded: Request = serde_json::from_slice(&encoded).unwrap();
        assert!(matches!(decoded, Request::Inspect));
        assert!(validate_request(&decoded).is_ok());
    }

    #[test]
    fn rejects_bad_pane() {
        let r = Request::Seen {
            pane_id: Some("1".into()),
        };
        assert!(validate_request(&r).is_err());
    }
    #[test]
    fn rejects_empty_identity() {
        let r = Request::Report {
            tool: "pi".into(),
            pane_id: "%1".into(),
            process_generation: "".into(),
            sequence: 1,
            state: AgentState::Idle,
            session_id: "$1".into(),
            session_name: "work".into(),
        };
        assert!(validate_request(&r).is_err());
    }

    #[test]
    fn rejects_oversized_and_delimited_identity_fields() {
        let oversized = Request::Report {
            tool: "pi".into(),
            pane_id: "%1".into(),
            process_generation: "x".repeat(MAX_FIELD_BYTES + 1),
            sequence: 1,
            state: AgentState::Idle,
            session_id: "$1".into(),
            session_name: "work".into(),
        };
        assert!(validate_request(&oversized).is_err());
        let delimited = Request::Report {
            tool: "pi".into(),
            pane_id: "%1".into(),
            process_generation: "bad\tname".into(),
            sequence: 1,
            state: AgentState::Idle,
            session_id: "$1".into(),
            session_name: "work".into(),
        };
        assert!(validate_request(&delimited).is_err());
    }

    #[test]
    fn rejects_invalid_session_id() {
        let request = Request::Exited {
            pane_id: None,
            session_id: Some("agent-one".into()),
        };
        assert!(validate_request(&request).is_err());
    }

    #[test]
    fn rejects_identifiers_that_are_only_a_prefix() {
        // "$"/"%" carry no tmux instance number, so accepting them lets a client
        // register records under an identity that can never match a real pane or
        // session, corrupting snapshots and picker joins.
        for pane_id in ["%", "$"] {
            let request = Request::Seen {
                pane_id: Some(pane_id.into()),
            };
            assert!(
                validate_request(&request).is_err(),
                "pane_id {pane_id:?} must be rejected"
            );
        }

        let exited = Request::Exited {
            pane_id: None,
            session_id: Some("$".into()),
        };
        assert!(validate_request(&exited).is_err());

        let report = Request::Report {
            tool: "custom".into(),
            pane_id: "%".into(),
            process_generation: "g".into(),
            sequence: 1,
            state: AgentState::Idle,
            session_id: "$".into(),
            session_name: "work".into(),
        };
        assert!(validate_request(&report).is_err());
    }

    #[test]
    fn generated_identifier_boundaries_preserve_the_protocol_invariant() {
        for number in 0..10_000u64 {
            let valid = Request::Exited {
                pane_id: Some(format!("%{number}")),
                session_id: Some(format!("${number}")),
            };
            assert!(validate_request(&valid).is_ok());

            for invalid in [
                format!("{number}"),
                format!("%-{number}"),
                format!("%{number}x"),
            ] {
                let request = Request::Seen {
                    pane_id: Some(invalid),
                };
                assert!(validate_request(&request).is_err());
            }
        }
    }

    fn report_with_generation(process_generation: String) -> Request {
        Request::Report {
            tool: "custom".into(),
            pane_id: "%1".into(),
            process_generation,
            sequence: 1,
            state: AgentState::Idle,
            session_id: "$1".into(),
            session_name: "work".into(),
        }
    }

    fn stream_containing(bytes: Vec<u8>) -> UnixStream {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        std::thread::spawn(move || writer.write_all(&bytes).unwrap());
        reader
    }

    fn request_with_wire_size(size: usize) -> Request {
        let fixed_size = serde_json::to_vec(&report_with_generation(String::new()))
            .unwrap()
            .len()
            + 1;
        report_with_generation("x".repeat(size - fixed_size))
    }

    fn response_with_wire_size(size: usize) -> Response {
        let fixed_size = serde_json::to_vec(&Response::ok(Some(Value::String(String::new()))))
            .unwrap()
            .len()
            + 1;
        Response::ok(Some(Value::String("x".repeat(size - fixed_size))))
    }

    fn drain_peer(mut peer: UnixStream) {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = peer.read_to_end(&mut bytes);
        });
    }

    #[test]
    fn protocol_size_and_identity_boundaries_are_exact() {
        assert_eq!(MAX_MESSAGE_BYTES, 65_536);
        assert!(validate_request(&report_with_generation("x".repeat(MAX_FIELD_BYTES))).is_ok());
        assert!(
            validate_request(&report_with_generation("x".repeat(MAX_FIELD_BYTES + 1))).is_err()
        );

        let pane_only = Request::Exited {
            pane_id: Some("%1".into()),
            session_id: None,
        };
        let session_only = Request::Exited {
            pane_id: None,
            session_id: Some("$1".into()),
        };
        let neither = Request::Exited {
            pane_id: None,
            session_id: None,
        };
        assert!(validate_request(&pane_only).is_ok());
        assert!(validate_request(&session_only).is_ok());
        assert!(validate_request(&neither).is_err());
    }

    #[test]
    fn bounded_reader_accepts_the_limit_and_rejects_adjacent_sizes() {
        let mut exact = vec![b'x'; MAX_MESSAGE_BYTES - 1];
        exact.push(b'\n');
        assert_eq!(
            read_bounded(&mut stream_containing(exact)).unwrap().len(),
            MAX_MESSAGE_BYTES
        );

        let oversized = vec![b'x'; MAX_MESSAGE_BYTES + 1];
        assert!(read_bounded(&mut stream_containing(oversized)).is_err());
        let (mut empty_reader, empty_writer) = UnixStream::pair().unwrap();
        drop(empty_writer);
        assert!(read_bounded(&mut empty_reader).is_err());
    }

    #[test]
    fn request_and_response_writers_enforce_bounds_and_round_trip() {
        let request = report_with_generation("g".into());
        let (mut request_reader, mut request_writer) = UnixStream::pair().unwrap();
        request_reader
            .set_read_timeout(Some(std::time::Duration::from_millis(100)))
            .unwrap();
        write_request(&mut request_writer, &request).unwrap();
        assert!(matches!(
            read_request(&mut request_reader),
            Ok(Request::Report { .. })
        ));

        let (mut boundary_writer, boundary_reader) = UnixStream::pair().unwrap();
        drain_peer(boundary_reader);
        assert!(write_request(
            &mut boundary_writer,
            &request_with_wire_size(MAX_MESSAGE_BYTES)
        )
        .is_ok());
        assert!(write_request(
            &mut boundary_writer,
            &request_with_wire_size(MAX_MESSAGE_BYTES + 1)
        )
        .is_err());
        assert!(write_response(
            &mut boundary_writer,
            &response_with_wire_size(MAX_MESSAGE_BYTES)
        )
        .is_ok());
        assert!(write_response(
            &mut boundary_writer,
            &response_with_wire_size(MAX_MESSAGE_BYTES + 1)
        )
        .is_err());
    }

    fn mutate_payload(payload: &[u8], state: &mut u64) -> Vec<u8> {
        *state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1);
        let mut mutated = payload.to_vec();
        let index = (*state as usize) % mutated.len();
        mutated[index] = ((*state >> 32) & 0xff) as u8;
        mutated
    }

    #[test]
    fn one_hundred_thousand_fuzzed_protocol_payloads_do_not_panic() {
        let seed = br#"{"type":"Report","tool":"custom","pane_id":"%1","process_generation":"g","sequence":1,"state":"idle","session_id":"$1","session_name":"work"}"#;
        let mut state = 0x5eed_u64;
        let mut parsed_count = 0usize;
        for _ in 0..100_000 {
            let payload = mutate_payload(seed, &mut state);
            if let Ok(request) = serde_json::from_slice::<Request>(&payload) {
                let _ = validate_request(&request);
                parsed_count += 1;
            }
        }
        assert!(
            parsed_count > 0,
            "the mutation corpus must exercise validation"
        );
    }

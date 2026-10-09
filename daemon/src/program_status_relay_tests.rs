fn scan_all(bytes: &[u8]) -> Vec<Vec<u8>> {
    let mut scanner = OscScanner::new();
    bytes.iter().filter_map(|byte| scanner.push(*byte)).collect()
}

/// Relays `bytes`, checks the mandatory final withdrawal, and returns the
/// reports forwarded before it.
fn relayed(bytes: &[u8]) -> Vec<Request> {
    let mut requests = Vec::new();
    relay("%7", bytes, |request| requests.push(request)).unwrap();
    let last = requests.pop().expect("a relay always withdraws its report");
    assert_eq!(status_of(&last), (None, ProgramState::Clear, None));
    requests
}

fn status_of(request: &Request) -> (Option<&str>, ProgramState, Option<BlockedKind>) {
    match request {
        Request::ProgramStatus {
            pane_id,
            app,
            state,
            kind,
        } => {
            assert_eq!(pane_id, "%7");
            (app.as_deref(), *state, *kind)
        }
        other => panic!("unexpected request {other:?}"),
    }
}

#[test]
fn scanner_accepts_both_osc_terminators_and_ignores_surrounding_output() {
    let bodies = scan_all(b"plain\x1b[1mtext\x1b]7501;state=working\x1b\\more\x1b]0;title\x07");
    assert_eq!(bodies, vec![b"7501;state=working".to_vec(), b"0;title".to_vec()]);
}

#[test]
fn scanner_reassembles_a_sequence_split_at_every_byte() {
    let mut scanner = OscScanner::new();
    let mut completed = Vec::new();
    for chunk in b"\x1b]7501;state=done\x1b\\".chunks(1) {
        completed.extend(scanner.push(chunk[0]));
    }
    assert_eq!(completed, vec![b"7501;state=done".to_vec()]);
}

#[test]
fn scanner_drops_aborted_and_oversized_osc_strings() {
    assert!(scan_all(b"\x1b]7501;state=working\x18\x1b\\").is_empty());
    assert!(scan_all(b"\x1b]7501;state=working\x1a\x07").is_empty());
    let interrupted = scan_all(b"\x1b]7501;state=working\x1b]7501;state=idle\x07");
    assert_eq!(interrupted, vec![b"7501;state=idle".to_vec()]);

    let mut oversized = b"\x1b]7501;".to_vec();
    oversized.extend(std::iter::repeat_n(b'x', MAX_OSC_BYTES));
    oversized.extend(b"\x07\x1b]7501;state=idle\x07");
    assert_eq!(scan_all(&oversized), vec![b"7501;state=idle".to_vec()]);

    let mut exact = b"\x1b]".to_vec();
    exact.extend(std::iter::repeat_n(b'y', MAX_OSC_BYTES));
    exact.push(BELL);
    assert_eq!(scan_all(&exact)[0].len(), MAX_OSC_BYTES);
}

#[test]
fn relay_forwards_pi_states_kind_and_app_without_messages() {
    let requests = relayed(
        b"\x1b]7501;state=working:app=pi:msg=c2Vzc2lvbg==\x1b\\\
          \x1b]7501;state=blocked:app=pi:kind=auth:msg=TG9n\x1b\\\
          \x1b]7501;state=error:app=pi\x07\x1b]7501;state=clear\x1b\\",
    );
    let statuses: Vec<_> = requests.iter().map(status_of).collect();
    assert_eq!(
        statuses,
        vec![
            (Some("pi"), ProgramState::Working, None),
            (Some("pi"), ProgramState::Blocked, Some(BlockedKind::Auth)),
            (Some("pi"), ProgramState::Error, None),
            (None, ProgramState::Clear, None),
        ]
    );
    assert!(!serde_json::to_string(&requests).unwrap().contains("msg"));
}

#[test]
fn relay_ignores_queries_child_records_and_unrelated_osc() {
    let requests = relayed(
        b"\x1b]7501;?\x1b\\\x1b]7501;state=working:id=sub\x1b\\\
          \x1b]7501;state=clear:id=sub\x1b\\\x1b]75011;state=done\x07\
          \x1b]7501;state=paused\x07\x1b]8;;state=done\x07\x1b]7501;app=pi\x07",
    );
    assert!(requests.is_empty(), "{requests:?}");
}

#[test]
fn relay_drops_invalid_apps_and_unknown_or_misplaced_kinds() {
    let requests = relayed(
        b"\x1b]7501;state=working:app=bad/app\x07\
          \x1b]7501;state=blocked:kind=elsewhere\x07\
          \x1b]7501;state=working:kind=auth\x07\
          \x1b]7501;state=blocked:kind=permission\x07\
          \x1b]7501;state=blocked:kind=question\x07",
    );
    let statuses: Vec<_> = requests.iter().map(status_of).collect();
    assert_eq!(
        statuses,
        vec![
            (None, ProgramState::Blocked, None),
            (None, ProgramState::Working, None),
            (None, ProgramState::Blocked, Some(BlockedKind::Permission)),
            (None, ProgramState::Blocked, Some(BlockedKind::Question)),
        ]
    );
}

#[test]
fn every_program_state_name_maps_to_its_protocol_state() {
    for (name, state) in [
        ("idle", ProgramState::Idle),
        ("working", ProgramState::Working),
        ("blocked", ProgramState::Blocked),
        ("done", ProgramState::Done),
        ("error", ProgramState::Error),
        ("clear", ProgramState::Clear),
    ] {
        let body = format!("7501;state={name}");
        let request = program_status_request("%7", body.as_bytes()).unwrap();
        assert_eq!(status_of(&request).1, state);
    }
    assert!(program_status_request("%7", b"7501;state=done:app=pi").is_some());
    assert!(program_status_request("bad", b"7501;state=done").is_none());
    assert!(program_status_request("%7", b"7501;state=\xff").is_none());
}

struct FailingReader;

impl Read for FailingReader {
    fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::other("closed pipe"))
    }
}

#[test]
fn relay_reports_read_errors_after_withdrawing_its_report() {
    let mut requests = Vec::new();
    assert!(relay("%7", FailingReader, |request| requests.push(request)).is_err());
    let statuses: Vec<_> = requests.iter().map(status_of).collect();
    assert_eq!(statuses, vec![(None, ProgramState::Clear, None)]);
}

#[test]
fn replaced_or_closed_relay_stream_withdraws_the_last_report() {
    // A user pipe-pane replaces the relay by closing its stdin while keeping
    // pane_pipe set; the final clear is the daemon's only signal.
    let mut requests = Vec::new();
    relay("%7", &b"\x1b]7501;state=working:app=pi\x07"[..], |request| {
        requests.push(request)
    })
    .unwrap();
    let statuses: Vec<_> = requests.iter().map(status_of).collect();
    assert_eq!(
        statuses,
        vec![
            (Some("pi"), ProgramState::Working, None),
            (None, ProgramState::Clear, None),
        ]
    );
}

#[test]
fn scanner_rejects_one_byte_over_the_limit_and_restarts_on_repeated_escape() {
    let mut over_limit = b"\x1b]".to_vec();
    over_limit.extend(std::iter::repeat_n(b'z', MAX_OSC_BYTES + 1));
    over_limit.push(BELL);
    assert!(scan_all(&over_limit).is_empty());
    assert_eq!(
        scan_all(b"\x1b\x1b]7501;state=idle\x07"),
        vec![b"7501;state=idle".to_vec()]
    );
}

struct InterruptedOnceReader {
    interrupted: bool,
    data: &'static [u8],
}

impl Read for InterruptedOnceReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if !self.interrupted {
            self.interrupted = true;
            return Err(io::Error::from(io::ErrorKind::Interrupted));
        }
        let length = self.data.len().min(buffer.len());
        buffer[..length].copy_from_slice(&self.data[..length]);
        self.data = &self.data[length..];
        Ok(length)
    }
}

#[test]
fn relay_retries_interrupted_reads() {
    let reader = InterruptedOnceReader {
        interrupted: false,
        data: b"\x1b]7501;state=working\x07",
    };
    let mut requests = Vec::new();
    relay("%7", reader, |request| requests.push(request)).unwrap();
    let states: Vec<_> = requests.iter().map(|request| status_of(request).1).collect();
    assert_eq!(states, vec![ProgramState::Working, ProgramState::Clear]);
}

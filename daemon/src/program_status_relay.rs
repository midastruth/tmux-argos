//! Relays OSC 7501 program status records from one pane's raw output stream.
//!
//! tmux discards OSC 7501 in its own terminal parser, so the daemon attaches
//! this relay with `pipe-pane -O`, which receives the pane's bytes before tmux
//! interprets them. The relay only forwards structured states; it never
//! forwards status messages or other pane output.

use crate::protocol::{validate_request, BlockedKind, ProgramState, Request};
use std::io::{self, Read};

const ESCAPE: u8 = 0x1b;
const BELL: u8 = 0x07;
const CANCEL: u8 = 0x18;
const SUBSTITUTE: u8 = 0x1a;
/// Bounds memory for OSC strings that never terminate. OSC 7501 reports are a
/// few hundred bytes; longer OSC bodies (titles, hyperlinks) are not needed.
const MAX_OSC_BYTES: usize = 8192;
const PROGRAM_STATUS_PREFIX: &str = "7501;";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ScanState {
    Ground,
    Escape,
    Osc,
    OscEscape,
}

/// Incremental OSC string scanner that tolerates sequences split across reads.
pub struct OscScanner {
    state: ScanState,
    body: Vec<u8>,
    overflowed: bool,
}

impl OscScanner {
    pub fn new() -> Self {
        Self {
            state: ScanState::Ground,
            body: Vec::new(),
            overflowed: false,
        }
    }

    fn start_osc(&mut self) {
        self.state = ScanState::Osc;
        self.body.clear();
        self.overflowed = false;
    }

    /// Returns the body of a complete, in-bounds OSC string ended by this byte.
    fn finish_osc(&mut self) -> Option<Vec<u8>> {
        self.state = ScanState::Ground;
        if self.overflowed {
            return None;
        }
        Some(std::mem::take(&mut self.body))
    }

    fn push_osc_byte(&mut self, byte: u8) {
        if self.body.len() < MAX_OSC_BYTES {
            self.body.push(byte);
        } else {
            self.overflowed = true;
        }
    }

    fn scan_escape(&mut self, byte: u8) {
        match byte {
            b']' => self.start_osc(),
            ESCAPE => self.state = ScanState::Escape,
            _ => self.state = ScanState::Ground,
        }
    }

    fn scan_osc(&mut self, byte: u8) -> Option<Vec<u8>> {
        match byte {
            BELL => return self.finish_osc(),
            ESCAPE => self.state = ScanState::OscEscape,
            CANCEL | SUBSTITUTE => self.state = ScanState::Ground,
            _ => self.push_osc_byte(byte),
        }
        None
    }

    /// Feeds one output byte and returns a completed OSC body, if any.
    pub fn push(&mut self, byte: u8) -> Option<Vec<u8>> {
        match self.state {
            ScanState::Ground => {
                if byte == ESCAPE {
                    self.state = ScanState::Escape;
                }
                None
            }
            ScanState::Escape => {
                self.scan_escape(byte);
                None
            }
            ScanState::Osc => self.scan_osc(byte),
            ScanState::OscEscape => {
                if byte == b'\\' {
                    return self.finish_osc();
                }
                // ESC followed by anything else aborts the OSC string and
                // begins a new escape sequence.
                self.scan_escape(byte);
                None
            }
        }
    }
}

fn parse_program_state(value: &str) -> Option<ProgramState> {
    match value {
        "idle" => Some(ProgramState::Idle),
        "working" => Some(ProgramState::Working),
        "blocked" => Some(ProgramState::Blocked),
        "done" => Some(ProgramState::Done),
        "error" => Some(ProgramState::Error),
        "clear" => Some(ProgramState::Clear),
        _ => None,
    }
}

fn parse_blocked_kind(value: &str) -> Option<BlockedKind> {
    match value {
        "permission" => Some(BlockedKind::Permission),
        "question" => Some(BlockedKind::Question),
        "auth" => Some(BlockedKind::Auth),
        _ => None,
    }
}

#[derive(Default)]
struct ProgramFields<'a> {
    state: Option<&'a str>,
    app: Option<&'a str>,
    kind: Option<&'a str>,
    has_record_id: bool,
}

fn program_fields(payload: &str) -> ProgramFields<'_> {
    let mut fields = ProgramFields::default();
    for pair in payload.split(':') {
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        match key {
            "state" => fields.state = Some(value),
            "app" => fields.app = Some(value),
            "kind" => fields.kind = Some(value),
            "id" => fields.has_record_id = true,
            _ => {}
        }
    }
    fields
}

/// Converts one OSC body into a status request for `pane_id`. Support queries,
/// child records (`id=`), unknown states, and invalid fields are ignored; an
/// unknown blocking reason keeps the blocked state without a reason.
pub fn program_status_request(pane_id: &str, osc_body: &[u8]) -> Option<Request> {
    let text = std::str::from_utf8(osc_body).ok()?;
    let payload = text.strip_prefix(PROGRAM_STATUS_PREFIX)?;
    let fields = program_fields(payload);
    if fields.has_record_id {
        return None;
    }
    let state = parse_program_state(fields.state?)?;
    let kind = match state {
        ProgramState::Blocked => fields.kind.and_then(parse_blocked_kind),
        _ => None,
    };
    let request = Request::ProgramStatus {
        pane_id: pane_id.to_string(),
        app: fields.app.map(str::to_string),
        state,
        kind,
    };
    validate_request(&request).ok()?;
    Some(request)
}

/// Reads `input` until end of stream and passes each status request to `send`.
/// Delivery failures are left to the caller: the next report carries the full
/// state again, so a dropped report is corrected without replay.
pub fn relay(pane_id: &str, mut input: impl Read, mut send: impl FnMut(Request)) -> io::Result<()> {
    let mut scanner = OscScanner::new();
    let mut buffer = [0u8; 4096];
    loop {
        let read = match input.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        for byte in &buffer[..read] {
            let Some(body) = scanner.push(*byte) else {
                continue;
            };
            if let Some(request) = program_status_request(pane_id, &body) {
                send(request);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    include!("program_status_relay_tests.rs");
}

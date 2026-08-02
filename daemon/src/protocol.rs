use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;

pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_FIELD_BYTES: usize = 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Request {
    Report {
        tool: String,
        pane_id: String,
        process_generation: String,
        sequence: u64,
        state: AgentState,
        session_id: String,
        session_name: String,
    },
    Seen {
        pane_id: Option<String>,
    },
    Exited {
        pane_id: Option<String>,
        session_id: Option<String>,
    },
    ReloadConfig,
    Shutdown,
    Snapshot,
    Ensure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentState {
    Blocked,
    Working,
    Done,
    Idle,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
impl Response {
    pub fn ok(data: Option<Value>) -> Self {
        Self {
            ok: true,
            data,
            error: None,
        }
    }
    pub fn error(error: String) -> Self {
        Self {
            ok: false,
            data: None,
            error: Some(error),
        }
    }
}

pub fn validate_request(request: &Request) -> Result<(), String> {
    fn field(name: &str, value: &str) -> Result<(), String> {
        if value.is_empty()
            || value.len() > MAX_FIELD_BYTES
            || value
                .bytes()
                .any(|b| b == 0 || b == b'\n' || b == b'\r' || b == b'\t')
        {
            return Err(format!("invalid {name}"));
        }
        Ok(())
    }
    fn pane(value: &str) -> Result<(), String> {
        field("pane_id", value)?;
        if !value.starts_with('%') || !value[1..].bytes().all(|b| b.is_ascii_digit()) {
            return Err("invalid pane_id".into());
        }
        Ok(())
    }
    fn session(value: &str) -> Result<(), String> {
        field("session_id", value)?;
        if !value.starts_with('$') || !value[1..].bytes().all(|b| b.is_ascii_digit()) {
            return Err("invalid session_id".into());
        }
        Ok(())
    }
    match request {
        Request::Report {
            tool,
            pane_id,
            process_generation,
            session_id,
            session_name,
            ..
        } => {
            field("tool", tool)?;
            pane(pane_id)?;
            field("process_generation", process_generation)?;
            session(session_id)?;
            field("session_name", session_name)?;
        }
        Request::Seen { pane_id } => {
            if pane_id.is_none() {
                return Err("Seen needs pane_id".into());
            }
            if let Some(value) = pane_id {
                pane(value)?;
            }
        }
        Request::Exited {
            pane_id,
            session_id,
        } => {
            if pane_id.is_none() && session_id.is_none() {
                return Err("Exited needs pane_id or session_id".into());
            }
            if let Some(value) = pane_id {
                pane(value)?;
            }
            if let Some(value) = session_id {
                session(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn read_bounded(stream: &mut UnixStream) -> io::Result<Vec<u8>> {
    let mut reader = BufReader::new(stream);
    let mut bytes = Vec::new();
    let read = reader
        .by_ref()
        .take((MAX_MESSAGE_BYTES + 1) as u64)
        .read_until(b'\n', &mut bytes)?;
    if read == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty request",
        ));
    }
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "message exceeds 64 KiB",
        ));
    }
    Ok(bytes)
}

pub fn read_request(stream: &mut UnixStream) -> io::Result<Request> {
    let bytes = read_bounded(stream)?;
    let request: Request = serde_json::from_slice(&bytes)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    validate_request(&request).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok(request)
}
pub fn write_request(stream: &mut UnixStream, request: &Request) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(request).map_err(io::Error::other)?;
    if bytes.len() + 1 > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "message exceeds 64 KiB",
        ));
    }
    bytes.push(b'\n');
    stream.write_all(&bytes)
}
pub fn read_response(stream: &mut UnixStream) -> io::Result<Response> {
    let bytes = read_bounded(stream)?;
    serde_json::from_slice(&bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}
pub fn write_response(stream: &mut UnixStream, response: &Response) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(response).map_err(io::Error::other)?;
    if bytes.len() + 1 > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "response exceeds 64 KiB",
        ));
    }
    bytes.push(b'\n');
    stream.write_all(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
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
}

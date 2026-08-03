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

fn validate_field(name: &str, value: &str) -> Result<(), String> {
    let contains_delimiter = value
        .bytes()
        .any(|byte| matches!(byte, 0 | b'\n' | b'\r' | b'\t'));
    if value.is_empty() || value.len() > MAX_FIELD_BYTES || contains_delimiter {
        return Err(format!("invalid {name}"));
    }
    Ok(())
}

fn validate_identifier(name: &str, value: &str, prefix: char) -> Result<(), String> {
    validate_field(name, value)?;
    let mut characters = value.chars();
    if characters.next() != Some(prefix) || !characters.all(|character| character.is_ascii_digit())
    {
        return Err(format!("invalid {name}"));
    }
    Ok(())
}

fn validate_report(
    tool: &str,
    pane_id: &str,
    process_generation: &str,
    session_id: &str,
    session_name: &str,
) -> Result<(), String> {
    validate_field("tool", tool)?;
    validate_identifier("pane_id", pane_id, '%')?;
    validate_field("process_generation", process_generation)?;
    validate_identifier("session_id", session_id, '$')?;
    validate_field("session_name", session_name)
}

fn validate_exit(pane_id: Option<&str>, session_id: Option<&str>) -> Result<(), String> {
    if pane_id.is_none() && session_id.is_none() {
        return Err("Exited needs pane_id or session_id".into());
    }
    if let Some(value) = pane_id {
        validate_identifier("pane_id", value, '%')?;
    }
    if let Some(value) = session_id {
        validate_identifier("session_id", value, '$')?;
    }
    Ok(())
}

pub fn validate_request(request: &Request) -> Result<(), String> {
    match request {
        Request::Report {
            tool,
            pane_id,
            process_generation,
            session_id,
            session_name,
            ..
        } => validate_report(tool, pane_id, process_generation, session_id, session_name),
        Request::Seen { pane_id } => {
            let value = pane_id.as_deref().ok_or("Seen needs pane_id")?;
            validate_identifier("pane_id", value, '%')
        }
        Request::Exited {
            pane_id,
            session_id,
        } => validate_exit(pane_id.as_deref(), session_id.as_deref()),
        _ => Ok(()),
    }
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

    include!("protocol/tests.rs");
}

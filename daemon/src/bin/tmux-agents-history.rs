use serde_json::Value;
use std::collections::HashMap;
use std::env;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[derive(Debug)]
struct HistoryRecord {
    agent: &'static str,
    source: PathBuf,
    session_id: String,
    cwd: String,
    updated_at: u64,
    title: String,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("tmux-agents-history: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    match arguments.as_slice() {
        [command, pi_dir, codex_dir, claude_dir] if command == "list" => {
            list_records(Path::new(pi_dir), Path::new(codex_dir), Path::new(claude_dir))
        }
        [command, agent, source] if command == "preview" => {
            preview_record(agent, Path::new(source))
        }
        _ => Err(
            "usage: tmux-agents-history list <pi-sessions-dir> <codex-home> <claude-home> | preview <agent> <source-file>"
                .to_string(),
        ),
    }
}

fn list_records(pi_dir: &Path, codex_home: &Path, claude_home: &Path) -> Result<(), String> {
    let mut records = Vec::new();
    collect_pi_records(pi_dir, &mut records);
    collect_codex_records(codex_home, &mut records);
    collect_claude_records(claude_home, &mut records);
    records.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));

    let stdout = io::stdout();
    let mut output = BufWriter::new(stdout.lock());
    for record in records {
        if contains_record_separator(&record.cwd)
            || contains_record_separator(&record.session_id)
            || contains_record_separator(&record.source.to_string_lossy())
        {
            continue;
        }
        if let Err(error) = writeln!(
            output,
            "{}\t{}\t{}\t{}\t{}\t{}",
            record.agent,
            record.source.to_string_lossy(),
            record.session_id,
            record.cwd,
            record.updated_at,
            compact_text(&record.title, 240)
        ) {
            if error.kind() == io::ErrorKind::BrokenPipe {
                return Ok(());
            }
            return Err(format!("failed to write history list: {error}"));
        }
    }
    Ok(())
}

fn collect_pi_records(root: &Path, records: &mut Vec<HistoryRecord>) {
    for source in jsonl_files(root) {
        if let Some(record) = parse_pi_record(&source) {
            records.push(record);
        }
    }
}

fn parse_pi_record(source: &Path) -> Option<HistoryRecord> {
    let file = File::open(source).ok()?;
    let mut session_id = String::new();
    let mut cwd = String::new();
    let mut first_prompt = String::new();
    let mut session_name = String::new();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("session") => {
                session_id = json_string(&value, &["id"]);
                cwd = json_string(&value, &["cwd"]);
            }
            Some("session_info") => {
                let name = json_string(&value, &["name"]);
                if !name.is_empty() {
                    session_name = name;
                }
            }
            Some("message") if first_prompt.is_empty() => {
                if let Some(message) = value.get("message") {
                    if message.get("role").and_then(Value::as_str) == Some("user") {
                        first_prompt = content_text(message.get("content"));
                    }
                }
            }
            _ => {}
        }
    }

    if session_id.is_empty() || cwd.is_empty() {
        return None;
    }
    let title = if session_name.is_empty() {
        fallback_title(first_prompt)
    } else {
        session_name
    };
    Some(HistoryRecord {
        agent: "pi",
        source: source.to_path_buf(),
        session_id,
        cwd,
        updated_at: modified_epoch(source),
        title,
    })
}

fn collect_codex_records(home: &Path, records: &mut Vec<HistoryRecord>) {
    let names = codex_session_names(&home.join("session_index.jsonl"));
    for source in jsonl_files(&home.join("sessions")) {
        if let Some(mut record) = parse_codex_record(&source) {
            if let Some(name) = names.get(&record.session_id) {
                record.title = name.clone();
            }
            records.push(record);
        }
    }
}

fn codex_session_names(index: &Path) -> HashMap<String, String> {
    let mut names = HashMap::new();
    let Ok(file) = File::open(index) else {
        return names;
    };
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let id = json_string(&value, &["id"]);
        let name = json_string(&value, &["thread_name"]);
        if !id.is_empty() && !name.is_empty() {
            names.insert(id, name);
        }
    }
    names
}

fn parse_codex_record(source: &Path) -> Option<HistoryRecord> {
    let file = File::open(source).ok()?;
    let mut session_id = String::new();
    let mut cwd = String::new();
    let mut first_event_prompt = String::new();
    let mut first_response_prompt = String::new();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let record_type = value.get("type").and_then(Value::as_str);
        let payload = value.get("payload");
        match record_type {
            Some("session_meta") => {
                session_id = payload
                    .map(|item| json_string(item, &["id"]))
                    .unwrap_or_default();
                cwd = payload
                    .map(|item| json_string(item, &["cwd"]))
                    .unwrap_or_default();
            }
            Some("event_msg") if first_event_prompt.is_empty() => {
                if payload
                    .and_then(|item| item.get("type"))
                    .and_then(Value::as_str)
                    == Some("user_message")
                {
                    first_event_prompt = payload
                        .map(|item| json_string(item, &["message"]))
                        .unwrap_or_default();
                }
            }
            Some("response_item") if first_response_prompt.is_empty() => {
                if payload
                    .and_then(|item| item.get("type"))
                    .and_then(Value::as_str)
                    == Some("message")
                    && payload
                        .and_then(|item| item.get("role"))
                        .and_then(Value::as_str)
                        == Some("user")
                {
                    first_response_prompt = payload
                        .map(|item| content_text(item.get("content")))
                        .unwrap_or_default();
                }
            }
            _ => {}
        }
    }

    if session_id.is_empty() || cwd.is_empty() {
        return None;
    }
    let prompt = if first_event_prompt.is_empty() {
        first_response_prompt
    } else {
        first_event_prompt
    };
    Some(HistoryRecord {
        agent: "codex",
        source: source.to_path_buf(),
        session_id,
        cwd,
        updated_at: modified_epoch(source),
        title: fallback_title(prompt),
    })
}

fn collect_claude_records(home: &Path, records: &mut Vec<HistoryRecord>) {
    let projects_root = home.join("projects");
    let Ok(project_directories) = fs::read_dir(projects_root) else {
        return;
    };
    for project_directory in project_directories.flatten() {
        let Ok(file_type) = project_directory.file_type() else {
            continue;
        };
        if !file_type.is_dir() {
            continue;
        }
        let Ok(entries) = fs::read_dir(project_directory.path()) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            let source = entry.path();
            // Claude stores resumable top-level conversations directly in each
            // encoded project directory. Nested subagent transcripts are not
            // independently resumable and must not appear as user history.
            if file_type.is_file()
                && source.extension().and_then(|value| value.to_str()) == Some("jsonl")
            {
                if let Some(record) = parse_claude_record(&source) {
                    records.push(record);
                }
            }
        }
    }
}

fn parse_claude_record(source: &Path) -> Option<HistoryRecord> {
    let file = File::open(source).ok()?;
    let mut session_id = String::new();
    let mut cwd = String::new();
    let mut first_prompt = String::new();

    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if session_id.is_empty() {
            session_id = json_string(&value, &["sessionId"]);
        }
        if cwd.is_empty() {
            cwd = json_string(&value, &["cwd"]);
        }
        if first_prompt.is_empty()
            && value.get("type").and_then(Value::as_str) == Some("user")
            && !value
                .get("isMeta")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            && !value
                .get("isSidechain")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        {
            first_prompt = content_text(value.get("message").and_then(|item| item.get("content")));
        }
    }

    if session_id.is_empty() || cwd.is_empty() {
        return None;
    }
    Some(HistoryRecord {
        agent: "claude",
        source: source.to_path_buf(),
        session_id,
        cwd,
        updated_at: modified_epoch(source),
        title: fallback_title(first_prompt),
    })
}

fn preview_record(agent: &str, source: &Path) -> Result<(), String> {
    let messages = match agent {
        "pi" => pi_preview(source),
        "codex" => codex_preview(source),
        "claude" => claude_preview(source),
        _ => return Err(format!("unsupported agent: {agent}")),
    };
    let stdout = io::stdout();
    let mut output = BufWriter::new(stdout.lock());
    if messages.is_empty() {
        return write_preview(&mut output, "No user/assistant messages found.\n");
    }
    let start = messages.len().saturating_sub(12);
    for (role, text) in &messages[start..] {
        let rendered = format!("{}\n{}\n\n", role_label(role), compact_preview_text(text));
        write_preview(&mut output, &rendered)?;
    }
    Ok(())
}

fn write_preview(output: &mut impl Write, text: &str) -> Result<(), String> {
    if let Err(error) = output.write_all(text.as_bytes()) {
        if error.kind() == io::ErrorKind::BrokenPipe {
            return Ok(());
        }
        return Err(format!("failed to write history preview: {error}"));
    }
    Ok(())
}

fn pi_preview(source: &Path) -> Vec<(String, String)> {
    let Ok(file) = File::open(source) else {
        return Vec::new();
    };
    BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_str::<Value>(&line).ok())
        .filter_map(|value| {
            if value.get("type").and_then(Value::as_str) != Some("message") {
                return None;
            }
            let message = value.get("message")?;
            message_pair(
                message.get("role").and_then(Value::as_str)?,
                message.get("content"),
            )
        })
        .collect()
}

fn codex_preview(source: &Path) -> Vec<(String, String)> {
    let Ok(file) = File::open(source) else {
        return Vec::new();
    };
    let mut event_messages = Vec::new();
    let mut response_messages = Vec::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(payload) = value.get("payload") else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("event_msg") => match payload.get("type").and_then(Value::as_str) {
                Some("user_message") => {
                    let text = json_string(payload, &["message"]);
                    if !text.is_empty() {
                        event_messages.push(("user".to_string(), text));
                    }
                }
                Some("agent_message") => {
                    let text = json_string(payload, &["message"]);
                    if !text.is_empty() {
                        event_messages.push(("assistant".to_string(), text));
                    }
                }
                _ => {}
            },
            Some("response_item")
                if payload.get("type").and_then(Value::as_str) == Some("message") =>
            {
                if let Some(pair) = message_pair(
                    payload.get("role").and_then(Value::as_str).unwrap_or(""),
                    payload.get("content"),
                ) {
                    response_messages.push(pair);
                }
            }
            _ => {}
        }
    }
    if event_messages.is_empty() {
        response_messages
    } else {
        event_messages
    }
}

fn claude_preview(source: &Path) -> Vec<(String, String)> {
    let Ok(file) = File::open(source) else {
        return Vec::new();
    };
    BufReader::new(file)
        .lines()
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_str::<Value>(&line).ok())
        .filter(|value| {
            !value
                .get("isMeta")
                .and_then(Value::as_bool)
                .unwrap_or(false)
                && !value
                    .get("isSidechain")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        })
        .filter_map(|value| {
            let role = value.get("message")?.get("role")?.as_str()?;
            message_pair(role, value.get("message")?.get("content"))
        })
        .collect()
}

fn message_pair(role: &str, content: Option<&Value>) -> Option<(String, String)> {
    if role != "user" && role != "assistant" {
        return None;
    }
    let text = content_text(content);
    if text.is_empty() {
        return None;
    }
    Some((role.to_string(), text))
}

fn content_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| {
                if let Some(text) = block.as_str() {
                    return Some(text.to_string());
                }
                let block_type = block.get("type").and_then(Value::as_str);
                if matches!(
                    block_type,
                    Some("text") | Some("input_text") | Some("output_text")
                ) {
                    return block
                        .get("text")
                        .and_then(Value::as_str)
                        .map(ToString::to_string);
                }
                None
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn json_string(value: &Value, path: &[&str]) -> String {
    let mut current = value;
    for key in path {
        let Some(next) = current.get(*key) else {
            return String::new();
        };
        current = next;
    }
    current.as_str().unwrap_or_default().to_string()
}

fn jsonl_files(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_jsonl_files(root, &mut files);
    files
}

fn collect_jsonl_files(root: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        if file_type.is_dir() {
            collect_jsonl_files(&path, files);
        } else if file_type.is_file()
            && path.extension().and_then(|value| value.to_str()) == Some("jsonl")
        {
            files.push(path);
        }
    }
}

fn modified_epoch(path: &Path) -> u64 {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn fallback_title(prompt: String) -> String {
    let compact = compact_text(&prompt, 240);
    if compact.is_empty() {
        "(untitled conversation)".to_string()
    } else {
        compact
    }
}

fn compact_text(text: &str, max_characters: usize) -> String {
    let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.chars().count() <= max_characters {
        return normalized;
    }
    let mut shortened: String = normalized
        .chars()
        .take(max_characters.saturating_sub(1))
        .collect();
    shortened.push('…');
    shortened
}

fn compact_preview_text(text: &str) -> String {
    text.replace('\t', "    ")
        .chars()
        .filter(|character| *character == '\n' || !character.is_control())
        .collect()
}

fn role_label(role: &str) -> &'static str {
    match role {
        "user" => "You:",
        "assistant" => "Agent:",
        _ => "Message:",
    }
}

fn contains_record_separator(text: &str) -> bool {
    text.contains('\t') || text.contains('\n') || text.contains('\r')
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temporary_file(name: &str, content: &str) -> PathBuf {
        let directory = env::temp_dir().join(format!(
            "tmux-agents-history-test-{}-{}",
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
}

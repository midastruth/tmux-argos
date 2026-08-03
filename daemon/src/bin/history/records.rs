fn collect_pi_records(root: &Path, records: &mut Vec<HistoryRecord>) {
    for source in jsonl_files(root) {
        if let Some(record) = parse_pi_record(&source) {
            records.push(record);
        }
    }
}

#[derive(Default)]
struct PiMetadata {
    session_id: String,
    cwd: String,
    first_prompt: String,
    session_name: String,
}

fn apply_pi_value(metadata: &mut PiMetadata, value: &Value) {
    match value.get("type").and_then(Value::as_str) {
        Some("session") => {
            metadata.session_id = json_string(value, &["id"]);
            metadata.cwd = json_string(value, &["cwd"]);
        }
        Some("session_info") => {
            let name = json_string(value, &["name"]);
            if !name.is_empty() {
                metadata.session_name = name;
            }
        }
        Some("message") if metadata.first_prompt.is_empty() => {
            let Some(message) = value.get("message") else {
                return;
            };
            if message.get("role").and_then(Value::as_str) == Some("user") {
                metadata.first_prompt = content_text(message.get("content"));
            }
        }
        _ => {}
    }
}

fn parse_pi_record(source: &Path) -> Option<HistoryRecord> {
    let file = File::open(source).ok()?;
    let mut metadata = PiMetadata::default();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        apply_pi_value(&mut metadata, &value);
    }
    if metadata.session_id.is_empty() || metadata.cwd.is_empty() {
        return None;
    }
    let title = match metadata.session_name.is_empty() {
        true => fallback_title(metadata.first_prompt),
        false => metadata.session_name,
    };
    Some(HistoryRecord {
        agent: "pi",
        source: source.to_path_buf(),
        session_id: metadata.session_id,
        cwd: metadata.cwd,
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

#[derive(Default)]
struct CodexMetadata {
    session_id: String,
    cwd: String,
    first_event_prompt: String,
    first_response_prompt: String,
}

fn codex_payload_is(payload: Option<&Value>, field: &str, expected: &str) -> bool {
    payload
        .and_then(|item| item.get(field))
        .and_then(Value::as_str)
        == Some(expected)
}

fn apply_codex_value(metadata: &mut CodexMetadata, value: &Value) {
    let payload = value.get("payload");
    match value.get("type").and_then(Value::as_str) {
        Some("session_meta") => {
            metadata.session_id = payload
                .map(|item| json_string(item, &["id"]))
                .unwrap_or_default();
            metadata.cwd = payload
                .map(|item| json_string(item, &["cwd"]))
                .unwrap_or_default();
        }
        Some("event_msg") if metadata.first_event_prompt.is_empty() => {
            if codex_payload_is(payload, "type", "user_message") {
                metadata.first_event_prompt = payload
                    .map(|item| json_string(item, &["message"]))
                    .unwrap_or_default();
            }
        }
        Some("response_item")
            if metadata.first_response_prompt.is_empty()
                && codex_payload_is(payload, "type", "message")
                && codex_payload_is(payload, "role", "user") =>
        {
            metadata.first_response_prompt = payload
                .map(|item| content_text(item.get("content")))
                .unwrap_or_default();
        }
        _ => {}
    }
}

fn parse_codex_record(source: &Path) -> Option<HistoryRecord> {
    let file = File::open(source).ok()?;
    let mut metadata = CodexMetadata::default();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        apply_codex_value(&mut metadata, &value);
    }
    if metadata.session_id.is_empty() || metadata.cwd.is_empty() {
        return None;
    }
    let prompt = match metadata.first_event_prompt.is_empty() {
        true => metadata.first_response_prompt,
        false => metadata.first_event_prompt,
    };
    Some(HistoryRecord {
        agent: "codex",
        source: source.to_path_buf(),
        session_id: metadata.session_id,
        cwd: metadata.cwd,
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

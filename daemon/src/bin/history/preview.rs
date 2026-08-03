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

fn append_codex_event(payload: &Value, messages: &mut Vec<(String, String)>) {
    let role = match payload.get("type").and_then(Value::as_str) {
        Some("user_message") => "user",
        Some("agent_message") => "assistant",
        _ => return,
    };
    let text = json_string(payload, &["message"]);
    if !text.is_empty() {
        messages.push((role.to_string(), text));
    }
}

fn append_codex_response(payload: &Value, messages: &mut Vec<(String, String)>) {
    if payload.get("type").and_then(Value::as_str) != Some("message") {
        return;
    }
    let role = payload.get("role").and_then(Value::as_str).unwrap_or("");
    if let Some(pair) = message_pair(role, payload.get("content")) {
        messages.push(pair);
    }
}

fn apply_codex_preview_value(
    value: &Value,
    event_messages: &mut Vec<(String, String)>,
    response_messages: &mut Vec<(String, String)>,
) {
    let Some(payload) = value.get("payload") else {
        return;
    };
    match value.get("type").and_then(Value::as_str) {
        Some("event_msg") => append_codex_event(payload, event_messages),
        Some("response_item") => append_codex_response(payload, response_messages),
        _ => {}
    }
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
        apply_codex_preview_value(&value, &mut event_messages, &mut response_messages);
    }
    match event_messages.is_empty() {
        true => response_messages,
        false => event_messages,
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

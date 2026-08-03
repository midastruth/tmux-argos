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

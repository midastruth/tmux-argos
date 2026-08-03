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
        eprintln!("tmux-argos-history: {error}");
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
            "usage: tmux-argos-history list <pi-sessions-dir> <codex-home> <claude-home> | preview <agent> <source-file>"
                .to_string(),
        ),
    }
}

fn list_records(pi_dir: &Path, codex_home: &Path, claude_home: &Path) -> Result<(), String> {
    let mut records = Vec::new();
    collect_pi_records(pi_dir, &mut records);
    collect_codex_records(codex_home, &mut records);
    collect_claude_records(claude_home, &mut records);
    records.sort_by_key(|record| std::cmp::Reverse(record.updated_at));

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

include!("history/records.rs");
include!("history/preview.rs");
include!("history/files.rs");

#[cfg(test)]
mod tests {
    use super::*;

    include!("history/tests.rs");
}

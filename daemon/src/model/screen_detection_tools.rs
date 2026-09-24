fn detect_pi(screen: &str) -> ScreenDetection {
    let bottom = bottom_non_empty_lines(screen, 6);
    if bottom.lines().any(pi_working_line) {
        return detection(AgentState::Working);
    }
    detection(AgentState::Idle)
}

fn pi_working_line(line: &str) -> bool {
    let status = line.trim().trim_start_matches('─').trim_start();
    let Some(spinner) = status.chars().next() else {
        return false;
    };
    if !is_braille_spinner(spinner) {
        return false;
    }
    status[spinner.len_utf8()..]
        .trim_start()
        .strip_prefix("Working")
        .is_some_and(|suffix| suffix.is_empty() || suffix.starts_with([' ', '─']))
}

fn detect_codex(title: &str, screen: &str) -> ScreenDetection {
    let title_lowercase = title.to_ascii_lowercase();
    if title_lowercase.contains("action required") {
        return detection(AgentState::Blocked);
    }
    if starts_with_braille_spinner(title) {
        return detection(AgentState::Working);
    }
    let after_prompt = after_last_codex_prompt(screen);
    let after_prompt_lowercase = after_prompt.to_ascii_lowercase();
    if codex_transcript_is_open(&after_prompt_lowercase) {
        return skip_detection();
    }
    if codex_startup_blocks(screen) || codex_live_prompt_blocks(after_prompt, &after_prompt_lowercase)
    {
        return detection(AgentState::Blocked);
    }
    let screen_lowercase = screen.to_ascii_lowercase();
    if weak_blocker(screen, &screen_lowercase) {
        return detection(AgentState::Blocked);
    }
    if codex_live_working(screen) {
        return detection(AgentState::Working);
    }
    if !title.trim().is_empty() {
        return visible_idle_detection();
    }
    detection(AgentState::Idle)
}

fn codex_transcript_is_open(after_prompt_lowercase: &str) -> bool {
    contains_all(
        after_prompt_lowercase,
        &[
            "↑/↓ to scroll",
            "pgup/pgdn to",
            "home/end to jump",
            "q to quit",
        ],
    ) && contains_any(
        after_prompt_lowercase,
        &["esc to edit prev", "esc/← to edit prev"],
    )
}

fn codex_startup_blocks(screen: &str) -> bool {
    let top = top_non_empty_lines(screen, 20);
    let trust = top.lines().any(|line| line.starts_with("> You are in "))
        && top.contains("Do you trust the contents of this directory?");
    let bottom = bottom_non_empty_lines(screen, 20);
    let update = contains_all(
        bottom,
        &["Update available!", "Update now", "Press enter to continue"],
    ) && bottom.contains("Skip until next version");
    trust || update
}

fn codex_live_prompt_blocks(after_prompt: &str, after_prompt_lowercase: &str) -> bool {
    contains_any(
        after_prompt_lowercase,
        &[
            "press enter to confirm or esc to cancel",
            "enter to submit answer",
            "enter to submit all",
            "allow command?",
        ],
    ) || weak_blocker(after_prompt, after_prompt_lowercase)
}

fn codex_live_working(screen: &str) -> bool {
    let bottom = bottom_non_empty_lines(screen, 3);
    if bottom.contains("■ Conversation interrupted") {
        return false;
    }
    bottom.lines().any(|line| {
        let trimmed = line.trim();
        let Some(marker) = trimmed.chars().next() else {
            return false;
        };
        matches!(marker, '•' | '◦')
            && trimmed[marker.len_utf8()..].trim_start().starts_with("Working (")
            && trimmed.contains("esc to interrupt)")
    })
}

fn detect_claude(title: &str, screen: &str) -> ScreenDetection {
    if starts_with_claude_spinner(title) {
        return detection(AgentState::Working);
    }
    let lowercase = screen.to_ascii_lowercase();
    let after_rule = after_last_horizontal_rule(&lowercase);
    if claude_transcript_is_open(&lowercase) {
        return skip_detection();
    }
    if claude_high_priority_blocker(screen, &lowercase, after_rule) {
        return detection(AgentState::Blocked);
    }
    if claude_live_working(screen, &lowercase) {
        return detection(AgentState::Working);
    }
    // A live idle prompt box outranks screen-wide permission wording, which may
    // belong to an already answered dialog or quoted text left in the history.
    if claude_prompt_is_idle(screen) {
        return visible_idle_detection();
    }
    if claude_model_picker_is_open(&lowercase) {
        return skip_detection();
    }
    if claude_permission_blocks(screen, &lowercase, after_rule) {
        return detection(AgentState::Blocked);
    }
    if title.trim_start().starts_with('✳') {
        return visible_idle_detection();
    }
    detection(AgentState::Idle)
}

fn starts_with_claude_spinner(value: &str) -> bool {
    value
        .trim_start()
        .chars()
        .next()
        .is_some_and(|character| is_braille_spinner(character) || matches!(character, '◐'..='◓'))
}

fn claude_transcript_is_open(screen_lowercase: &str) -> bool {
    let bottom = bottom_non_empty_lines(screen_lowercase, 3);
    bottom.contains("showing detailed transcript")
        && contains_any(bottom, &["ctrl+o", "ctrl+e", "↑↓ scroll", "? for shortcuts"])
}

fn claude_high_priority_blocker(screen: &str, lowercase: &str, after_rule: &str) -> bool {
    claude_navigation_blocks(after_rule)
        || contains_all(lowercase, &["run a dynamic workflow?", "esc to cancel"])
        || claude_mcp_elicitation_blocks(screen, lowercase)
}

fn claude_navigation_blocks(after_rule_lowercase: &str) -> bool {
    if !after_rule_lowercase.contains("esc to cancel") {
        return false;
    }
    if after_rule_lowercase.contains("enter to confirm") {
        return true;
    }
    after_rule_lowercase.contains("enter to select")
        && contains_any(
            after_rule_lowercase,
            &[
                "tab/arrow keys to navigate",
                "arrow keys to navigate",
                "arrows to navigate",
                "↑/↓ to navigate",
                "↑↓ to navigate",
            ],
        )
}

fn claude_mcp_elicitation_blocks(screen: &str, lowercase: &str) -> bool {
    lowercase.contains("mcp server")
        && lowercase.contains("requests your input")
        && lowercase.contains("esc to cancel")
        && screen.lines().any(|line| {
            let option = line.trim_start().trim_start_matches('❯').trim_start();
            option.starts_with("Accept") || option.starts_with("Decline")
        })
}

fn claude_live_working(screen: &str, lowercase: &str) -> bool {
    let bottom = bottom_non_empty_lines(screen, 12);
    claude_btw_is_open(bottom)
        || bottom.lines().any(claude_active_turn_line)
        || claude_background_agents_working(screen)
        || claude_mcp_tasks_working(bottom, lowercase)
}

fn claude_btw_is_open(bottom: &str) -> bool {
    bottom.lines().any(|line| line.trim_start().starts_with("/btw"))
        && bottom
            .lines()
            .any(|line| line.trim().eq_ignore_ascii_case("esc to close"))
}

fn claude_active_turn_line(line: &str) -> bool {
    let trimmed = line.trim_start();
    let Some(marker) = trimmed.chars().next() else {
        return false;
    };
    if matches!(marker, '⏸' | '⏵') {
        return trimmed.to_ascii_lowercase().contains("esc to interrupt");
    }
    is_claude_activity_marker(marker) && trimmed.contains('…')
}

fn claude_background_agents_working(screen: &str) -> bool {
    let Some(line) = last_non_empty_above_prompt_box(screen) else {
        return false;
    };
    let trimmed = line.trim_start();
    let Some(marker) = trimmed.chars().next() else {
        return false;
    };
    let status = trimmed[marker.len_utf8()..].trim_start().to_ascii_lowercase();
    is_claude_activity_marker(marker)
        && status.starts_with("waiting for ")
        && status.contains(" background agent")
        && status.ends_with(" to finish")
}

fn claude_mcp_tasks_working(bottom: &str, lowercase: &str) -> bool {
    if contains_any(
        lowercase,
        &[
            "do you want to proceed?",
            "esc to cancel",
            "waiting for permission",
            "do you want to allow this connection?",
            "tab to amend",
            "ctrl+e to explain",
        ],
    ) {
        return false;
    }
    let lines: Vec<&str> = bottom.lines().collect();
    (0..lines.len()).any(|start| claude_mcp_task_status_starts_at(&lines, start))
}

/// Claude renders activity summaries at column zero and indents its own wrapped
/// continuations. Anchoring the marker at column zero keeps indented transcript
/// text from impersonating a running MCP task.
fn claude_mcp_task_status_starts_at(lines: &[&str], start: usize) -> bool {
    let Some(summary) = claude_column_zero_status_text(lines[start]) else {
        return false;
    };
    let mut status = summary.to_ascii_lowercase();
    if ends_with_running_mcp_task_count(&status) {
        return true;
    }
    let continuations = lines[start + 1..]
        .iter()
        .take(CLAUDE_STATUS_MAX_CONTINUATION_LINES)
        .take_while(|line| line.starts_with([' ', '\t']));
    for continuation in continuations {
        status.push(' ');
        status.push_str(&continuation.to_ascii_lowercase());
        if ends_with_running_mcp_task_count(&status) {
            return true;
        }
    }
    false
}

const CLAUDE_STATUS_MAX_CONTINUATION_LINES: usize = 3;

fn claude_column_zero_status_text(line: &str) -> Option<&str> {
    let marker = line.chars().next()?;
    if !is_claude_activity_marker(marker) {
        return None;
    }
    let text = &line[marker.len_utf8()..];
    if !text.starts_with([' ', '\t']) {
        return None;
    }
    Some(text)
}

fn ends_with_running_mcp_task_count(status_lowercase: &str) -> bool {
    let Some((summary, task_count)) = status_lowercase.rsplit_once('·') else {
        return false;
    };
    if summary.trim().is_empty() {
        return false;
    }
    let words: Vec<&str> = task_count.split_whitespace().collect();
    let [count, "mcp", noun, "still", "running"] = words.as_slice() else {
        return false;
    };
    is_positive_decimal(count) && matches!(*noun, "task" | "tasks")
}

fn is_positive_decimal(value: &str) -> bool {
    !value.is_empty() && !value.starts_with('0') && value.chars().all(|digit| digit.is_ascii_digit())
}

fn is_claude_activity_marker(character: char) -> bool {
    matches!(character, '*' | '·' | '✢' | '✳' | '✶' | '✻' | '✽')
}

fn claude_model_picker_is_open(screen_lowercase: &str) -> bool {
    contains_all(
        screen_lowercase,
        &["select model", "enter to set as default", "esc to cancel"],
    ) && !screen_lowercase.contains("do you want to proceed?")
        && !screen_lowercase.contains("enter to select")
}

fn claude_permission_blocks(screen: &str, lowercase: &str, after_rule: &str) -> bool {
    claude_command_permission_blocks(lowercase)
        || claude_choice_permission_blocks(after_rule)
        || legacy_claude_blocker(screen, lowercase)
}

fn claude_command_permission_blocks(screen_lowercase: &str) -> bool {
    screen_lowercase.contains("do you want to proceed?")
        && contains_any(
            screen_lowercase,
            &[
                "bash command",
                "bash(",
                "contains expansion",
                "tab to amend",
                "ctrl+e to explain",
            ],
        )
        && contains_any(screen_lowercase, &["yes", "1. yes", "2. no"])
}

fn claude_choice_permission_blocks(after_rule_lowercase: &str) -> bool {
    contains_all(
        after_rule_lowercase,
        &["do you want to proceed?", "esc to cancel"],
    ) && contains_any(
        after_rule_lowercase,
        &["1. yes", "2. yes", "2. no", "3. no"],
    )
}

fn claude_prompt_is_idle(screen: &str) -> bool {
    let prompt_body = prompt_box_body(screen);
    let lowercase = prompt_body.to_ascii_lowercase();
    has_claude_prompt_line(prompt_body)
        && !contains_any(
            &lowercase,
            &[
                "enter to select",
                "esc to cancel",
                "tab/arrow keys",
                "arrow keys to navigate",
                "↑/↓ to navigate",
            ],
        )
}

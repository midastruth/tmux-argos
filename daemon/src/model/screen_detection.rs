fn detect_pi(screen: &str) -> ScreenDetection {
    // Pi renders this literal status while a turn is running. This is the same
    // high-confidence screen rule used by Herdr's bundled Pi manifest.
    if screen.contains("Working...") {
        return detection(AgentState::Working);
    }
    detection(AgentState::Idle)
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
    if contains_all(
        &after_prompt_lowercase,
        &[
            "↑/↓ to scroll",
            "pgup/pgdn to",
            "home/end to jump",
            "q to quit",
        ],
    ) && (after_prompt_lowercase.contains("esc to edit prev")
        || after_prompt_lowercase.contains("esc/← to edit prev"))
    {
        return skip_detection();
    }
    if contains_any(
        &after_prompt_lowercase,
        &[
            "press enter to confirm or esc to cancel",
            "enter to submit answer",
            "enter to submit all",
            "allow command?",
        ],
    ) {
        return detection(AgentState::Blocked);
    }
    let screen_lowercase = screen.to_ascii_lowercase();
    if weak_blocker(screen, &screen_lowercase) {
        return detection(AgentState::Blocked);
    }
    if !title.trim().is_empty() && !starts_with_braille_spinner(title) {
        return visible_idle_detection();
    }
    detection(AgentState::Idle)
}

fn claude_transcript_is_open(screen_lowercase: &str) -> bool {
    let bottom = bottom_non_empty_lines(screen_lowercase, 3);
    bottom.contains("showing detailed transcript")
        && contains_any(bottom, &["ctrl+o", "ctrl+e", "↑↓ scroll", "? for shortcuts"])
}

fn claude_navigation_blocks(after_rule_lowercase: &str) -> bool {
    contains_all(after_rule_lowercase, &["enter to select", "esc to cancel"])
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

fn claude_model_picker_is_open(screen_lowercase: &str) -> bool {
    contains_all(
        screen_lowercase,
        &["select model", "enter to set as default", "esc to cancel"],
    ) && !screen_lowercase.contains("do you want to proceed?")
        && !screen_lowercase.contains("enter to select")
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

fn claude_is_blocked(screen: &str, lowercase: &str, after_rule: &str) -> bool {
    claude_navigation_blocks(after_rule)
        || contains_all(lowercase, &["run a dynamic workflow?", "esc to cancel"])
        || claude_command_permission_blocks(lowercase)
        || claude_choice_permission_blocks(after_rule)
        || legacy_claude_blocker(screen, lowercase)
}

fn claude_is_idle(title: &str, screen: &str) -> bool {
    claude_prompt_is_idle(screen) || title.trim_start().starts_with('✳')
}

fn detect_claude(title: &str, screen: &str) -> ScreenDetection {
    if starts_with_braille_spinner(title) {
        return detection(AgentState::Working);
    }
    let lowercase = screen.to_ascii_lowercase();
    let after_rule = after_last_horizontal_rule(&lowercase);
    if claude_transcript_is_open(&lowercase) || claude_model_picker_is_open(&lowercase) {
        return skip_detection();
    }
    if claude_is_blocked(screen, &lowercase, after_rule) {
        return detection(AgentState::Blocked);
    }
    if claude_is_idle(title, screen) {
        return visible_idle_detection();
    }
    detection(AgentState::Idle)
}

fn detection(state: AgentState) -> ScreenDetection {
    ScreenDetection {
        state,
        skip_state_update: false,
        visible_idle: false,
    }
}

fn visible_idle_detection() -> ScreenDetection {
    ScreenDetection {
        state: AgentState::Idle,
        skip_state_update: false,
        visible_idle: true,
    }
}

fn skip_detection() -> ScreenDetection {
    ScreenDetection {
        state: AgentState::Idle,
        skip_state_update: true,
        visible_idle: false,
    }
}

fn starts_with_braille_spinner(value: &str) -> bool {
    value
        .trim_start()
        .chars()
        .next()
        .is_some_and(|ch| ('\u{2800}'..='\u{28ff}').contains(&ch))
}

fn contains_all(haystack_lowercase: &str, needles_lowercase: &[&str]) -> bool {
    needles_lowercase
        .iter()
        .all(|needle| haystack_lowercase.contains(needle))
}

fn contains_any(haystack_lowercase: &str, needles_lowercase: &[&str]) -> bool {
    needles_lowercase
        .iter()
        .any(|needle| haystack_lowercase.contains(needle))
}

fn weak_blocker(screen: &str, screen_lowercase: &str) -> bool {
    screen_lowercase.contains("[y/n]")
        || screen_lowercase.contains("yes (y)")
        || ((screen_lowercase.contains("do you want to")
            || screen_lowercase.contains("would you like to"))
            && (screen_lowercase.contains("yes") || screen.contains('❯')))
}

fn legacy_claude_blocker(screen: &str, screen_lowercase: &str) -> bool {
    let prompt_alone = screen.lines().any(|line| line.trim() == "❯");
    if prompt_alone {
        return false;
    }
    weak_blocker(screen, screen_lowercase)
        || contains_any(
            screen_lowercase,
            &[
                "waiting for permission",
                "do you want to allow this connection?",
                "tab to amend",
                "ctrl+e to explain",
                "do you want to proceed?",
                "review your answers",
                "skip interview and plan immediately",
            ],
        )
}

fn after_last_codex_prompt(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(index) = lines
        .iter()
        .rposition(|line| *line == "›" || line.starts_with("› "))
    else {
        return content;
    };
    slice_from_line_index(content, &lines, index + 1)
}

fn bottom_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(start_index) = lines
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map(|(index, _)| index)
    else {
        return "";
    };
    slice_from_line_index(content, &lines, start_index)
}

fn after_last_horizontal_rule(content: &str) -> &str {
    let mut last_rule_end = 0usize;
    let mut offset = 0usize;
    for line in content.lines() {
        let next_offset = offset + line.len() + 1;
        if is_horizontal_rule(line) {
            last_rule_end = next_offset.min(content.len());
        }
        offset = next_offset;
    }
    &content[last_rule_end..]
}

fn prompt_box_body(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let Some(top) = prompt_box_top_border_index(&lines) else {
        return "";
    };
    let start = line_start_offset(content, &lines, top + 1);
    let end_index = lines[top + 1..]
        .iter()
        .position(|line| is_horizontal_rule(line))
        .map(|relative| top + 1 + relative)
        .unwrap_or(lines.len());
    let end = line_start_offset(content, &lines, end_index);
    &content[start.min(content.len())..end.min(content.len())]
}

fn has_claude_prompt_line(content: &str) -> bool {
    content
        .lines()
        .any(|line| line.trim_start().starts_with('❯'))
}

fn prompt_box_top_border_index(lines: &[&str]) -> Option<usize> {
    let mut border_count = 0;
    for index in (0..lines.len()).rev() {
        if is_horizontal_rule(lines[index]) {
            border_count += 1;
            if border_count == 2 {
                return Some(index);
            }
        }
    }
    None
}

fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let rule_chars = trimmed.chars().take_while(|ch| *ch == '─').count();
    if rule_chars == 0 {
        return false;
    }
    let rule_bytes = trimmed
        .char_indices()
        .nth(rule_chars)
        .map(|(index, _)| index)
        .unwrap_or(trimmed.len());
    let suffix = trimmed[rule_bytes..].trim_start();
    suffix.is_empty() || rule_chars >= 3
}

fn slice_from_line_index<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    let byte_offset = line_start_offset(content, lines, index);
    &content[byte_offset.min(content.len())..]
}

fn line_start_offset(content: &str, lines: &[&str], index: usize) -> usize {
    lines[..index.min(lines.len())]
        .iter()
        .map(|line| line.len() + 1)
        .sum::<usize>()
        .min(content.len())
}

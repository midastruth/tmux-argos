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
        .is_some_and(is_braille_spinner)
}

fn is_braille_spinner(character: char) -> bool {
    ('\u{2800}'..='\u{28ff}').contains(&character)
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

fn top_non_empty_lines(content: &str, count: usize) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    let end_index = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .take(count)
        .last()
        .map_or(0, |(index, _)| index + 1);
    &content[..line_start_offset(content, &lines, end_index)]
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

fn last_non_empty_above_prompt_box(content: &str) -> Option<&str> {
    let lines: Vec<&str> = content.lines().collect();
    let top = prompt_box_top_border_index(&lines)?;
    lines[..top]
        .iter()
        .rev()
        .find(|line| !line.trim().is_empty())
        .copied()
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

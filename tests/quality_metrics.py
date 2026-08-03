#!/usr/bin/env python3
"""Strict dependency-free structural metrics for Bash and Rust production code."""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

MAX_FILE_LINES = 400
MAX_FUNCTION_LINES = 60
MAX_CYCLOMATIC_COMPLEXITY = 10
MAX_DUPLICATION_PERCENT = 1.0
DUPLICATE_WINDOW_LINES = 8


@dataclass(frozen=True)
class FunctionMetric:
    path: Path
    name: str
    start_line: int
    line_count: int
    complexity: int


def production_files(root: Path) -> list[Path]:
    shell_files = [
        root / "tmux-argos.tmux",
        *sorted((root / "scripts").rglob("*.sh")),
        *sorted((root / "scripts").rglob("*.awk")),
    ]
    rust_files = sorted((root / "daemon" / "src").rglob("*.rs"))
    return [path for path in [*shell_files, *rust_files] if path.is_file()]


def awk_blocks(path: Path, lines: list[str]) -> list[FunctionMetric]:
    metrics: list[FunctionMetric] = []
    index = 0
    while index < len(lines):
        code = lines[index].split("#", 1)[0]
        if "{" not in code:
            index += 1
            continue
        start = index
        name = code.split("{", 1)[0].strip() or "<awk-block>"
        depth = 0
        while index < len(lines):
            block_line = lines[index].split("#", 1)[0]
            depth += block_line.count("{") - block_line.count("}")
            index += 1
            if depth <= 0:
                break
        body = lines[start:index]
        complexity = 1
        for block_line in body:
            complexity += len(re.findall(r"\b(?:if|for|while|do)\b", block_line))
            complexity += block_line.count("&&") + block_line.count("||")
        metrics.append(FunctionMetric(path, name, start + 1, len(body), complexity))
    return metrics


def shell_functions(path: Path, lines: list[str]) -> list[FunctionMetric]:
    if path.suffix == ".awk":
        return awk_blocks(path, lines)

    starts: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{", line)
        if match:
            starts.append((index, match.group(1)))

    metrics: list[FunctionMetric] = []
    for position, (start, name) in enumerate(starts):
        next_start = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        end = next_start
        for index in range(start + 1, next_start):
            if lines[index] == "}":
                end = index + 1
                break
        body = lines[start:end]
        complexity = 1
        in_case = False
        for line in body:
            code = line.split("#", 1)[0]
            complexity += len(re.findall(r"\b(?:if|elif|for|while|until)\b", code))
            complexity += code.count("&&") + code.count("||")
            if re.search(r"\bcase\b.*\bin\s*$", code):
                in_case = True
                continue
            if in_case and re.match(r"^[ \t]+[^#*][^)]*\)[ \t]*(?:[^)]|$)", code):
                complexity += 1
            if in_case and re.match(r"^[ \t]*esac\b", code):
                in_case = False
        metrics.append(FunctionMetric(path, name, start + 1, len(body), complexity))
    return metrics


def strip_rust_non_code(line: str, in_block_comment: bool) -> tuple[str, bool]:
    output: list[str] = []
    index = 0
    in_string = False
    in_character = False
    escaped = False
    while index < len(line):
        pair = line[index : index + 2]
        character = line[index]
        if in_block_comment:
            if pair == "*/":
                in_block_comment = False
                index += 2
            else:
                index += 1
            continue
        if not in_string and not in_character and pair == "/*":
            in_block_comment = True
            index += 2
            continue
        if not in_string and not in_character and pair == "//":
            break
        if escaped:
            escaped = False
            output.append(" ")
            index += 1
            continue
        if (in_string or in_character) and character == "\\":
            escaped = True
            output.append(" ")
            index += 1
            continue
        if not in_character and character == '"':
            in_string = not in_string
            output.append(" ")
            index += 1
            continue
        if not in_string and character == "'":
            if index + 1 < len(line) and re.match(r"[A-Za-z_]", line[index + 1]):
                output.append(character)
            else:
                in_character = not in_character
                output.append(" ")
            index += 1
            continue
        output.append(character if not in_string and not in_character else " ")
        index += 1
    return "".join(output), in_block_comment


def rust_functions(path: Path, lines: list[str]) -> list[FunctionMetric]:
    code_lines: list[str] = []
    in_block_comment = False
    for line in lines:
        code, in_block_comment = strip_rust_non_code(line, in_block_comment)
        code_lines.append(code)

    metrics: list[FunctionMetric] = []
    index = 0
    function_pattern = re.compile(
        r"^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?fn[ \t]+([A-Za-z_][A-Za-z0-9_]*)"
    )
    while index < len(lines):
        match = function_pattern.match(code_lines[index])
        if not match:
            index += 1
            continue
        start = index
        name = match.group(1)
        depth = 0
        body_started = False
        while index < len(lines):
            code = code_lines[index]
            if "{" in code:
                body_started = True
            depth += code.count("{") - code.count("}")
            index += 1
            if body_started and depth <= 0:
                break
        body = code_lines[start:index]
        complexity = 1
        for code in body:
            complexity += len(re.findall(r"\b(?:if|for|while|loop)\b", code))
            complexity += code.count("&&") + code.count("||")
            stripped = code.strip()
            if "=>" in stripped and not stripped.startswith("_ =>"):
                complexity += stripped.count("=>")
        metrics.append(FunctionMetric(path, name, start + 1, len(body), complexity))
    return metrics


def normalized_duplicate_lines(path: Path) -> list[str]:
    normalized: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = re.sub(r"[ \t]+", " ", raw_line.strip())
        if not line or line.startswith(("#", "//")) or line in {"{", "}", ");", "};", "fi", "done"}:
            continue
        normalized.append(line)
    return normalized


def duplication_percent(files: list[Path]) -> float:
    normalized = {path: normalized_duplicate_lines(path) for path in files}
    occurrences: dict[tuple[str, ...], list[tuple[Path, int]]] = defaultdict(list)
    for path, lines in normalized.items():
        for index in range(0, len(lines) - DUPLICATE_WINDOW_LINES + 1):
            window = tuple(lines[index : index + DUPLICATE_WINDOW_LINES])
            occurrences[window].append((path, index))

    duplicated_positions: set[tuple[Path, int]] = set()
    for positions in occurrences.values():
        distinct = set(positions)
        if len(distinct) < 2:
            continue
        for path, start in distinct:
            for offset in range(DUPLICATE_WINDOW_LINES):
                duplicated_positions.add((path, start + offset))
    total_lines = sum(len(lines) for lines in normalized.values())
    if total_lines == 0:
        return 0.0
    return len(duplicated_positions) * 100.0 / total_lines


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    files = production_files(root)
    failures: list[str] = []

    for path in files:
        lines = path.read_text(encoding="utf-8").splitlines()
        relative_path = path.relative_to(root)
        if len(lines) > MAX_FILE_LINES:
            failures.append(f"{relative_path}: {len(lines)} lines exceeds {MAX_FILE_LINES}")
        metrics = rust_functions(path, lines) if path.suffix == ".rs" else shell_functions(path, lines)
        for metric in metrics:
            location = f"{relative_path}:{metric.start_line} {metric.name}"
            if metric.line_count > MAX_FUNCTION_LINES:
                failures.append(f"{location}: {metric.line_count} lines exceeds {MAX_FUNCTION_LINES}")
            if metric.complexity > MAX_CYCLOMATIC_COMPLEXITY:
                failures.append(
                    f"{location}: complexity {metric.complexity} exceeds {MAX_CYCLOMATIC_COMPLEXITY}"
                )

    duplicate_percentage = duplication_percent(files)
    if duplicate_percentage > MAX_DUPLICATION_PERCENT:
        failures.append(
            f"duplicate code: {duplicate_percentage:.2f}% exceeds {MAX_DUPLICATION_PERCENT:.2f}% "
            f"({DUPLICATE_WINDOW_LINES}-line windows)"
        )

    if failures:
        for failure in failures:
            print(f"not ok - {failure}", file=sys.stderr)
        print(f"not ok - strict quality metrics: {len(failures)} violation(s)", file=sys.stderr)
        return 1

    print(
        "ok - strict quality metrics "
        f"(files<={MAX_FILE_LINES}, functions<={MAX_FUNCTION_LINES}, "
        f"complexity<={MAX_CYCLOMATIC_COMPLEXITY}, duplicates={duplicate_percentage:.2f}%)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

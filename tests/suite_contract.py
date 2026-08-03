#!/usr/bin/env python3
"""Guard constitutional gate capabilities and wiring against silent drift."""

from __future__ import annotations

import re
import sys
from pathlib import Path
PROTECTED_PATHS = {
    "tests/architecture.sh",
    "tests/bash_mutation.sh",
    "tests/flaky.sh",
    "tests/gherkin_contract.py",
    "tests/meta.sh",
    "tests/mutation.sh",
    "tests/perf_smoke.sh",
    "tests/quality.sh",
    "tests/quality_metrics.py",
    "tests/security.sh",
    "tests/suite_contract.py",
    "tests/system.sh",
    "tests/test_constitution.mjs",
    "tests/verify.sh",
    "spec",
    "daemon/fixtures",
    ".github/workflows",
    ".github/CODEOWNERS",
    ".pi/extensions/test-constitution.ts",
    "AGENTS.md",
}


def normalized_shell(source: str) -> str:
    return " ".join(source.split())


def require_fragments(path: Path, fragments: dict[str, str], failures: list[str]) -> None:
    source = normalized_shell(path.read_text(encoding="utf-8"))
    for claim, fragment in fragments.items():
        if normalized_shell(fragment) not in source:
            failures.append(f"{path}: missing contract: {claim}")


def require_exact_lines(path: Path, lines: dict[str, str], failures: list[str]) -> None:
    source_lines = {line.strip() for line in path.read_text(encoding="utf-8").splitlines()}
    for claim, expected_line in lines.items():
        if expected_line not in source_lines:
            failures.append(f"{path}: missing exact contract: {claim}")


def workflow_jobs(source: str) -> dict[str, str]:
    jobs: dict[str, list[str]] = {}
    current: str | None = None
    for line in source.splitlines():
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current = match.group(1)
            jobs[current] = []
            continue
        if current is not None:
            jobs[current].append(line)
    return {name: "\n".join(lines) for name, lines in jobs.items()}


def check_fast_gate(root: Path, failures: list[str]) -> None:
    require_fragments(
        root / "tests/verify.sh",
        {
            "Pi constitution behavior": 'node "$ROOT/tests/test_constitution.mjs"',
            "Gherkin bindings": 'python3 "$ROOT/tests/gherkin_contract.py"',
            "suite drift contract": 'python3 "$ROOT/tests/suite_contract.py"',
            "architecture contracts": 'bash "$ROOT/tests/architecture.sh"',
            "quality contracts": 'bash "$ROOT/tests/quality.sh"',
            "ShellCheck": "shellcheck -x",
            "Rust formatting": 'cargo fmt --manifest-path "$ROOT/daemon/Cargo.toml" -- --check',
            "Rust compilation": 'cargo check --manifest-path "$ROOT/daemon/Cargo.toml"',
            "Rust Clippy": 'cargo clippy --manifest-path "$ROOT/daemon/Cargo.toml" --all-targets',
            "Rust behavior": 'cargo test --manifest-path "$ROOT/daemon/Cargo.toml"',
            "Bash behavior": 'bash "$ROOT/tests/run.sh"',
            "falsifier meta-tests": 'bash "$ROOT/tests/meta.sh"',
        },
        failures,
    )
    require_exact_lines(
        root / "tests/verify.sh",
        {"30 second feedback budget": "TIME_BUDGET_SECONDS=30"},
        failures,
    )


def check_deep_gates(root: Path, failures: list[str]) -> None:
    require_fragments(
        root / "tests/perf_smoke.sh",
        {
            "10/50/100 scaling cases": "for n in 10 50 100",
        },
        failures,
    )
    require_exact_lines(
        root / "tests/perf_smoke.sh",
        {
            "20 measured runs": "iterations=20",
            "three warmups": "warmup=3",
            "ten CPU measurements": "cpu_iterations=10",
            "120ms p95 ceiling": "max_picker_ms=120",
            "100ms CPU p95 ceiling": "max_picker_cpu_ms=100",
            "2x growth ceiling": "max_growth=2.0",
            "two tmux call ceiling": "max_tmux_calls=2",
            "one daemon call ceiling": "max_daemon_calls=1",
            "64KiB picker output ceiling": "max_output_bytes=65536",
        },
        failures,
    )
    require_fragments(
        root / "tests/perf_smoke.sh",
        {
            "picker CPU timing": "measure_cpu 'picker.sh --list n=100'",
            "picker tmux I/O accounting": 'tmux_calls="$(awk',
            "Rust allocation gate": "allocation_metrics::state_hot_paths_stay_within_allocation_budgets",
        },
        failures,
    )
    require_exact_lines(
        root / "daemon/src/allocation_metrics.rs",
        {
            "report allocation count": "const MAX_REPORT_ALLOCATIONS: usize = 8;",
            "report allocation bytes": "const MAX_REPORT_BYTES: usize = 512;",
            "snapshot allocation count": "const MAX_SNAPSHOT_ALLOCATIONS: usize = 3_000;",
            "snapshot allocation bytes": "const MAX_SNAPSHOT_BYTES: usize = 192 * 1024;",
        },
        failures,
    )
    require_fragments(
        root / "tests/flaky.sh",
        {
            "twenty stability repetitions": "REPETITIONS=20",
            "Rust stability suite": 'cargo test --manifest-path "$ROOT/daemon/Cargo.toml"',
            "Bash stability suite": 'bash "$ROOT/tests/run.sh"',
        },
        failures,
    )
    require_fragments(
        root / "tests/mutation.sh",
        {
            "pinned mutation tester": "cargo-mutants 27.1.0 is required",
            "state model mutations": "--file 'src/model.rs'",
            "protocol mutations": "--file 'src/protocol.rs'",
            "bounded mutant timeout": "--timeout 30",
            "unseen-completion fault": "unwatched-completion-stays-idle",
            "immutable Rust lifecycle fault": "session-exit-matches-reusable-name",
        },
        failures,
    )
    require_fragments(
        root / "tests/bash_mutation.sh",
        {
            "immutable open fault": "stale-row-opens-reused-name",
            "immutable kill fault": "single-kill-targets-reused-name",
            "blocked-state fault": "daemon-blocked-state-is-unprotected",
            "malformed-state fault": "malformed-daemon-state-is-accepted",
            "native resume fault": "pi-history-loses-native-resume-flag",
            "client detach fault": "popup-detaches-whole-session",
            "zero-fork fault": "status-fragment-adds-a-fork",
            "immutable lifecycle fault": "batch-exit-reports-reusable-name",
        },
        failures,
    )
    require_fragments(
        root / "tests/system.sh",
        {
            "100 concurrent clients": 'for request_number in $(seq 1 "$concurrent_requests")',
            "twenty restart cycles": "for _cycle in $(seq 1 20)",
            "16MiB idle RSS": '"$idle_rss_kib" -le 16384',
            "32MiB pressure RSS": '"$rss_kib" -le 32768',
            "real isolated tmux": 'tmux -L "$SOCKET_NAME" -f /dev/null new-session',
            "cold startup timing": 'startup_started_at="$(now_ns)"',
            "warm request p95": 'warm_request_p95_ms="$(measure_warm_request_p95 || true)"',
            "sustained CPU accounting": 'sustained_cpu_us_per_request="$(awk',
            "sustained RSS accounting": "sustained_rss_growth_kib=",
            "sustained descriptor accounting": 'sustained_fds_before="$(open_fd_count',
            "snapshot I/O accounting": 'snapshot_bytes="$(printf',
        },
        failures,
    )
    require_exact_lines(
        root / "tests/system.sh",
        {
            "100ms cold startup ceiling": "startup_max_ms=100",
            "20 warm request measurements": "warm_request_iterations=20",
            "10ms warm request p95 ceiling": "warm_request_p95_max_ms=10",
            "100 concurrent requests": "concurrent_requests=100",
            "60 second sustained load": "sustained_seconds=60",
            "ten thousand request floor": "sustained_min_requests=10000",
            "5ms sustained request ceiling": "sustained_average_max_ms=5",
            "100us daemon CPU ceiling": "sustained_cpu_max_us_per_request=100",
            "1MiB sustained RSS growth ceiling": "sustained_rss_growth_max_kib=1024",
            "64KiB snapshot ceiling": "snapshot_max_bytes=65536",
        },
        failures,
    )
    require_fragments(
        root / "tests/security.sh",
        {
            "pinned audit tool": "cargo-audit 0.22.2 is required",
            "RustSec audit": 'cargo audit --file "$ROOT/daemon/Cargo.lock"',
            "AWS key detection": "AKIA[0-9A-Z]{16}",
            "GitHub token detection": "gh[pousr]_[A-Za-z0-9]{30,}",
            "private key detection": "PRIVATE KEY-----",
        },
        failures,
    )


def check_ci(root: Path, failures: list[str]) -> None:
    path = root / ".github/workflows/test.yml"
    source = path.read_text(encoding="utf-8")
    jobs = workflow_jobs(source)
    required_jobs = {
        "constitutional-gate": "bash tests/verify.sh",
        "system-gate": "bash tests/system.sh",
        "mutation-gate": "bash tests/mutation.sh",
        "security-gate": "bash tests/security.sh",
        "stability-gate": "bash tests/flaky.sh",
        "performance-gate": "bash tests/perf_smoke.sh",
    }
    for job_name, command in required_jobs.items():
        body = jobs.get(job_name)
        if body is None:
            failures.append(f"{path}: required CI job is missing: {job_name}")
            continue
        if command not in body:
            failures.append(f"{path}: {job_name} no longer runs {command}")
        if job_name != "constitutional-gate" and "needs: constitutional-gate" not in body:
            failures.append(f"{path}: {job_name} no longer depends on constitutional-gate")
    if not re.search(r"^  push:\s*$", source, flags=re.MULTILINE):
        failures.append(f"{path}: push trigger is missing")
    if not re.search(r"^  pull_request:\s*$", source, flags=re.MULTILINE):
        failures.append(f"{path}: pull_request trigger is missing")
    mutation_body = jobs.get("mutation-gate", "")
    if "bash tests/bash_mutation.sh" not in mutation_body:
        failures.append(f"{path}: mutation-gate no longer runs the Bash fault corpus")
    system_body = jobs.get("system-gate", "")
    if "os: [ubuntu-latest, macos-latest]" not in system_body:
        failures.append(f"{path}: Linux/macOS system-test matrix drifted")


def check_protection_boundary(root: Path, failures: list[str]) -> None:
    agents = (root / "AGENTS.md").read_text(encoding="utf-8")
    for protected_path in PROTECTED_PATHS:
        if protected_path not in agents:
            failures.append(f"AGENTS.md: protected path is no longer documented: {protected_path}")

    codeowners = (root / ".github/CODEOWNERS").read_text(encoding="utf-8")
    owned_paths = {
        fields[0].strip("/")
        for line in codeowners.splitlines()
        if (fields := line.split()) and not line.lstrip().startswith("#")
    }
    for protected_path in PROTECTED_PATHS:
        if protected_path not in owned_paths:
            failures.append(f".github/CODEOWNERS: protected path is not owned: {protected_path}")

    extension = (root / ".pi/extensions/test-constitution.ts").read_text(encoding="utf-8")
    match = re.search(r"const PROTECTED_PATHS = \[(.*?)\] as const;", extension, flags=re.DOTALL)
    extension_paths = set(re.findall(r'"([^"]+)"', match.group(1))) if match else set()
    missing_extension_paths = sorted(PROTECTED_PATHS - extension_paths)
    if missing_extension_paths:
        failures.append(
            ".pi/extensions/test-constitution.ts: protection drifted; "
            f"missing={missing_extension_paths}"
        )


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    failures: list[str] = []
    check_fast_gate(root, failures)
    check_deep_gates(root, failures)
    check_ci(root, failures)
    check_protection_boundary(root, failures)
    if failures:
        for failure in failures:
            print(f"not ok - {failure}", file=sys.stderr)
        print(f"not ok - test-suite contract: {len(failures)} drift(s)", file=sys.stderr)
        return 1
    print(f"ok - {6 + 5} test-gate capabilities and wiring boundaries have not drifted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

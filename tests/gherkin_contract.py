#!/usr/bin/env python3
"""Ensure every Gherkin scenario is bound to an executable acceptance test."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def feature_test_ids(features_root: Path) -> list[str]:
    ids: list[str] = []
    pending_id: str | None = None
    for feature_path in sorted(features_root.glob("*.feature")):
        for line_number, line in enumerate(feature_path.read_text().splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("@test-id:"):
                pending_id = stripped.removeprefix("@test-id:").strip()
                if not pending_id:
                    raise ValueError(f"{feature_path}:{line_number}: empty test id")
            if stripped.startswith("Scenario:"):
                if pending_id is None:
                    raise ValueError(f"{feature_path}:{line_number}: scenario has no @test-id")
                ids.append(pending_id)
                pending_id = None
    return ids


def acceptance_map(path: Path) -> dict[str, tuple[str, str]]:
    mappings: dict[str, tuple[str, str]] = {}
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError(f"{path}:{line_number}: expected id, suite, and test name")
        test_id, suite, test_name = fields
        if test_id in mappings:
            raise ValueError(f"{path}:{line_number}: duplicate test id {test_id}")
        if suite not in {"bash", "rust"}:
            raise ValueError(f"{path}:{line_number}: unsupported suite {suite}")
        mappings[test_id] = (suite, test_name)
    return mappings


def rust_test_names(root: Path) -> set[str]:
    names: set[str] = set()
    for path in (root / "daemon" / "src").rglob("*.rs"):
        text = path.read_text()
        names.update(re.findall(r"#\[test\]\s*fn\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    return names


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    try:
        scenario_ids = feature_test_ids(root / "spec" / "features")
        mappings = acceptance_map(root / "spec" / "acceptance-map.tsv")
    except ValueError as error:
        print(f"not ok - {error}", file=sys.stderr)
        return 1

    failures: list[str] = []
    if len(scenario_ids) != len(set(scenario_ids)):
        failures.append("Gherkin test IDs must be unique")
    if set(scenario_ids) != set(mappings):
        missing = sorted(set(scenario_ids) - set(mappings))
        orphaned = sorted(set(mappings) - set(scenario_ids))
        failures.append(f"acceptance map mismatch; missing={missing}, orphaned={orphaned}")

    bash_source = (root / "tests" / "run.sh").read_text()
    rust_names = rust_test_names(root)
    for test_id in scenario_ids:
        suite, test_name = mappings[test_id]
        if suite == "bash" and f"'{test_name}'" not in bash_source:
            failures.append(f"{test_id}: Bash acceptance test is missing: {test_name}")
        if suite == "rust" and test_name not in rust_names:
            failures.append(f"{test_id}: Rust acceptance test is missing: {test_name}")

    if failures:
        for failure in failures:
            print(f"not ok - {failure}", file=sys.stderr)
        return 1
    print(f"ok - {len(scenario_ids)} Gherkin scenarios map to executable acceptance tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

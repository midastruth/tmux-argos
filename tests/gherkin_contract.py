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


def acceptance_map(path: Path) -> dict[str, str]:
    mappings: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise ValueError(f"{path}:{line_number}: expected id and suite")
        test_id, suite = fields
        if test_id in mappings:
            raise ValueError(f"{path}:{line_number}: duplicate test id {test_id}")
        if suite not in {"bash", "rust"}:
            raise ValueError(f"{path}:{line_number}: unsupported suite {suite}")
        mappings[test_id] = suite
    return mappings


def acceptance_markers(root: Path) -> dict[str, list[tuple[str, Path]]]:
    markers: dict[str, list[tuple[str, Path]]] = {}
    marker_pattern = re.compile(r"@acceptance-id:([A-Za-z0-9_-]+)")
    for path in sorted((root / "tests").rglob("*.sh")):
        for test_id in marker_pattern.findall(path.read_text()):
            markers.setdefault(test_id, []).append(("bash", path))
    for path in sorted((root / "daemon" / "src").rglob("*.rs")):
        for test_id in marker_pattern.findall(path.read_text()):
            markers.setdefault(test_id, []).append(("rust", path))
    return markers


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

    markers = acceptance_markers(root)
    for test_id in scenario_ids:
        expected_suite = mappings[test_id]
        bindings = markers.get(test_id, [])
        if len(bindings) != 1:
            failures.append(f"{test_id}: expected one acceptance marker, found {bindings}")
            continue
        actual_suite, marker_path = bindings[0]
        if actual_suite != expected_suite:
            failures.append(
                f"{test_id}: expected {expected_suite} marker, found {actual_suite} in {marker_path}"
            )

    if failures:
        for failure in failures:
            print(f"not ok - {failure}", file=sys.stderr)
        return 1
    print(f"ok - {len(scenario_ids)} Gherkin scenarios map to executable acceptance tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

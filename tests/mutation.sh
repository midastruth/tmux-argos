#!/usr/bin/env bash
# Critical state and protocol mutations must all be caught. cargo-mutants exits
# non-zero for any viable survivor, which is stricter than the 95% critical-path
# minimum.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMPDIR:-/tmp}/tmux-argos-mutants.$$"

cleanup() {
  rm -rf "$OUTPUT"
}
trap cleanup EXIT
mkdir -p "$OUTPUT"

if ! cargo mutants --version >/dev/null 2>&1; then
  printf 'not ok - cargo-mutants 27.1.0 is required\n' >&2
  exit 1
fi

replace_once() {
  local path="$1" old_text="$2" new_text="$3"
  python3 - "$path" "$old_text" "$new_text" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
old_text = sys.argv[2]
new_text = sys.argv[3]
source = path.read_text()
count = source.count(old_text)
if count != 1:
    raise SystemExit(f"expected one mutation target in {path}, found {count}")
path.write_text(source.replace(old_text, new_text))
PY
}

run_seeded_mutant() {
  local name="$1" relative_path="$2" old_text="$3" new_text="$4"
  local fixture="$OUTPUT/seeded-$name"
  mkdir -p "$fixture"
  cp "$ROOT/daemon/Cargo.toml" "$ROOT/daemon/Cargo.lock" "$fixture/"
  cp -R "$ROOT/daemon/src" "$fixture/src"
  replace_once "$fixture/$relative_path" "$old_text" "$new_text" || return 1
  if ! CARGO_TARGET_DIR="$OUTPUT/seeded-target" cargo check \
    --manifest-path "$fixture/Cargo.toml" >/dev/null 2>&1; then
    printf 'not ok - seeded Rust mutant did not compile: %s\n' "$name" >&2
    return 1
  fi
  if CARGO_TARGET_DIR="$OUTPUT/seeded-target" cargo test \
    --manifest-path "$fixture/Cargo.toml" >/dev/null 2>&1; then
    printf 'not ok - surviving seeded Rust mutant: %s\n' "$name" >&2
    return 1
  fi
  printf 'ok - Rust behavior tests killed seeded mutant: %s\n' "$name"
}

if ! cargo mutants --manifest-path "$ROOT/daemon/Cargo.toml" \
  --jobs 4 \
  --timeout 30 \
  --output "$OUTPUT/cargo-mutants" \
  --file 'src/model.rs' \
  --file 'src/protocol.rs'; then
  exit 1
fi

run_seeded_mutant \
  'unwatched-completion-stays-idle' \
  'src/model/state_scan.rs' \
  $'        if pane_visible {\n            AgentState::Idle\n        } else {\n            AgentState::Done\n        }' \
  $'        if pane_visible {\n            AgentState::Idle\n        } else {\n            AgentState::Idle\n        }' || exit 1

run_seeded_mutant \
  'session-exit-matches-reusable-name' \
  'src/model/state_events.rs' \
  'let same_session = session_id.is_some_and(|session| record.session_id == session);' \
  'let same_session = session_id.is_some_and(|session| record.session_name == session);' || exit 1

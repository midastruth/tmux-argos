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

if ! cargo mutants --version >/dev/null 2>&1; then
  printf 'not ok - cargo-mutants 27.1.0 is required\n' >&2
  exit 1
fi

cargo mutants --manifest-path "$ROOT/daemon/Cargo.toml" \
  --jobs 4 \
  --timeout 30 \
  --output "$OUTPUT" \
  --file 'src/model.rs' \
  --file 'src/protocol.rs'

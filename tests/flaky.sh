#!/usr/bin/env bash
# A test that fails once in twenty identical runs is not accepted as stable.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPETITIONS=20

for iteration in $(seq 1 "$REPETITIONS"); do
  printf 'stability run %02d/%02d\n' "$iteration" "$REPETITIONS"
  cargo test --manifest-path "$ROOT/daemon/Cargo.toml" >/dev/null || exit 1
  bash "$ROOT/tests/run.sh" >/dev/null || exit 1
done
printf 'ok - Rust and Bash tests passed %d consecutive runs\n' "$REPETITIONS"

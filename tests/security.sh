#!/usr/bin/env bash
# Dependency advisories and high-confidence committed-secret signatures are
# binary gates: no known finding is accepted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! cargo audit --version >/dev/null 2>&1; then
  printf 'not ok - cargo-audit 0.22.2 is required\n' >&2
  exit 1
fi

cargo audit --file "$ROOT/daemon/Cargo.lock" || exit 1

secret_pattern='AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----'
secret_matches="$(
  grep -R -I -n -E \
    --exclude='security.sh' \
    --exclude-dir='.git' \
    --exclude-dir='target' \
    "$secret_pattern" "$ROOT" 2>/dev/null || true
)"
if [ -n "$secret_matches" ]; then
  printf 'not ok - committed secret signature detected:\n%s\n' "$secret_matches" >&2
  exit 1
fi
printf 'ok - no RustSec advisory or committed secret signature found\n'

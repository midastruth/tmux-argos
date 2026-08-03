#!/usr/bin/env bash
# Executable architecture contracts for production code.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FAILURES=0

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'not ok - %s\n' "$1" >&2
}

pass() {
  printf 'ok - %s\n' "$1"
}

required_paths='tmux-argos.tmux
scripts/daemon.sh
scripts/event.sh
scripts/helpers.sh
scripts/launch_menu.sh
scripts/launch.sh
scripts/list.sh
scripts/picker.sh
scripts/status_click.sh
scripts/picker/common.sh
scripts/picker/rows.sh
scripts/picker/actions.sh
scripts/lib/resolve_pane_agent.awk
scripts/lib/validate_picker_rows.awk
scripts/lib/join_protected_sessions.awk
daemon/src/main.rs
daemon/src/model.rs
daemon/src/model/screen_detection.rs
daemon/src/model/screen_io.rs
daemon/src/model/state_events.rs
daemon/src/model/state_output.rs
daemon/src/model/state_scan.rs
daemon/src/model/tests_detection.rs
daemon/src/model/tests_state.rs
daemon/src/protocol.rs
daemon/src/bin/tmux-argos-history.rs
daemon/src/bin/history/files.rs
daemon/src/bin/history/preview.rs
daemon/src/bin/history/records.rs
daemon/src/bin/history/tests.rs'

while IFS= read -r relative_path; do
  if [ ! -f "$ROOT/$relative_path" ]; then
    fail "required production boundary is missing: $relative_path"
  fi
done <<EOF
$required_paths
EOF

# helpers.sh is the shared base library. picker.sh is the sole composition root
# allowed to source the three responsibility-specific picker modules; those
# modules cannot source one another, which keeps the graph acyclic.
source_dependency_allowed() {
  local relative_path="$1" source_line="$2"
  case "$source_line" in
  *helpers.sh*) return 0 ;;
  esac
  if [ "$relative_path" = scripts/picker.sh ]; then
    case "$source_line" in
    *picker/common.sh*|*picker/rows.sh*|*picker/actions.sh*) return 0 ;;
    esac
  fi
  return 1
}

source_contract_failed=0
while IFS= read -r shell_file; do
  relative_path="${shell_file#"$ROOT/"}"
  while IFS= read -r source_line; do
    [ -n "$source_line" ] || continue
    if ! source_dependency_allowed "$relative_path" "$source_line"; then
      printf 'architecture: %s has forbidden source dependency: %s\n' \
        "$relative_path" "$source_line" >&2
      source_contract_failed=1
    fi
  done < <(grep -E '^[[:space:]]*(\.|source)[[:space:]]+' "$shell_file" 2>/dev/null || true)
done < <(find "$ROOT/scripts" -type f -name '*.sh' -print; printf '%s\n' "$ROOT/tmux-argos.tmux")
if [ "$source_contract_failed" -eq 0 ]; then
  pass 'Bash source dependency graph is acyclic and follows composition boundaries'
else
  fail 'Bash source dependency contract was violated'
fi

# Production code must never depend on mocks or test helpers.
if grep -R -n -E '(^|[^[:alnum:]_])tests/' \
  "$ROOT/tmux-argos.tmux" "$ROOT/scripts" "$ROOT/daemon/src" >/dev/null 2>&1; then
  fail 'production code depends on the tests boundary'
else
  pass 'production code is independent of tests'
fi

# Rust dependency direction is main -> model -> protocol. protocol is the
# innermost boundary and therefore imports no other crate-local module.
if grep -n -E 'crate::(model|main)(::|\{)' "$ROOT/daemon/src/protocol.rs" >/dev/null 2>&1; then
  fail 'protocol.rs depends on an outer Rust module'
else
  pass 'protocol.rs is an inward dependency boundary'
fi

unexpected_model_dependency="$(
  grep -Eo 'crate::[[:alnum:]_]+' "$ROOT/daemon/src/model.rs" 2>/dev/null |
    grep -v '^crate::protocol$' || true
)"
if [ -n "$unexpected_model_dependency" ]; then
  printf '%s\n' "$unexpected_model_dependency" >&2
  fail 'model.rs depends on a Rust module other than protocol'
else
  pass 'model.rs depends only on protocol'
fi

module_declaration_failed=0
while IFS= read -r rust_file; do
  [ "$rust_file" = "$ROOT/daemon/src/main.rs" ] && continue
  if grep -n -E '^[[:space:]]*(pub[[:space:]]+)?mod[[:space:]]+(model|protocol)[[:space:]]*;' \
    "$rust_file" >/dev/null 2>&1; then
    printf 'architecture: forbidden module root in %s\n' "${rust_file#"$ROOT/"}" >&2
    module_declaration_failed=1
  fi
done < <(find "$ROOT/daemon/src" -type f -name '*.rs' -print)
if [ "$module_declaration_failed" -eq 0 ]; then
  pass 'main.rs is the only Rust composition root'
else
  fail 'a second Rust composition root was introduced'
fi

if [ "$FAILURES" -gt 0 ]; then
  printf 'not ok - architecture contracts: %s violation(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'ok - architecture contracts\n'

#!/usr/bin/env bats
# Tests for run-shellcheck.sh with a stub shellcheck binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-shellcheck.sh"
  WORK=$(mktemp -d)
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/shellcheck" <<'STUB'
#!/bin/sh
for f; do :; done
case "$f" in *bad.sh) echo boom >&2; exit 3 ;; esac
printf '{"comments":[{"file":"%s","line":2,"level":"warning","code":2086,"message":"Double quote to prevent globbing."}]}\n' "$f"
exit 1
STUB
  chmod +x "$WORK/bin/shellcheck"
}

teardown() {
  rm -rf "$WORK"
}

@test "shellcheck: findings from every file are merged" {
  touch "$WORK/a.sh" "$WORK/c.sh"
  cd "$WORK"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' a.sh c.sh)"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(.file) == ["a.sh", "c.sh"] and all(.[]; .severity == "Medium" and .line == 2)' >/dev/null
}

@test "shellcheck: a failing file is exit 1 and still emits the other files' findings" {
  touch "$WORK/a.sh" "$WORK/bad.sh" "$WORK/c.sh"
  cd "$WORK"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' a.sh bad.sh c.sh)"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e 'map(.file) == ["a.sh", "c.sh"]' >/dev/null
  [[ "$stderr" == *"shellcheck failed on bad.sh (exit 3)"* ]]
}

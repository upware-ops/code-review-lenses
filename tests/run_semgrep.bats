#!/usr/bin/env bats
# Tests for run-semgrep.sh. Uses SEMGREP_MOCK_FILE or a stub semgrep on PATH.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-semgrep.sh"
  SEMGREP_FIX="${FIXTURES_DIR}/semgrep"
  WORK=$(mktemp -d)
  touch "$WORK/app.py"
}

teardown() {
  rm -rf "$WORK"
}

@test "semgrep: results map to findings with exit 0" {
  SEMGREP_MOCK_FILE="$SEMGREP_FIX/semgrep-findings.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1' >/dev/null
  echo "$output" | jq -e '.[0].severity == "Medium" and .[0].source == "semgrep" and .[0].file == "app.py" and .[0].line == 3' >/dev/null
}

@test "semgrep: reported errors keep the findings and exit 1" {
  SEMGREP_MOCK_FILE="$SEMGREP_FIX/semgrep-partial-parse.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e 'length == 1' >/dev/null
}

@test "semgrep: unparseable output is exit 1 with empty array" {
  echo 'not json' > "$WORK/garbage.json"
  SEMGREP_MOCK_FILE="$WORK/garbage.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "semgrep: non-zero exit with error-free JSON is exit 1" {
  unset SEMGREP_MOCK_FILE
  mkdir -p "$WORK/bin"
  printf '%s\n' '#!/bin/sh' "echo '{\"results\":[],\"errors\":[]}'" 'exit 2' > "$WORK/bin/semgrep"
  chmod +x "$WORK/bin/semgrep"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

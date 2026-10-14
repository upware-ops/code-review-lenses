#!/usr/bin/env bats
# Tests for run-ruff.sh. Uses RUFF_MOCK_FILE to bypass the binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-ruff.sh"
  RUFF_FIX="${FIXTURES_DIR}/ruff"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# File extension matching
# ---------------------------------------------------------------------------

@test "ruff: non-Python file returns empty array" {
  touch "$WORK/notes.txt"
  RUFF_MOCK_FILE="$RUFF_FIX/ruff-findings.json" run --separate-stderr "$SCRIPT" "$WORK/notes.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "ruff: .py extension triggers scan" {
  touch "$WORK/app.py"
  RUFF_MOCK_FILE="$RUFF_FIX/ruff-findings.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].source == "ruff"' >/dev/null
}

@test "ruff: .pyw extension triggers scan" {
  touch "$WORK/gui.pyw"
  RUFF_MOCK_FILE="$RUFF_FIX/ruff-findings.json" run --separate-stderr "$SCRIPT" "$WORK/gui.pyw"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].source == "ruff"' >/dev/null
}

#!/usr/bin/env bats
# Tests for run-golangci-lint.sh. Uses GOLANGCI_MOCK_FILE to bypass the binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-golangci-lint.sh"
  GOLANGCI_FIX="${FIXTURES_DIR}/golangci"
  WORK=$(mktemp -d)
  touch "$WORK/main.go"
}

teardown() {
  rm -rf "$WORK"
}

@test "golangci-lint: issues map to findings with exit 0" {
  GOLANGCI_MOCK_FILE="$GOLANGCI_FIX/golangci-findings.json" run --separate-stderr "$SCRIPT" "$WORK/main.go"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1' >/dev/null
  echo "$output" | jq -e '.[0].severity == "High" and .[0].source == "golangci-lint" and .[0].file == "main.go" and .[0].line == 10' >/dev/null
}

@test "golangci-lint: unparseable output is exit 1 with empty array" {
  echo 'not json' > "$WORK/garbage.json"
  GOLANGCI_MOCK_FILE="$WORK/garbage.json" run --separate-stderr "$SCRIPT" "$WORK/main.go"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

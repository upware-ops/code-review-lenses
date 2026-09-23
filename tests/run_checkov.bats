#!/usr/bin/env bats
# Tests for run-checkov.sh. Uses CHECKOV_MOCK_FILE with --quiet-shaped JSON.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-checkov.sh"
  CHECKOV_FIX="${FIXTURES_DIR}/checkov"
  WORK=$(mktemp -d)
  touch "$WORK/main.tf"
}

teardown() {
  rm -rf "$WORK"
}

@test "checkov: failed checks without parsing errors exit 0" {
  jq 'map(.summary.parsing_errors = 0)' "$CHECKOV_FIX/checkov-quiet-parse-error.json" > "$WORK/clean.json"
  CHECKOV_MOCK_FILE="$WORK/clean.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].severity == "High" and .[0].file == "main.tf"' >/dev/null
  echo "$output" | jq -e '.[0].finding == "CKV_SECRET_6: Base64 High Entropy String"' >/dev/null
}

@test "checkov: summary parsing errors keep the findings and exit 1" {
  CHECKOV_MOCK_FILE="$CHECKOV_FIX/checkov-quiet-parse-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e 'length == 1 and .[0].severity == "High"' >/dev/null
}

#!/usr/bin/env bats
# Tests for run-phpcs.sh. Uses PHPCS_MOCK_FILE to bypass the binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-phpcs.sh"
  PHPCS_FIX="${FIXTURES_DIR}/phpcs"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# No-op paths
# ---------------------------------------------------------------------------

@test "phpcs: empty input returns empty array" {
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-empty.json" run --separate-stderr "$SCRIPT" ""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "phpcs: non-PHP file returns empty array" {
  touch "$WORK/app.py"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-empty.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "phpcs: nonexistent PHP file returns empty array" {
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-empty.json" run --separate-stderr "$SCRIPT" "nonexistent/file.php"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "phpcs: empty files object returns empty array" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-empty.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "phpcs: malformed output falls through safely" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-malformed.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "phpcs: binary missing returns empty array" {
  unset PHPCS_MOCK_FILE
  run --separate-stderr "$SCRIPT" "src/module.php"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# File extension matching
# ---------------------------------------------------------------------------

@test "phpcs: .php extension triggers scan" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

@test "phpcs: .module extension triggers scan" {
  touch "$WORK/my_module.module"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/my_module.module"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Severity mapping
# ---------------------------------------------------------------------------

@test "phpcs: type ERROR maps to High" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "High"' >/dev/null
}

@test "phpcs: type WARNING maps to Medium" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-warning.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "Medium"' >/dev/null
}

# ---------------------------------------------------------------------------
# Schema conformance
# ---------------------------------------------------------------------------

@test "phpcs: findings conform to required schema" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    all(.[]; has("severity") and has("confidence") and has("source")
        and has("file") and has("line") and has("finding") and has("remediation"))
  ' >/dev/null
}

@test "phpcs: source field is phpcs on all findings" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .source == "phpcs")' >/dev/null
}

@test "phpcs: confidence is 90 on all findings" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .confidence == 90)' >/dev/null
}

@test "phpcs: finding text contains sniff source" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | test("Generic.PHP.UpperCaseConstant")' >/dev/null
}

# ---------------------------------------------------------------------------
# stdin input contract
# ---------------------------------------------------------------------------

@test "phpcs: accepts file list via stdin" {
  touch "$WORK/module.php"
  PHPCS_MOCK_FILE="$PHPCS_FIX/phpcs-error.json" run --separate-stderr bash -c \
    "echo '$WORK/module.php' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Live exit codes (stub phpcs on PATH)
# ---------------------------------------------------------------------------

@test "phpcs: live exit 2 with a JSON report yields findings" {
  unset PHPCS_MOCK_FILE
  mkdir -p "$WORK/bin"
  printf '%s\n' '#!/bin/sh' '[ "$1" = "-i" ] && exit 0' "cat '$PHPCS_FIX/phpcs-error.json'" 'exit 2' > "$WORK/bin/phpcs"
  chmod +x "$WORK/bin/phpcs"
  touch "$WORK/module.php"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

@test "phpcs: live exit 3 with error text fails closed" {
  unset PHPCS_MOCK_FILE
  mkdir -p "$WORK/bin"
  printf '%s\n' '#!/bin/sh' '[ "$1" = "-i" ] && exit 0' 'echo "ERROR: the \"PSR12\" coding standard is not installed."' 'exit 3' > "$WORK/bin/phpcs"
  chmod +x "$WORK/bin/phpcs"
  touch "$WORK/module.php"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "phpcs: live exit above 3, or non-zero with empty stdout, hits the failure branch" {
  unset PHPCS_MOCK_FILE
  mkdir -p "$WORK/bin"
  touch "$WORK/module.php"
  printf '%s\n' '#!/bin/sh' '[ "$1" = "-i" ] && exit 0' "cat '$PHPCS_FIX/phpcs-error.json'" 'exit 16' > "$WORK/bin/phpcs"
  chmod +x "$WORK/bin/phpcs"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"phpcs failed (exit 16)"* ]]
  printf '%s\n' '#!/bin/sh' '[ "$1" = "-i" ] && exit 0' 'exit 2' > "$WORK/bin/phpcs"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/module.php"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"phpcs failed (exit 2)"* ]]
}

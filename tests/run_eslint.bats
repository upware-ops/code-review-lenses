#!/usr/bin/env bats
# Tests for run-eslint.sh. Uses ESLINT_MOCK_FILE to bypass the binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-eslint.sh"
  ESLINT_FIX="${FIXTURES_DIR}/eslint"
  WORK=$(mktemp -d)
  # Create a minimal ESLint config so the no-config check does not block.
  # Set GITHUB_WORKSPACE so config detection finds it regardless of test CWD.
  touch "$WORK/.eslintrc.json"
  export GITHUB_WORKSPACE="$WORK"
}

teardown() {
  rm -rf "$WORK"
  unset GITHUB_WORKSPACE
}

# Stub eslint at $1: logs "<cwd>|<argv0>|<args>" to $ESLINT_LOG and reports one finding for its last argument.
make_eslint_stub() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" << 'EOF'
#!/bin/sh
case "$*" in *--help*) echo "--no-warn-ignored"; exit 0 ;; esac
printf '%s|%s|%s\n' "$PWD" "$0" "$*" >> "$ESLINT_LOG"
for last; do :; done
printf '[{"filePath":"%s","messages":[{"ruleId":"no-undef","severity":2,"message":"x","line":1}]}]\n' "$last"
exit 1
EOF
  chmod +x "$1"
  export ESLINT_LOG="$WORK/eslint.log"
}

# ---------------------------------------------------------------------------
# No-op paths
# ---------------------------------------------------------------------------

@test "eslint: empty input returns empty array" {
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-empty.json" run --separate-stderr "$SCRIPT" ""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "eslint: non-JS/TS file returns empty array" {
  touch "$WORK/app.py"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-empty.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "eslint: nonexistent JS file returns empty array" {
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-empty.json" run --separate-stderr "$SCRIPT" "nonexistent/file.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "eslint: empty mock output returns empty array" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-empty.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "eslint: malformed output falls through safely" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-malformed.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "eslint: binary missing returns empty array" {
  unset ESLINT_MOCK_FILE
  # No node_modules and npx not available in CI PATH for eslint; expects skip.
  run --separate-stderr "$SCRIPT" "src/app.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "eslint: missing config warns on stderr instead of passing as a clean scan" {
  mkdir -p "$WORK/noconf/node_modules/.bin"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/noconf/node_modules/.bin/eslint"
  chmod +x "$WORK/noconf/node_modules/.bin/eslint"
  echo 'var x' > "$WORK/noconf/x.js"
  unset ESLINT_MOCK_FILE
  cd "$WORK/noconf"
  GITHUB_WORKSPACE="$WORK/noconf" run --separate-stderr bash "$SCRIPT" "$WORK/noconf/x.js"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"WARNING: no ESLint config in $WORK/noconf"* ]]
}

# ---------------------------------------------------------------------------
# File extension matching
# ---------------------------------------------------------------------------

@test "eslint: .tsx extension triggers scan" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

@test "eslint: .ts extension triggers scan" {
  touch "$WORK/utils.ts"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/utils.ts"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

@test "eslint: .mjs extension triggers scan" {
  touch "$WORK/config.mjs"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/config.mjs"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Severity mapping
# ---------------------------------------------------------------------------

@test "eslint: severity 2 (error) maps to High" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "High"' >/dev/null
}

@test "eslint: severity 1 (warning) maps to Medium" {
  touch "$WORK/format.ts"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-warning.json" run --separate-stderr "$SCRIPT" "$WORK/format.ts"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "Medium"' >/dev/null
}

# ---------------------------------------------------------------------------
# Messages without a ruleId
# ---------------------------------------------------------------------------

@test "eslint: fatal parse error is kept as a High finding" {
  touch "$WORK/broken.js"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-parse-error.json" run --separate-stderr "$SCRIPT" "$WORK/broken.js"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].severity == "High" and .[0].line == 1' >/dev/null
  echo "$output" | jq -e '.[0].finding | startswith("parse-error: Parsing error")' >/dev/null
  echo "$output" | jq -e '.[0].remediation | contains("parsing error") and (contains("eslint.org") | not)' >/dev/null
}

@test "eslint: non-fatal null-rule messages such as ignored-file warnings are dropped" {
  touch "$WORK/ignored.js"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-ignored.json" run --separate-stderr "$SCRIPT" "$WORK/ignored.js"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# Schema conformance
# ---------------------------------------------------------------------------

@test "eslint: findings conform to required schema" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    all(.[]; has("severity") and has("confidence") and has("source")
        and has("file") and has("line") and has("finding") and has("remediation"))
  ' >/dev/null
}

@test "eslint: source field is eslint on all findings" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .source == "eslint")' >/dev/null
}

@test "eslint: confidence is 90 on all findings" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .confidence == 90)' >/dev/null
}

@test "eslint: finding text contains rule ID" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | test("no-unused-vars")' >/dev/null
}

@test "eslint: remediation includes eslint.org docs URL" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr "$SCRIPT" "$WORK/Button.tsx"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].remediation | test("eslint.org")' >/dev/null
}

# ---------------------------------------------------------------------------
# stdin input contract
# ---------------------------------------------------------------------------

@test "eslint: live run with no --no-warn-ignored does not unbound-abort" {
  mkdir -p "$WORK/node_modules/.bin"
  cat > "$WORK/node_modules/.bin/eslint" << 'EOF'
#!/bin/sh
if echo "$*" | grep -q -- --help; then
  echo "eslint"
  exit 0
fi
printf '%s\n' '[{"filePath":"x.js","messages":[{"ruleId":"no-undef","severity":2,"message":"x","line":1}]}]'
exit 1
EOF
  chmod +x "$WORK/node_modules/.bin/eslint"
  echo 'var x' > "$WORK/x.js"
  unset ESLINT_MOCK_FILE
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK" run --separate-stderr bash "$SCRIPT" "$WORK/x.js"
  [[ "${stderr:-}" != *"unbound variable"* ]]
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | test("no-undef")' >/dev/null
}

@test "eslint: pins the reviewer's config so configs beside linted files never load" {
  mkdir -p "$WORK/node_modules/.bin" "$WORK/pr/src"
  cat > "$WORK/node_modules/.bin/eslint" <<'EOF'
#!/bin/sh
if echo "$*" | grep -q -- --help; then
  echo "--no-warn-ignored"
  exit 0
fi
printf '%s\n' "$@" > "$ARGV_FILE"
echo '[]'
EOF
  chmod +x "$WORK/node_modules/.bin/eslint"
  echo 'var x' > "$WORK/pr/src/app.js"
  touch "$WORK/pr/src/.eslintrc.cjs" "$WORK/pr/src/eslint.config.js"
  unset ESLINT_MOCK_FILE
  cd "$WORK"
  ARGV_FILE="$WORK/argv" run --separate-stderr bash "$SCRIPT" "$WORK/pr/src/app.js"
  [ "$status" -eq 0 ]
  grep -qx -- '--no-eslintrc' "$WORK/argv"
  [ "$(grep -A1 -x -- '--config' "$WORK/argv" | tail -1)" = "$WORK/.eslintrc.json" ]
  touch "$WORK/eslint.config.js"
  ARGV_FILE="$WORK/argv" run --separate-stderr bash "$SCRIPT" "$WORK/pr/src/app.js"
  [ "$status" -eq 0 ]
  [ "$(grep -c -x -- '--no-eslintrc' "$WORK/argv")" -eq 0 ]
  [ "$(grep -A1 -x -- '--config' "$WORK/argv" | tail -1)" = "$WORK/eslint.config.js" ]
}

@test "eslint: a flat config lints checkout files only and warns once naming the files outside the checkout" {
  unset ESLINT_MOCK_FILE
  make_eslint_stub "$WORK/node_modules/.bin/eslint"
  mkdir -p "$BATS_TEST_TMPDIR/pr"
  touch "$WORK/eslint.config.js" "$WORK/local.js" "$WORK/abs.js" "$BATS_TEST_TMPDIR/pr/a.js" "$BATS_TEST_TMPDIR/pr/b.js"
  cd "$WORK"
  run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' "$BATS_TEST_TMPDIR/pr/a.js" local.js "$WORK/abs.js" "$BATS_TEST_TMPDIR/pr/b.js")"
  [ "$status" -eq 0 ]
  [ "$(cat "$ESLINT_LOG")" = "$WORK|$WORK/node_modules/.bin/eslint|--format json --config $WORK/eslint.config.js --no-warn-ignored local.js $WORK/abs.js" ]
  echo "$output" | jq -e 'map(.file) == ["abs.js"]' >/dev/null
  [ "$(printf '%s\n' "$stderr" | grep -c '')" -eq 1 ]
  [[ "$stderr" == "WARNING: eslint: not linting 2 file(s) outside the reviewer checkout with a flat config"*"): $BATS_TEST_TMPDIR/pr/a.js $BATS_TEST_TMPDIR/pr/b.js" ]]
}

@test "eslint: a flat config with only files outside the checkout warns and does not run eslint" {
  unset ESLINT_MOCK_FILE
  make_eslint_stub "$WORK/node_modules/.bin/eslint"
  touch "$WORK/eslint.config.js" "$BATS_TEST_TMPDIR/x.js"
  cd "$WORK"
  run --separate-stderr bash "$SCRIPT" "$BATS_TEST_TMPDIR/x.js"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == "WARNING: eslint: not linting 1 file(s) outside the reviewer checkout with a flat config"*"): $BATS_TEST_TMPDIR/x.js" ]]
  [ ! -e "$ESLINT_LOG" ]
}

@test "eslint: a changed file whose relative path starts with - is passed as a path, not an option" {
  unset ESLINT_MOCK_FILE
  make_eslint_stub "$WORK/node_modules/.bin/eslint"
  cd "$WORK"
  touch -- "--config=evil.js"
  run --separate-stderr bash "$SCRIPT" "--config=evil.js"
  [ "$status" -eq 0 ]
  [[ "$(cat "$ESLINT_LOG")" == *" --no-warn-ignored ./--config=evil.js" ]]
}

@test "eslint: a legacy config still lints files outside the checkout, from the checkout" {
  unset ESLINT_MOCK_FILE
  make_eslint_stub "$WORK/node_modules/.bin/eslint"
  touch "$BATS_TEST_TMPDIR/x.js"
  cd "$WORK"
  run --separate-stderr bash "$SCRIPT" "$BATS_TEST_TMPDIR/x.js"
  [ "$status" -eq 0 ]
  [ "$(cat "$ESLINT_LOG")" = "$WORK|$WORK/node_modules/.bin/eslint|--format json --no-eslintrc --config $WORK/.eslintrc.json --no-warn-ignored $BATS_TEST_TMPDIR/x.js" ]
  echo "$output" | jq -e --arg f "$BATS_TEST_TMPDIR/x.js" 'map(.file) == [$f]' >/dev/null
  [ -z "$stderr" ]
}

@test "eslint: the npx fallback runs the eslint that npx resolves, by absolute path" {
  unset ESLINT_MOCK_FILE
  make_eslint_stub "$WORK/hoisted/eslint"
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\n[ "$*" = "--no -c command -v eslint" ] && echo "%s"\n' "$WORK/hoisted/eslint" > "$WORK/bin/npx"
  chmod +x "$WORK/bin/npx"
  touch "$WORK/local.js"
  cd "$WORK"
  PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" local.js
  [ "$status" -eq 0 ]
  [[ "$(cat "$ESLINT_LOG")" == "$WORK|$WORK/hoisted/eslint|"*" local.js" ]]
}

@test "eslint: an npx that cannot resolve eslint skips with a warning and never runs npx eslint" {
  unset ESLINT_MOCK_FILE
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/npx" << 'EOF'
#!/bin/sh
echo "$*" >> "$NPX_LOG"
case "$*" in "--no -c "*) exit 1 ;; esac
exit 0
EOF
  chmod +x "$WORK/bin/npx"
  touch "$WORK/local.js"
  cd "$WORK"
  NPX_LOG="$WORK/npx.log" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" local.js
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"eslint not found"* ]]
  [ "$(cat "$WORK/npx.log")" = "--no -c command -v eslint" ]
}

@test "eslint: accepts file list via stdin" {
  touch "$WORK/Button.tsx"
  ESLINT_MOCK_FILE="$ESLINT_FIX/eslint-error.json" run --separate-stderr bash -c \
    "echo '$WORK/Button.tsx' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

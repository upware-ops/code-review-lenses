#!/usr/bin/env bats
# Tests for evaluate-gates.sh.
# Creates temp diff files and file-path lists and asserts the correct gate values.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/evaluate-gates.sh"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# Helper: run the gate script with custom DIFF_FILE content and DIFF_PATHS list.
run_gates() {
  local diff_content="$1" diff_paths="$2"
  local diff_file="${WORK}/test.diff"
  printf '%s\n' "$diff_content" > "$diff_file"
  DIFF_FILE="$diff_file" DIFF_PATHS="$diff_paths" run bash "$SCRIPT"
}

# Parse a gate flag value from sourced output (e.g., "GATE_ERROR_PATTERNS=true" → "true").
gate_value() {
  local gate_name="$1"
  echo "$output" | grep "^${gate_name}=" | cut -d= -f2
}

# ---------------------------------------------------------------------------
# Fallback behavior
# ---------------------------------------------------------------------------

@test "gates: missing DIFF_FILE defaults all gates to true" {
  DIFF_FILE="" DIFF_PATHS="src/foo.go" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_ERROR_PATTERNS)" = "true" ]
  [ "$(gate_value GATE_CONTROL_FLOW)" = "true" ]
  [ "$(gate_value GATE_SECURITY_PATTERNS)" = "true" ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "true" ]
  [ "$(gate_value GATE_TEST_PATHS)" = "true" ]
  [ "$(gate_value GATE_COMMENT_CHANGES)" = "true" ]
  [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "true" ]
}

@test "gates: nonexistent DIFF_FILE defaults all gates to true" {
  DIFF_FILE="/nonexistent/path.diff" DIFF_PATHS="src/foo.go" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_ERROR_PATTERNS)" = "true" ]
}

# ---------------------------------------------------------------------------
# GATE_ERROR_PATTERNS
# ---------------------------------------------------------------------------

@test "gates: diff with 'if err' triggers GATE_ERROR_PATTERNS" {
  run_gates $'+if err != nil {\n+  return err\n+}' "src/main.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_ERROR_PATTERNS)" = "true" ]
}

@test "gates: diff with 'catch' triggers GATE_ERROR_PATTERNS" {
  run_gates $'+} catch (Exception e) {\n+  log.error(e);\n+}' "src/Service.java"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_ERROR_PATTERNS)" = "true" ]
}

@test "gates: pure docs diff does not trigger GATE_ERROR_PATTERNS" {
  run_gates "+Updated README content with no code" "README.md"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_ERROR_PATTERNS)" = "false" ]
}

# ---------------------------------------------------------------------------
# GATE_CONTROL_FLOW
# ---------------------------------------------------------------------------

@test "gates: diff with added 'if' statement triggers GATE_CONTROL_FLOW" {
  run_gates $'+if x > 0 {\n+  doSomething()\n+}' "src/main.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CONTROL_FLOW)" = "true" ]
}

@test "gates: removed 'if' (minus line) does not trigger GATE_CONTROL_FLOW" {
  run_gates $'-if x > 0 {\n-  doSomething()\n-}' "src/main.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CONTROL_FLOW)" = "false" ]
}

@test "gates: >100KB of added lines still triggers GATE_CONTROL_FLOW (echo|grep -q SIGPIPEs under pipefail)" {
  {
    printf '%s\n' '+if (x) {'
    for _ in {1..8000}; do printf '%s\n' '+  let padding = 0;'; done
  } > "$WORK/large.diff"
  [ "$(wc -c < "$WORK/large.diff" | tr -d ' ')" -gt 102400 ]
  DIFF_FILE="$WORK/large.diff" DIFF_PATHS="src/main.js" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CONTROL_FLOW)" = "true" ]
}

# ---------------------------------------------------------------------------
# GATE_SECURITY_PATTERNS
# ---------------------------------------------------------------------------

@test "gates: diff mentioning 'password' triggers GATE_SECURITY_PATTERNS" {
  run_gates "+const password = 'change-me'" "config/settings.py"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_SECURITY_PATTERNS)" = "true" ]
}

@test "gates: go.mod in changed file paths triggers GATE_SECURITY_PATTERNS" {
  run_gates "+require example.com/foo v1.2.3" "go.mod"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_SECURITY_PATTERNS)" = "true" ]
}

@test "gates: Dockerfile in file paths triggers GATE_SECURITY_PATTERNS" {
  run_gates "+FROM node:20" "Dockerfile"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_SECURITY_PATTERNS)" = "true" ]
}

@test "gates: plain diff with no security content does not trigger GATE_SECURITY_PATTERNS" {
  run_gates "+Added a new helper function" "src/utils.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_SECURITY_PATTERNS)" = "false" ]
}

# ---------------------------------------------------------------------------
# GATE_CODE_OR_INFRA
# ---------------------------------------------------------------------------

@test "gates: Go source file triggers GATE_CODE_OR_INFRA" {
  run_gates "+func foo() {}" "src/main.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "true" ]
}

@test "gates: Claude and Grok workflow wrappers trigger GATE_CODE_OR_INFRA" {
  run_gates "+export const meta" ".claude/workflows/code-review-lenses-workflow.js"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "true" ]
  run_gates "+let meta" ".grok/workflows/code-review-lenses-workflow.rhai"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "true" ]
}

@test "gates: GitHub Actions workflow triggers GATE_CODE_OR_INFRA" {
  run_gates "+    runs-on: ubuntu-latest" ".github/workflows/ci.yml"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "true" ]
}

@test "gates: executable and operational .github files are infra; GitHub's documentary files are not" {
  for path in .github/actions/setup/action.yml .github/actions/setup/run.sh .github/dependabot.yml; do
    run_gates "+x: y" "$path"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_CODE_OR_INFRA)" = "true" ] || { echo "not infra: $path" >&2; return 1; }
  done
  for path in .github/ISSUE_TEMPLATE/bug.yml .github/PULL_REQUEST_TEMPLATE/default.md .github/FUNDING.yml .github/CODEOWNERS; do
    run_gates "+x: y" "$path"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_CODE_OR_INFRA)" = "false" ] || { echo "infra: $path" >&2; return 1; }
  done
}

@test "gates: only .md files do not trigger GATE_CODE_OR_INFRA" {
  run_gates "+Updated documentation" "docs/guide.md"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "false" ]
}

@test "gates: only CHANGELOG does not trigger GATE_CODE_OR_INFRA" {
  run_gates "+## v1.9.0" "CHANGELOG.md"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_CODE_OR_INFRA)" = "false" ]
}

# ---------------------------------------------------------------------------
# GATE_TEST_PATHS
# ---------------------------------------------------------------------------

@test "gates: every test-path form from the pr-test-analyzer list triggers GATE_TEST_PATHS" {
  for path in pkg/foo_test.go pkg/test_foo.py web/app.test.ts web/app.spec.ts \
    spec/models/user.rb src/__tests__/a.js test/a.js lib/tests/a.js \
    pkg/foo_test.rb web/app.test.jsx web/app.spec.js app/models/user_spec.rb \
    src/FooTest.java src/FooTests.cs src/test/resources/app.properties; do
    run_gates "+x" "$path"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_TEST_PATHS)" = "true" ] || { echo "not a test path: $path" >&2; return 1; }
  done
}

@test "gates: one test path among several changed paths triggers GATE_TEST_PATHS" {
  run_gates "+x" $'src/main.go\npkg/foo_test.go\nREADME.md'
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_TEST_PATHS)" = "true" ]
}

@test "gates: near-miss paths do not trigger GATE_TEST_PATHS, whatever the diff says" {
  for path in src/main.go src/latest/a.go src/inspect/a.go src/contest/a.go src/testing.go \
    src/foo_testdata/a.go src/foo_test.d/a.go docs/spec.md src/app.tests.js src/Footest.java \
    src/test.py lib/protest/x.rb; do
    run_gates "+func TestFoo(t *testing.T) {}" "$path"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_TEST_PATHS)" = "false" ] || { echo "test path: $path" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# GATE_COMMENT_CHANGES
# ---------------------------------------------------------------------------

@test "gates: added or removed lines opening with a comment marker trigger GATE_COMMENT_CHANGES" {
  for line in '+// line comment' '+    // indented' '-# removed hash comment' $'+\t# tab indented' \
    '+/* block */' '+  /** javadoc */' '-/* removed block */' '+"""docstring"""' '+    """' "+'''single'''"; do
    run_gates "$line" "src/a.go"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_COMMENT_CHANGES)" = "true" ] || { echo "not a comment change: $line" >&2; return 1; }
  done
}

@test "gates: changed lines that do not open with a comment marker do not trigger GATE_COMMENT_CHANGES" {
  for line in '+x := 1 // trailing comment' '+ * block continuation' '+return "#tag"' '+-- sql comment' '+x := 1'; do
    run_gates "$line" "src/a.go"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_COMMENT_CHANGES)" = "false" ] || { echo "comment change: $line" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------
# GATE_TYPE_DEFINITIONS
# ---------------------------------------------------------------------------

@test "gates: added or removed type definitions trigger GATE_TYPE_DEFINITIONS" {
  for line in '+type Foo struct {' '+type Pair[K comparable, V any] struct {' '+type Reader interface {' \
    '-export interface Bar {' '+public class Baz' '+class Foo:' '+  enum Color { Red }' '-pub enum Kind {' \
    '+type UserId = string' '+export type Box<T> = { value: T }' '+pub struct User {}' '-struct Point { x: i32 }' '+typedef struct {'; do
    run_gates "$line" "src/a.go"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "true" ] || { echo "not a type definition: $line" >&2; return 1; }
  done
}

@test "gates: near-miss words and file headers do not trigger GATE_TYPE_DEFINITIONS" {
  for line in '+superclass Foo' '+interfaces are listed' '+base_class = 1' '+enums = []' '+x := 1' \
    '+const type = 1' '+the type system is fine' '+destruct x' '+structure = 1'; do
    run_gates "$line" "src/a.go"
    [ "$status" -eq 0 ]
    [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "false" ] || { echo "type definition: $line" >&2; return 1; }
  done
  run_gates $'--- a/src/enum values.go\n+++ b/src/enum values.go\n@@ -1 +1 @@\n-x := 1\n+x := 2' "src/enum values.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "false" ]
}

# ---------------------------------------------------------------------------
# GATE_COMMENT_CHANGES and GATE_TYPE_DEFINITIONS: lines that are not changes
# ---------------------------------------------------------------------------

@test "gates: context lines and hunk headers trigger neither GATE_COMMENT_CHANGES nor GATE_TYPE_DEFINITIONS" {
  run_gates $'diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1,4 +1,4 @@ class Header:\n # context comment\n class Context:\n-    x = 1\n+    x = 2' "src/a.py"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_COMMENT_CHANGES)" = "false" ]
  [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "false" ]
}

@test "gates: a diff with no changed lines leaves GATE_COMMENT_CHANGES and GATE_TYPE_DEFINITIONS false" {
  run_gates "" "src/a.go"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_COMMENT_CHANGES)" = "false" ]
  [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "false" ]
}

@test "gates: >100KB of changed lines still triggers GATE_COMMENT_CHANGES and GATE_TYPE_DEFINITIONS" {
  {
    for _ in {1..8000}; do printf '%s\n' '+  let padding = 0;'; done
    printf '%s\n' '+// late comment' '+class Late {}'
  } > "$WORK/large.diff"
  [ "$(wc -c < "$WORK/large.diff" | tr -d ' ')" -gt 102400 ]
  DIFF_FILE="$WORK/large.diff" DIFF_PATHS="src/main.js" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(gate_value GATE_COMMENT_CHANGES)" = "true" ]
  [ "$(gate_value GATE_TYPE_DEFINITIONS)" = "true" ]
}

@test "gates: unreadable DIFF_FILE is grep rc 2 abort, not no-match" {
  if [[ "$EUID" -eq 0 ]]; then
    skip "root reads chmod 000 files"
  fi
  printf '%s\n' "+token" > "$WORK/locked.diff"
  chmod 000 "$WORK/locked.diff"
  DIFF_FILE="$WORK/locked.diff" DIFF_PATHS="src/auth.go" run bash "$SCRIPT"
  chmod u+r "$WORK/locked.diff"
  [ "$status" -eq 1 ]
  [[ "$output" != *"GATE_SECURITY_PATTERNS=false"* ]]
}

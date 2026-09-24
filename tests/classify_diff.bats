#!/usr/bin/env bats
# Drive classify-diff.sh (TIER / promotions / auto-cheap).

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  CLS="${SCRIPTS_DIR}/classify-diff.sh"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

@test "classify-diff: tiny when few files and few lines" {
  printf '%s\n' 'a.md' > "$WORK/paths"
  printf '%s\n' '+++ a/a.md' '+one' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" bash "$CLS")
  eval "$_cls"
  [[ "$TIER" == "tiny" ]]
  [[ "$ARCH_PROMOTED" == "false" ]]
  [[ "$SECURITY_PROMOTED" == "false" ]]
}

@test "classify-diff: tiny + Dockerfile promotes architecture" {
  printf '%s\n' 'Dockerfile' > "$WORK/paths"
  printf '%s\n' '+++ a/Dockerfile' '+FROM x' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" bash "$CLS")
  eval "$_cls"
  [[ "$TIER" == "tiny" ]]
  [[ "$ARCH_PROMOTED" == "true" ]]
}

@test "classify-diff: yaml-only with no security gate is LOW_RISK_CONFIG" {
  printf '%s\n' 'deploy/values.yaml' > "$WORK/paths"
  printf '%s\n' '+++ a/deploy/values.yaml' '+x: 1' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" \
    GATE_SECURITY_PATTERNS=false bash "$CLS")
  eval "$_cls"
  [[ "$LOW_RISK_CONFIG" == "true" ]]
}

@test "classify-diff: mixed go+yaml is not LOW_RISK_CONFIG" {
  printf '%s\n' 'src/main.go' 'deploy/values.yaml' > "$WORK/paths"
  printf '%s\n' '+++ a/src/main.go' '+package main' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" \
    GATE_SECURITY_PATTERNS=false bash "$CLS")
  eval "$_cls"
  [[ "$LOW_RISK_CONFIG" == "false" ]]
}

@test "classify-diff: GATE_CODE_OR_INFRA=false sets DOCS_ONLY" {
  printf '%s\n' 'README.md' > "$WORK/paths"
  printf '%s\n' '+++ a/README.md' '+x' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" \
    GATE_CODE_OR_INFRA=false bash "$CLS")
  eval "$_cls"
  [[ "$DOCS_ONLY" == "true" ]]
}

@test "classify-diff: unreadable DIFF_FILE is exit 1" {
  run -1 env DIFF_FILE="$WORK/missing" DIFF_PATHS=a.md bash "$CLS"
  [ "$status" -eq 1 ]
}

@test "classify-diff: empty DIFF_FILE is exit 1, not a zero-line tiny diff" {
  run -1 env DIFF_FILE= DIFF_PATHS=a.md bash "$CLS"
}

@test "classify-diff: LINES_CHANGED skips file headers, counts removed '--' lines" {
  printf '%s\n' 'diff --git a/q.sql b/q.sql' 'index 1111111..2222222 100644' \
    '--- a/q.sql' '+++ b/q.sql' '@@ -1,2 +1,2 @@' '--- old comment' '+-- new comment' ' SELECT 1;' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS='q.sql' bash "$CLS")
  eval "$_cls"
  [[ "$LINES_CHANGED" == "2" ]]
}

@test "classify-diff: tiny root-level api/ path promotes security" {
  printf '%s\n' '+++ b/api/users.go' '+x' > "$WORK/diff"
  _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS='api/users.go' bash "$CLS")
  eval "$_cls"
  [[ "$TIER" == "tiny" ]]
  [[ "$SECURITY_PROMOTED" == "true" ]]
}

@test "classify-diff: tiny lockfile-only diff promotes security" {
  printf '%s\n' '+++ b/x.lock' '+x' > "$WORK/diff"
  for lock in package-lock.json go.sum composer.lock Pipfile.lock Gemfile.lock Cargo.lock yarn.lock pnpm-lock.yaml; do
    _cls=$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$lock" bash "$CLS")
    eval "$_cls"
    [[ "$SECURITY_PROMOTED" == "true" ]] || { echo "not promoted: $lock" >&2; return 1; }
  done
}

@test "language-profile table names lowercase to existing files" {
  PROFILES="$SCRIPTS_DIR/../language-profiles"
  for name in Go Python TypeScript JavaScript Rust Ruby PHP Java C++ Shell Csharp Kotlin Swift Scala Lua Perl SQL Terraform YAML; do
    lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    [[ -f "$PROFILES/${lower}.md" ]] || {
      echo "missing language-profiles/${lower}.md for table name $name" >&2
      return 1
    }
  done
}
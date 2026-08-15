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
  eval "$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" bash "$CLS")"
  [[ "$TIER" == "tiny" ]]
  [[ "$ARCH_PROMOTED" == "false" ]]
  [[ "$SECURITY_PROMOTED" == "false" ]]
}

@test "classify-diff: tiny + Dockerfile promotes architecture" {
  printf '%s\n' 'Dockerfile' > "$WORK/paths"
  printf '%s\n' '+++ a/Dockerfile' '+FROM x' > "$WORK/diff"
  eval "$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" bash "$CLS")"
  [[ "$TIER" == "tiny" ]]
  [[ "$ARCH_PROMOTED" == "true" ]]
}

@test "classify-diff: yaml-only with no security gate is LOW_RISK_CONFIG" {
  printf '%s\n' 'deploy/values.yaml' > "$WORK/paths"
  printf '%s\n' '+++ a/deploy/values.yaml' '+x: 1' > "$WORK/diff"
  eval "$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" \
    GATE_SECURITY_PATTERNS=false bash "$CLS")"
  [[ "$LOW_RISK_CONFIG" == "true" ]]
}

@test "classify-diff: mixed go+yaml is not LOW_RISK_CONFIG" {
  printf '%s\n' 'src/main.go' 'deploy/values.yaml' > "$WORK/paths"
  printf '%s\n' '+++ a/src/main.go' '+package main' > "$WORK/diff"
  eval "$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" \
    GATE_SECURITY_PATTERNS=false bash "$CLS")"
  [[ "$LOW_RISK_CONFIG" == "false" ]]
}

@test "classify-diff: GATE_CODE_OR_INFRA=false sets DOCS_ONLY" {
  printf '%s\n' 'README.md' > "$WORK/paths"
  printf '%s\n' '+++ a/README.md' '+x' > "$WORK/diff"
  eval "$(DIFF_FILE="$WORK/diff" DIFF_PATHS="$(cat "$WORK/paths")" \
    GATE_CODE_OR_INFRA=false bash "$CLS")"
  [[ "$DOCS_ONLY" == "true" ]]
}

@test "classify-diff: unreadable DIFF_FILE is exit 1" {
  run -1 env DIFF_FILE="$WORK/missing" DIFF_PATHS=a.md bash "$CLS"
  [ "$status" -eq 1 ]
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
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
  export HOME="$WORK/home"
}

teardown() {
  rm -rf "$WORK"
}

# Stub binary: logs "<cwd>|<args>" to $GL_LOG, exits 3 if ./fail exists, else copies ./out.json to the --output.json.path file.
make_golangci_stub() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/golangci-lint" << 'EOF'
#!/bin/sh
printf '%s|%s\n' "$PWD" "$*" >> "$GL_LOG"
[ -f fail ] && { echo boom >&2; exit 3; }
cp out.json "${2#--output.json.path=}"
EOF
  chmod +x "$WORK/bin/golangci-lint"
  export GL_LOG="$WORK/gl.log"
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

@test "golangci-lint: linters other than errcheck/govet/staticcheck map to Medium" {
  jq '.Issues[0].FromLinter = "gocritic"' "$GOLANGCI_FIX/golangci-findings.json" > "$WORK/medium.json"
  GOLANGCI_MOCK_FILE="$WORK/medium.json" run --separate-stderr "$SCRIPT" "$WORK/main.go"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "Medium"' >/dev/null
}

@test "golangci-lint: no Go files, unreadable mock, or missing binary return [] with exit 0" {
  touch "$WORK/app.py"
  GOLANGCI_MOCK_FILE="$GOLANGCI_FIX/golangci-findings.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  GOLANGCI_MOCK_FILE="$WORK/missing.json" run --separate-stderr "$SCRIPT" "$WORK/main.go"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  mkdir -p "$WORK/pathbin"
  ln -s "$(command -v jq)" "$WORK/pathbin/jq"
  _bash=$(command -v bash)
  unset GOLANGCI_MOCK_FILE
  run --separate-stderr env PATH="$WORK/pathbin" "$_bash" "$SCRIPT" "$WORK/main.go"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"golangci-lint not installed"* ]]
}

@test "golangci-lint: live run passes v2 flags and unique packages from the module root" {
  unset GOLANGCI_MOCK_FILE
  mkdir -p "$WORK/bin" "$WORK/mod/a" "$WORK/mod/b"
  touch "$WORK/mod/go.mod" "$WORK/mod/a/x.go" "$WORK/mod/a/y.go" "$WORK/mod/b/z.go"
  cat > "$WORK/bin/golangci-lint" << 'EOF'
#!/bin/sh
[ -f go.mod ] || { echo "not in module root: $PWD" >&2; exit 3; }
case "$*" in
  "run --output.json.path=/"*" --path-mode=abs --issues-exit-code=0 --no-config ./a/... ./b/...") ;;
  *) echo "unexpected args: $*" >&2; exit 3 ;;
esac
printf '{"Issues":[{"FromLinter":"errcheck","Text":"x","Pos":{"Filename":"%s/a/x.go","Line":3}}]}\n' "$PWD" > "${2#--output.json.path=}"
printf '1 issues:\n* errcheck: 1\n'
EOF
  chmod +x "$WORK/bin/golangci-lint"
  GITHUB_WORKSPACE="$WORK" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' "$WORK/mod/a/x.go" "$WORK/mod/a/y.go" "$WORK/mod/b/z.go")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg f "$WORK/mod/a/x.go" 'length == 1 and .[0].file == $f and .[0].line == 3' >/dev/null
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' mod/a/x.go mod/a/y.go mod/b/z.go)"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].file == "mod/a/x.go"' >/dev/null
}

@test "golangci-lint: live run lints each Go module from its own root and merges the findings" {
  unset GOLANGCI_MOCK_FILE
  make_golangci_stub
  mkdir -p "$WORK/modA/a" "$WORK/modA/b" "$WORK/modB/c" "$WORK/loose"
  touch "$WORK/modA/go.mod" "$WORK/modA/a/x.go" "$WORK/modA/b/z.go" "$WORK/modB/go.mod" "$WORK/modB/c/w.go" "$WORK/loose/gen.go"
  printf '{"Issues":[{"FromLinter":"errcheck","Text":"a","Pos":{"Filename":"%s/modA/a/x.go","Line":3}}]}\n' "$WORK" > "$WORK/modA/out.json"
  printf '{"Issues":[{"FromLinter":"govet","Text":"b","Pos":{"Filename":"%s/modB/c/w.go","Line":7}}]}\n' "$WORK" > "$WORK/modB/out.json"
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' modA/a/x.go modB/c/w.go loose/gen.go modA/b/z.go)"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$WORK/gl.log")" -eq 2 ]
  [[ "$(sed -n 1p "$WORK/gl.log")" == "$WORK/modA|run --output.json.path=/"*" --path-mode=abs --issues-exit-code=0 --no-config ./a/... ./b/..." ]]
  [[ "$(sed -n 2p "$WORK/gl.log")" == "$WORK/modB|run --output.json.path=/"*" --path-mode=abs --issues-exit-code=0 --no-config ./c/..." ]]
  [[ "$stderr" == *"loose/gen.go"* ]]
  echo "$output" | jq -e 'map(.file) == ["modA/a/x.go", "modB/c/w.go"] and map(.line) == [3, 7]' >/dev/null
}

@test "golangci-lint: a failing module run is exit 1 and still emits the other modules' findings" {
  unset GOLANGCI_MOCK_FILE
  make_golangci_stub
  mkdir -p "$WORK/modA/a" "$WORK/modB/c" "$WORK/modC/d"
  touch "$WORK/modA/go.mod" "$WORK/modA/a/x.go" "$WORK/modB/go.mod" "$WORK/modB/c/w.go" "$WORK/modB/fail" "$WORK/modC/go.mod" "$WORK/modC/d/v.go"
  printf '{"Issues":[{"FromLinter":"errcheck","Text":"a","Pos":{"Filename":"%s/modA/a/x.go","Line":3}}]}\n' "$WORK" > "$WORK/modA/out.json"
  printf '{"Issues":[{"FromLinter":"govet","Text":"c","Pos":{"Filename":"%s/modC/d/v.go","Line":5}}]}\n' "$WORK" > "$WORK/modC/out.json"
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' modA/a/x.go modB/c/w.go modC/d/v.go)"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e 'map(.file) == ["modA/a/x.go", "modC/d/v.go"]' >/dev/null
  [[ "$stderr" == *"modB"*"exit 3"*"boom"* ]]
  touch "$WORK/modA/fail" "$WORK/modC/fail"
  GITHUB_WORKSPACE="$WORK" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' modA/a/x.go modB/c/w.go modC/d/v.go)"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "golangci-lint: pins the reviewer's config, or --no-config, never the reviewed module's" {
  unset GOLANGCI_MOCK_FILE
  make_golangci_stub
  mkdir -p "$WORK/ws" "$WORK/pr/mod/a"
  touch "$WORK/pr/mod/go.mod" "$WORK/pr/mod/a/x.go" "$WORK/pr/mod/.golangci.yml"
  echo '{"Issues":[]}' > "$WORK/pr/mod/out.json"
  cd "$WORK"
  for name in .golangci.yml .golangci.yaml .golangci.toml .golangci.json; do
    touch "$WORK/ws/$name"
    : > "$WORK/gl.log"
    GITHUB_WORKSPACE="$WORK/ws" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
    [ "$status" -eq 0 ]
    [[ "$(cat "$WORK/gl.log")" == "$WORK/pr/mod|run "*" --issues-exit-code=0 --config=$WORK/ws/$name ./a/..." ]]
    rm "$WORK/ws/$name"
  done
  : > "$WORK/gl.log"
  GITHUB_WORKSPACE="$WORK/ws" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/gl.log")" == "$WORK/pr/mod|run "*" --issues-exit-code=0 --no-config ./a/..." ]]
  mkdir -p "$HOME"
  touch "$HOME/.golangci.yml"
  : > "$WORK/gl.log"
  GITHUB_WORKSPACE="$WORK/ws" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/gl.log")" == "$WORK/pr/mod|run "*" --issues-exit-code=0 --config=$HOME/.golangci.yml ./a/..." ]]
  touch "$WORK/ws/.golangci.yml"
  : > "$WORK/gl.log"
  cd "$WORK/ws"
  GITHUB_WORKSPACE="" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/gl.log")" == "$WORK/pr/mod|run "*" --issues-exit-code=0 --config=$WORK/ws/.golangci.yml ./a/..." ]]
}

@test "golangci-lint: without HOME it still runs, using only the reviewer-root config or --no-config" {
  unset GOLANGCI_MOCK_FILE
  make_golangci_stub
  mkdir -p "$WORK/ws" "$WORK/pr/mod/a"
  touch "$WORK/pr/mod/go.mod" "$WORK/pr/mod/a/x.go" "$WORK/ws/.golangci.yml"
  echo '{"Issues":[]}' > "$WORK/pr/mod/out.json"
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK/ws" PATH="$WORK/bin:$PATH" run --separate-stderr env -u HOME bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/gl.log")" == "$WORK/pr/mod|run "*" --issues-exit-code=0 --config=$WORK/ws/.golangci.yml ./a/..." ]]
  rm "$WORK/ws/.golangci.yml"
  : > "$WORK/gl.log"
  GITHUB_WORKSPACE="$WORK/ws" HOME="" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/gl.log")" == "$WORK/pr/mod|run "*" --issues-exit-code=0 --no-config ./a/..." ]]
}

@test "golangci-lint: a valid module under an invalid parent go.work is still linted, with GOWORK=off, GOTOOLCHAIN=local and no VCS stamping" {
  unset GOLANGCI_MOCK_FILE
  mkdir -p "$WORK/bin" "$WORK/pr/mod/a"
  printf 'go 1.21\n\nuse ./missing\n' > "$WORK/pr/go.work"
  printf 'module example.com/mod\n\ngo 1.21\n' > "$WORK/pr/mod/go.mod"
  printf 'package a\n' > "$WORK/pr/mod/a/x.go"
  cat > "$WORK/bin/golangci-lint" << 'EOF'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$PWD" "$GOWORK" "$GOTOOLCHAIN" "$GOFLAGS" >> "$GL_LOG"
if command -v go >/dev/null 2>&1; then go list ./... >/dev/null || exit 3; fi
echo '{"Issues":[]}' > "${2#--output.json.path=}"
EOF
  chmod +x "$WORK/bin/golangci-lint"
  export GL_LOG="$WORK/gl.log"
  GOWORK='' GOTOOLCHAIN=auto GOFLAGS=-mod=mod GITHUB_WORKSPACE="$WORK" PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/a/x.go"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ "$(cat "$WORK/gl.log")" = "$WORK/pr/mod|off|local|-mod=mod -buildvcs=false" ]
}

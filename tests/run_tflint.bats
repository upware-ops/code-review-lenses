#!/usr/bin/env bats
# Tests for run-tflint.sh. Uses TFLINT_MOCK_FILE to bypass the binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-tflint.sh"
  TF_FIX="${FIXTURES_DIR}/tflint"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# Stub binary: records its argv plus the plugin dir and config file it would inherit to $ARGV_FILE.
make_tflint_stub() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tflint" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" "PLUGIN_DIR=${TFLINT_PLUGIN_DIR-}" "CONFIG_FILE=${TFLINT_CONFIG_FILE-}" > "$ARGV_FILE"
echo '{"issues":[]}'
STUB
  chmod +x "$WORK/bin/tflint"
}

# ---------------------------------------------------------------------------
# No-op paths
# ---------------------------------------------------------------------------

@test "tflint: empty input returns empty array" {
  TFLINT_MOCK_FILE="$TF_FIX/tflint-empty.json" run --separate-stderr "$SCRIPT" ""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tflint: non-Terraform file returns empty array" {
  touch "$WORK/app.py"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-empty.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tflint: nonexistent TF file returns empty array" {
  TFLINT_MOCK_FILE="$TF_FIX/tflint-empty.json" run --separate-stderr "$SCRIPT" "nonexistent/main.tf"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tflint: empty issues array returns empty array" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-empty.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "tflint: malformed output falls through safely" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-malformed.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "tflint: binary missing returns empty array" {
  unset TFLINT_MOCK_FILE
  run --separate-stderr "$SCRIPT" "main.tf"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# File extension matching
# ---------------------------------------------------------------------------

@test "tflint: .tf extension triggers scan" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

@test "tflint: .tfvars extension triggers scan" {
  touch "$WORK/terraform.tfvars"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/terraform.tfvars"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Severity mapping
# ---------------------------------------------------------------------------

@test "tflint: rule severity error maps to High" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "High"' >/dev/null
}

@test "tflint: rule severity warning maps to Medium" {
  touch "$WORK/variables.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-warning.json" run --separate-stderr "$SCRIPT" "$WORK/variables.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].severity == "Medium"' >/dev/null
}

# ---------------------------------------------------------------------------
# Schema conformance
# ---------------------------------------------------------------------------

@test "tflint: findings conform to required schema" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    all(.[]; has("severity") and has("confidence") and has("source")
        and has("file") and has("line") and has("finding") and has("remediation"))
  ' >/dev/null
}

@test "tflint: source field is tflint on all findings" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .source == "tflint")' >/dev/null
}

@test "tflint: confidence is 90 on all findings" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .confidence == 90)' >/dev/null
}

@test "tflint: finding text contains rule name" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | test("aws_instance_invalid_type")' >/dev/null
}

@test "tflint: remediation includes rule link when present" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr "$SCRIPT" "$WORK/main.tf"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].remediation | test("https://")' >/dev/null
}

# ---------------------------------------------------------------------------
# stdin input contract
# ---------------------------------------------------------------------------

@test "tflint: accepts file list via stdin" {
  touch "$WORK/main.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-error.json" run --separate-stderr bash -c \
    "echo '$WORK/main.tf' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Trusted config and plugins (live binary stub)
# ---------------------------------------------------------------------------

@test "tflint: pins the reviewer's config and plugin dir instead of the reviewed directory's" {
  unset TFLINT_MOCK_FILE TFLINT_CONFIG_FILE TFLINT_PLUGIN_DIR
  mkdir -p "$WORK/bin" "$WORK/home" "$WORK/pr/mod/.tflint.d/plugins"
  cat > "$WORK/bin/tflint" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" "PLUGIN_DIR=$TFLINT_PLUGIN_DIR" > "$ARGV_FILE"
echo '{"issues":[]}'
STUB
  chmod +x "$WORK/bin/tflint"
  touch "$WORK/pr/mod/main.tf" "$WORK/pr/mod/.tflint.hcl" "$WORK/.tflint.hcl"
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK" HOME="$WORK/home" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "--chdir=$WORK/pr/mod" "$WORK/argv"
  grep -qx -- "--config=$WORK/.tflint.hcl" "$WORK/argv"
  grep -qx -- "PLUGIN_DIR=$WORK/home/.tflint.d/plugins" "$WORK/argv"
  rm "$WORK/.tflint.hcl"
  GITHUB_WORKSPACE="$WORK" HOME="$WORK/home" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "--config=/dev/null" "$WORK/argv"
}

@test "tflint: without HOME it still runs, pinning only the reviewer-root config and plugin dir" {
  unset TFLINT_MOCK_FILE TFLINT_CONFIG_FILE TFLINT_PLUGIN_DIR
  make_tflint_stub
  mkdir -p "$WORK/pr/mod"
  touch "$WORK/pr/mod/main.tf" "$WORK/.tflint.hcl"
  cd "$WORK"
  GITHUB_WORKSPACE="$WORK" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr env -u HOME bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "--config=$WORK/.tflint.hcl" "$WORK/argv"
  grep -qx -- "PLUGIN_DIR=$WORK/.tflint.d/plugins" "$WORK/argv"
  rm "$WORK/.tflint.hcl"
  GITHUB_WORKSPACE="$WORK" HOME="" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "--config=/dev/null" "$WORK/argv"
  grep -qx -- "PLUGIN_DIR=$WORK/.tflint.d/plugins" "$WORK/argv"
}

@test "tflint: relative TFLINT_CONFIG_FILE and TFLINT_PLUGIN_DIR are anchored to the reviewer checkout" {
  unset TFLINT_MOCK_FILE TFLINT_CONFIG_FILE TFLINT_PLUGIN_DIR
  make_tflint_stub
  mkdir -p "$WORK/pr/mod"
  touch "$WORK/pr/mod/main.tf"
  cd "$WORK"
  TFLINT_CONFIG_FILE=conf/tflint.hcl TFLINT_PLUGIN_DIR=plugins HOME="$WORK/home" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "CONFIG_FILE=$PWD/conf/tflint.hcl" "$WORK/argv"
  grep -qx -- "PLUGIN_DIR=$PWD/plugins" "$WORK/argv"
  [ "$(grep -c -- '^--config=' "$WORK/argv")" -eq 0 ]
  TFLINT_PLUGIN_DIR='~/plugins' HOME="$WORK/home" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "PLUGIN_DIR=$PWD/~/plugins" "$WORK/argv"
}

@test "tflint: absolute TFLINT_CONFIG_FILE and TFLINT_PLUGIN_DIR operator overrides are kept as set" {
  unset TFLINT_MOCK_FILE TFLINT_CONFIG_FILE TFLINT_PLUGIN_DIR
  make_tflint_stub
  mkdir -p "$WORK/pr/mod"
  touch "$WORK/pr/mod/main.tf"
  cd "$WORK"
  TFLINT_CONFIG_FILE=/etc/tflint.hcl TFLINT_PLUGIN_DIR=/opt/tflint-plugins HOME="$WORK/home" ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/pr/mod/main.tf"
  [ "$status" -eq 0 ]
  grep -qx -- "CONFIG_FILE=/etc/tflint.hcl" "$WORK/argv"
  grep -qx -- "PLUGIN_DIR=/opt/tflint-plugins" "$WORK/argv"
  [ "$(grep -c -- '^--config=' "$WORK/argv")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Module-level issues (empty filename, line 0)
# ---------------------------------------------------------------------------

@test "tflint: mock module-level issue maps to the first changed Terraform file at line 0" {
  touch "$WORK/main.tf" "$WORK/variables.tf"
  TFLINT_MOCK_FILE="$TF_FIX/tflint-module-level.json" run --separate-stderr "$SCRIPT" \
    "$(printf '%s\n' "$WORK/variables.tf" "$WORK/main.tf")"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg f "$WORK/variables.tf" '.[0].file == $f and .[0].line == 0' >/dev/null
  echo "$output" | jq -e '.[1].file == "main.tf" and .[1].line == 8' >/dev/null
}

@test "tflint: live module-level issues map to the first changed Terraform file of each directory" {
  unset TFLINT_MOCK_FILE TFLINT_CONFIG_FILE TFLINT_PLUGIN_DIR
  mkdir -p "$WORK/bin" "$WORK/infra"
  cat > "$WORK/bin/tflint" <<'STUB'
#!/bin/sh
cat "$ISSUES_FILE"
exit 2
STUB
  chmod +x "$WORK/bin/tflint"
  touch "$WORK/versions.tf" "$WORK/main.tf" "$WORK/infra/network.tf" "$WORK/infra/main.tf"
  cd "$WORK"
  HOME="$WORK/home" ISSUES_FILE="$TF_FIX/tflint-module-level.json" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' versions.tf main.tf infra/network.tf infra/main.tf)"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    map([.file, .line]) == [["versions.tf", 0], ["main.tf", 8], ["infra/network.tf", 0], ["infra/main.tf", 8]]
  ' >/dev/null
}

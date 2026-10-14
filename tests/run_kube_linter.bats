#!/usr/bin/env bats
# Tests for run-kube-linter.sh. Uses KUBELINTER_MOCK_FILE to bypass the binary.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-kube-linter.sh"
  KL_FIX="${FIXTURES_DIR}/kubelinter"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# No-op paths
# ---------------------------------------------------------------------------

@test "kube-linter: empty input returns empty array" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-empty.json" run --separate-stderr "$SCRIPT" ""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "kube-linter: non-YAML file returns empty array" {
  touch "$WORK/app.py"
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$WORK/app.py"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "kube-linter: plain YAML without apiVersion is skipped" {
  # Use the non-k8s YAML fixture which lacks apiVersion/kind
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/not-k8s.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "kube-linter: nonexistent YAML file returns empty array" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "nonexistent/deploy.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "kube-linter: empty Reports array returns empty array" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-empty.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "kube-linter: malformed output falls through safely" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-malformed.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "kube-linter: binary missing returns empty array" {
  unset KUBELINTER_MOCK_FILE
  run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# Content-sniff guard: k8s manifest detection
# ---------------------------------------------------------------------------

@test "kube-linter: k8s manifest with apiVersion triggers scan" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Schema conformance
# ---------------------------------------------------------------------------

@test "kube-linter: findings conform to required schema" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    all(.[]; has("severity") and has("confidence") and has("source")
        and has("file") and has("line") and has("finding") and has("remediation"))
  ' >/dev/null
}

@test "kube-linter: source field is kube-linter on all findings" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .source == "kube-linter")' >/dev/null
}

@test "kube-linter: severity is Medium on all findings" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .severity == "Medium")' >/dev/null
}

@test "kube-linter: confidence is 85 on all findings" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .confidence == 85)' >/dev/null
}

@test "kube-linter: finding text contains check name" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | test("no-read-only-root-fs")' >/dev/null
}

# ---------------------------------------------------------------------------
# stdin input contract
# ---------------------------------------------------------------------------

@test "kube-linter: accepts file list via stdin" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr bash -c \
    "echo '$KL_FIX/deployment.yaml' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
}

# ---------------------------------------------------------------------------
# Undecodable manifests (live binary stub)
# ---------------------------------------------------------------------------

@test "kube-linter: live run passes --fail-on-invalid-resource and keeps failed-to-load-object reports as findings" {
  unset KUBELINTER_MOCK_FILE
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/kube-linter" <<'STUB'
#!/bin/sh
case " $* " in
  *" --fail-on-invalid-resource "*) ;;
  *) echo "missing --fail-on-invalid-resource: $*" >&2; exit 3 ;;
esac
cat "$REPORT_FILE"
echo "Error: found 1 lint errors" >&2
exit 1
STUB
  chmod +x "$WORK/bin/kube-linter"
  printf 'apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: three\n' > "$WORK/broken.yaml"
  REPORT_FILE="$KL_FIX/kubelinter-invalid-object.json" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/broken.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    length == 1 and .[0].source == "kube-linter" and .[0].file == "/repo/k8s/broken.yaml"
    and (.[0].finding | startswith("failed-to-load-object: failed to decode"))
    and (.[0].remediation | contains("valid k8s yaml"))
  ' >/dev/null
  REPORT_FILE=/dev/null PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/broken.yaml"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

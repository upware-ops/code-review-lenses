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

stub_kube_linter() {
  unset KUBELINTER_MOCK_FILE
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/kube-linter" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$ARGV_FILE"
echo '{"Reports":[]}'
STUB
  chmod +x "$WORK/bin/kube-linter"
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

@test "kube-linter: Helm chart template is not handed to kube-linter and is named on stderr" {
  stub_kube_linter
  mkdir -p "$WORK/chart/templates"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$WORK/chart/Chart.yaml"
  cp "$KL_FIX/helm-template.yaml" "$WORK/chart/templates/deploy.yaml"
  ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' "$WORK/chart/templates/deploy.yaml" "$KL_FIX/deployment.yaml")"
  [ "$status" -eq 0 ]
  grep -qxF -- "$KL_FIX/deployment.yaml" "$WORK/argv"
  [ "$(grep -cF -- "$WORK/chart/templates/deploy.yaml" "$WORK/argv")" -eq 0 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"skipped Helm chart templates"*"$WORK/chart/templates/deploy.yaml" ]]
}

@test "kube-linter: chart templates are skipped for relative paths and nested template directories" {
  stub_kube_linter
  mkdir -p "$WORK/templates" "$WORK/chart/templates/sub"
  printf 'apiVersion: v2\nname: root\nversion: 0.1.0\n' > "$WORK/Chart.yaml"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$WORK/chart/Chart.yaml"
  cp "$KL_FIX/helm-template.yaml" "$WORK/templates/root.yaml"
  cp "$KL_FIX/helm-template.yaml" "$WORK/chart/templates/sub/nested.yaml"
  cp "$KL_FIX/deployment.yaml" "$WORK/plain.yaml"
  cd "$WORK"
  ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' templates/root.yaml chart/templates/sub/nested.yaml plain.yaml)"
  [ "$status" -eq 0 ]
  grep -qxF -- plain.yaml "$WORK/argv"
  [ "$(grep -cF -e root.yaml -e nested.yaml "$WORK/argv")" -eq 0 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"templates/root.yaml"*"chart/templates/sub/nested.yaml" ]]
}

@test "kube-linter: plain manifests containing {{ outside a chart are still linted" {
  stub_kube_linter
  { cat "$KL_FIX/deployment.yaml"; echo '# {{ }}'; } > "$WORK/comment.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\n  annotations:\n    note: "{{x}}"\nspec:\n  containers:\n  - name: c\n    image: i\n    securityContext:\n      privileged: true\n' > "$WORK/annotation.yaml"
  ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$(printf '%s\n' "$WORK/comment.yaml" "$WORK/annotation.yaml")"
  [ "$status" -eq 0 ]
  grep -qxF -- "$WORK/comment.yaml" "$WORK/argv"
  grep -qxF -- "$WORK/annotation.yaml" "$WORK/argv"
  [ -z "$stderr" ]
}

@test "kube-linter: a manifest whose relative path starts with - is linted, not read as an option" {
  stub_kube_linter
  cp "$KL_FIX/deployment.yaml" "$WORK/-x.yaml"
  cd "$WORK"
  ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "-x.yaml"
  [ "$status" -eq 0 ]
  grep -qxF -- "./-x.yaml" "$WORK/argv"
}

@test "kube-linter: templates/ directory without a Chart.yaml beside it is not a chart" {
  stub_kube_linter
  mkdir -p "$WORK/app/templates"
  printf 'apiVersion: v2\nname: decoy\nversion: 0.1.0\n' > "$WORK/Chart.yaml"
  cp "$KL_FIX/helm-template.yaml" "$WORK/app/templates/deploy.yaml"
  ARGV_FILE="$WORK/argv" PATH="$WORK/bin:$PATH" \
    run --separate-stderr bash "$SCRIPT" "$WORK/app/templates/deploy.yaml"
  [ "$status" -eq 0 ]
  grep -qxF -- "$WORK/app/templates/deploy.yaml" "$WORK/argv"
  [ -z "$stderr" ]
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

@test "kube-linter: finding names the object from K8sObject and line is 0" {
  KUBELINTER_MOCK_FILE="$KL_FIX/kubelinter-violations.json" run --separate-stderr "$SCRIPT" "$KL_FIX/deployment.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | endswith("[Deployment nginx-deployment]")' >/dev/null
  echo "$output" | jq -e 'all(.[]; .line == 0)' >/dev/null
}

@test "kube-linter: absolute FilePath under the working directory becomes repo-relative" {
  mkdir -p "$WORK/k8s"
  cp "$KL_FIX/deployment.yaml" "$WORK/k8s/deployment.yaml"
  cd "$WORK"
  jq --arg f "$PWD/k8s/deployment.yaml" '.Reports[0].Object.Metadata.FilePath = $f' \
    "$KL_FIX/kubelinter-violations.json" > "$WORK/violations.json"
  KUBELINTER_MOCK_FILE="$WORK/violations.json" run --separate-stderr "$SCRIPT" k8s/deployment.yaml
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].file == "k8s/deployment.yaml"' >/dev/null
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
    length == 1 and .[0].source == "kube-linter" and .[0].file == "/nonexistent-kubelinter-root/k8s/broken.yaml" and .[0].line == 0
    and (.[0].finding | startswith("failed-to-load-object: failed to decode") and contains("[resource"))
    and (.[0].remediation | contains("valid k8s yaml"))
  ' >/dev/null
  REPORT_FILE=/dev/null PATH="$WORK/bin:$PATH" run --separate-stderr bash "$SCRIPT" "$WORK/broken.yaml"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

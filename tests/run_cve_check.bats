#!/usr/bin/env bats
# Tests for run-cve-check.sh.
#
# Two kinds of tests:
#   1. Parser-level: extract parse_go_mod() in isolation and assert the
#      ecosystem/name/version tuples it emits (covers issue #67).
#   2. End-to-end: feed a manifest plus an OSV_MOCK_FILE batch response (ids and
#      modified only, like the real querybatch; the full records come from
#      vulns/<id>.json beside it) and assert the resulting findings JSON. Where
#      the request itself matters, a curl stand-in on PATH records it. Fully offline.

bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  load test_helper
  SCRIPT="${SCRIPTS_DIR}/run-cve-check.sh"
  CVE_FIX="${FIXTURES_DIR}/cve"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# querybatch mock in the real shape: one result per id argument, {id, modified} only.
mock_batch() {
  jq -n '{results: [$ARGS.positional[] | {vulns: [{id: ., modified: "2025-06-01T00:00:00Z"}]}]}' \
    --args "$@" > "$WORK/batch.json"
}

# Advisory GHSA-test-ver on package $2 (ecosystem $1) with one introduced-0 range per fixed
# version after them, served as the only vulnerability of a one-package batch.
mock_advisory() {
  local eco="$1" name="$2"
  shift 2
  mkdir -p "$WORK/records"
  jq -n --arg eco "$eco" --arg name "$name" '{
      id: "GHSA-test-ver", summary: "Synthetic advisory", aliases: ["CVE-2025-00001"],
      severity: [{type: "CVSS_V3", score: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N"}],
      affected: [{package: {name: $name, ecosystem: $eco},
                  ranges: [$ARGS.positional[] | {type: "ECOSYSTEM", events: [{introduced: "0"}, {fixed: .}]}]}]}' \
    --args "$@" > "$WORK/records/GHSA-test-ver.json"
  mock_batch GHSA-test-ver
}

run_mocked() {
  OSV_MOCK_FILE="$WORK/batch.json" OSV_VULNS_MOCK_DIR="$WORK/records" run --separate-stderr "$SCRIPT" "$@"
}

# Version in the first remediation ("Upgrade X to <v> or later."), "none" when no fix is recommended.
recommended_fix() {
  echo "$output" | jq -r '.[0].remediation | capture("^Upgrade \\S+ to (?<v>\\S+) or later").v // "none"'
}

# Adds another affected package (ecosystem $1, name $2, fixed in $3) to the record mock_advisory wrote.
add_affected() {
  jq --arg eco "$1" --arg name "$2" --arg fixed "$3" \
    '.affected += [{package: {name: $name, ecosystem: $eco}, ranges: [{type: "ECOSYSTEM", events: [{introduced: "0"}, {fixed: $fixed}]}]}]' \
    "$WORK/records/GHSA-test-ver.json" > "$WORK/records/updated.json"
  mv "$WORK/records/updated.json" "$WORK/records/GHSA-test-ver.json"
}

# curl stand-in on PATH. Logs "<method> <url>" to $SHIM_LOG, saves the last POST body to
# $SHIM_BODY, answers POST from $SHIM_BATCH (default: no vulnerabilities) and GET .../<id>
# from $SHIM_VULNS_DIR/<id>.json (exit 22 when missing, like --fail-with-body on a 404). With
# $SHIM_FAIL_POST=N, the Nth POST and every later one exit 22 like --fail-with-body on a 5xx.
make_curl_shim() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET url="" body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$SHIM_LOG"
if [[ "$method" == POST ]]; then
  printf '%s\n' "$body" > "$SHIM_BODY"
  if [[ -n "${SHIM_FAIL_POST:-}" && "$(grep -c '^POST ' "$SHIM_LOG")" -ge "$SHIM_FAIL_POST" ]]; then echo '{"code":13,"message":"Internal error"}'; exit 22; fi
  if [[ -n "${SHIM_BATCH:-}" ]]; then cat "$SHIM_BATCH"; else printf '%s' "$body" | jq -c '{results: [.queries[] | {}]}'; fi
  exit 0
fi
id="${url##*/}"
if [[ -r "${SHIM_VULNS_DIR:-/nonexistent}/${id}.json" ]]; then cat "${SHIM_VULNS_DIR}/${id}.json"; exit 0; fi
echo '{"code":5,"message":"Vulnerability not found"}'
exit 22
EOF
  chmod +x "$WORK/bin/curl"
  export PATH="$WORK/bin:$PATH" SHIM_LOG="$WORK/curl.log" SHIM_BODY="$WORK/body.json"
}

# "name@version" for each query of the last request recorded by make_curl_shim, in order.
queried_packages() {
  jq -r '.queries[] | "\(.package.name)@\(.version)"' "$SHIM_BODY"
}

# ---------------------------------------------------------------------------
# parse_go_mod — replace directive handling (#67)
# ---------------------------------------------------------------------------

@test "parse_go_mod: replace applies when require comes before replace (#67)" {
  load_function "$SCRIPT" parse_go_mod
  run parse_go_mod "$CVE_FIX/go.mod.require-before-replace"
  [ "$status" -eq 0 ]
  # The replaced module must resolve to the fork, regardless of file ordering.
  [[ "$output" == *"Go	example.com/fork	1.2.3"* ]]
  # The original module/version must NOT be queried.
  [[ "$output" != *"example.com/original	1.0.0"* ]]
  # Unreplaced modules pass through untouched.
  [[ "$output" == *"Go	example.com/safe	2.0.0"* ]]
}

@test "parse_go_mod: replace applies when replace comes before require" {
  load_function "$SCRIPT" parse_go_mod
  run parse_go_mod "$CVE_FIX/go.mod.replace-before-require"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Go	example.com/fork	1.2.3"* ]]
  [[ "$output" != *"example.com/original	1.0.0"* ]]
  [[ "$output" == *"Go	example.com/safe	2.0.0"* ]]
}

@test "parse_go_mod: local-path replace keeps original (cannot query local fork)" {
  load_function "$SCRIPT" parse_go_mod
  run parse_go_mod "$CVE_FIX/go.mod.local-replace"
  [ "$status" -eq 0 ]
  # A local replacement target (../local/fork) is not queryable; the original
  # module is left in place rather than emitting a bogus local path.
  [[ "$output" == *"Go	example.com/original	1.0.0"* ]]
  [[ "$output" != *"local"* ]]
}

@test "parse_go_mod: unclosed replace block does not skip require entries in pass 2" {
  load_function "$SCRIPT" parse_go_mod
  run parse_go_mod "$CVE_FIX/go.mod.unclosed-replace"
  [ "$status" -eq 0 ]
  # in_replace state must be reset at the pass-2 boundary; if it leaks,
  # all require lines in pass 2 are treated as replace lines and silently skipped.
  [[ "$output" == *"Go	example.com/safe	2.0.0"* ]]
}

@test "parse_go_mod: a versioned replace does not apply to another required version" {
  load_function "$SCRIPT" parse_go_mod
  cat > "$WORK/go.mod" <<'EOF'
module example.com/app

go 1.22

require example.com/one v1.5.0

require (
	example.com/two v1.5.0
)

replace example.com/one v1.0.0 => example.com/fork-one v1.2.3

replace (
	example.com/two v1.0.0 => example.com/fork-two v1.2.3
)
EOF
  run parse_go_mod "$WORK/go.mod"
  [ "$status" -eq 0 ]
  [ "$output" = $'Go\texample.com/one\t1.5.0\nGo\texample.com/two\t1.5.0' ]
}

@test "parse_go_mod: a versionless replace applies to any required version" {
  load_function "$SCRIPT" parse_go_mod
  cat > "$WORK/go.mod" <<'EOF'
module example.com/app

go 1.22

require example.com/one v1.5.0

require (
	example.com/two v1.5.0
)

replace example.com/one => example.com/fork-one v2.0.0

replace example.com/one v1.0.0 => example.com/other v9.9.9

replace (
	example.com/two => example.com/fork-two v2.0.0
	example.com/two v1.0.0 => example.com/other v9.9.9
)
EOF
  run parse_go_mod "$WORK/go.mod"
  [ "$status" -eq 0 ]
  [ "$output" = $'Go\texample.com/fork-one\t2.0.0\nGo\texample.com/fork-two\t2.0.0' ]
}

@test "parse_go_mod: a versioned replace applies to its exact version ahead of a versionless one" {
  load_function "$SCRIPT" parse_go_mod
  cat > "$WORK/go.mod" <<'EOF'
module example.com/app

go 1.22

require example.com/one v1.0.0

require (
	example.com/two v1.0.0
)

replace example.com/one v1.0.0 => example.com/fork-one v1.2.3

replace example.com/one => example.com/other v9.9.9

replace (
	example.com/two v1.0.0 => example.com/fork-two v1.2.3
	example.com/two => example.com/other v9.9.9
)
EOF
  run parse_go_mod "$WORK/go.mod"
  [ "$status" -eq 0 ]
  [ "$output" = $'Go\texample.com/fork-one\t1.2.3\nGo\texample.com/fork-two\t1.2.3' ]
}

# ---------------------------------------------------------------------------
# No-op paths
# ---------------------------------------------------------------------------

@test "cve-check: empty input returns empty array" {
  run --separate-stderr "$SCRIPT" ""
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "cve-check: no manifest files in input returns empty array" {
  run --separate-stderr "$SCRIPT" $'src/foo.go\nREADME.md'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "cve-check: nonexistent manifest path returns empty array" {
  run --separate-stderr "$SCRIPT" "nonexistent/go.mod"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# End-to-end with OSV batch mock
# ---------------------------------------------------------------------------

@test "cve-check: go.mod with critical CVE produces Critical finding with dependency-cve category" {
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-critical.json" run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length > 0' >/dev/null
  echo "$output" | jq -e '.[0].severity == "Critical"' >/dev/null
  echo "$output" | jq -e '.[0].source == "dependency-check"' >/dev/null
  echo "$output" | jq -e '.[0].confidence >= 80' >/dev/null
  echo "$output" | jq -e '.[0].category == "dependency-cve"' >/dev/null
  echo "$output" | jq -e '.[0].file | endswith("go.mod")' >/dev/null
}

@test "cve-check: empty OSV batch response returns empty findings array" {
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-empty.json" run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "cve-check: unparseable package.json is exit 1 with empty array" {
  printf '%s\n' '{not json' > "$WORK/package.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "parse_requirements_txt: unreadable file returns 1" {
  load_function "$SCRIPT" parse_requirements_txt
  run parse_requirements_txt "$WORK/missing-requirements.txt"
  [ "$status" -eq 1 ]
}

@test "parse_requirements_txt: no pinned lines is empty success" {
  load_function "$SCRIPT" parse_requirements_txt
  printf '%s\n' '# comment' 'requests' > "$WORK/requirements.txt"
  run parse_requirements_txt "$WORK/requirements.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cve-check: OSV results length mismatch is exit 1 with empty array" {
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-mismatch.json" run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "cve-check: malformed OSV batch response is exit 1 with empty array" {
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-malformed.json" run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
}

@test "cve-check: CVSS v4 vector maps to High (conservative fallback)" {
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-cvss4.json" run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length > 0' >/dev/null
  echo "$output" | jq -e '.[0].severity == "High"' >/dev/null
  echo "$output" | jq -e '.[0].category == "dependency-cve"' \
    || { echo "Actual category: $(echo "$output" | jq -r '.[0].category // "PARSE_ERROR"')" >&2; false; }
}

# ---------------------------------------------------------------------------
# Full records: querybatch returns only {id, modified}
# ---------------------------------------------------------------------------

@test "cve-check: ids-only querybatch response is expanded via GET /v1/vulns/{id}" {
  make_curl_shim
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  SHIM_BATCH="$CVE_FIX/osv-batch-critical.json" SHIM_VULNS_DIR="$CVE_FIX/vulns" \
    OSV_VULNS_URL="https://osv.example.test/v1/vulns" \
    run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].severity == "Critical"' >/dev/null
  echo "$output" | jq -e '.[0].finding | startswith("CVE-2025-99999 (GHSA-xxxx-critical) [CVSS 9.8]: Critical remote code execution")' >/dev/null
  echo "$output" | jq -e '.[0].remediation | startswith("Upgrade example.com/fork to 1.2.4 or later")' >/dev/null
  grep -qx 'GET https://osv.example.test/v1/vulns/GHSA-xxxx-critical' "$SHIM_LOG"
}

@test "cve-check: OSV_VULNS_MOCK_DIR supplies the records instead of vulns/ beside the mock" {
  mkdir "$WORK/records"
  jq '.summary = "Record from the override dir"' "$CVE_FIX/vulns/GHSA-xxxx-critical.json" \
    > "$WORK/records/GHSA-xxxx-critical.json"
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-critical.json" OSV_VULNS_MOCK_DIR="$WORK/records" \
    run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].finding | contains("Record from the override dir")' >/dev/null
}

@test "cve-check: each unique vulnerability id is fetched once" {
  make_curl_shim
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  mock_batch GHSA-xxxx-critical GHSA-xxxx-critical
  SHIM_BATCH="$WORK/batch.json" SHIM_VULNS_DIR="$CVE_FIX/vulns" run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 2' >/dev/null
  [ "$(grep -c '^GET ' "$SHIM_LOG")" -eq 1 ]
  grep -qx 'GET https://api.osv.dev/v1/vulns/GHSA-xxxx-critical' "$SHIM_LOG"
}

@test "cve-check: vulnerability id with unexpected characters is refused with exit 1" {
  printf '%s\n' '{"dependencies":{"lib":"3.5.0"}}' > "$WORK/package.json"
  mock_batch 'GHSA-x/../../etc/passwd'
  OSV_MOCK_FILE="$WORK/batch.json" OSV_VULNS_MOCK_DIR="$CVE_FIX/vulns" \
    run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"Refusing OSV vulnerability id"* ]]
}

@test "cve-check: failed record fetch is exit 1 with empty array" {
  make_curl_shim
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  SHIM_BATCH="$CVE_FIX/osv-batch-critical.json" SHIM_VULNS_DIR="$WORK/no-records" \
    run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"OSV record request failed (curl exit 22) for GHSA-xxxx-critical"* ]]
}

@test "cve-check: record missing from OSV_VULNS_MOCK_DIR is exit 1 with empty array" {
  mkdir "$WORK/records"
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-critical.json" OSV_VULNS_MOCK_DIR="$WORK/records" \
    run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"OSV record GHSA-xxxx-critical not readable"* ]]
}

@test "cve-check: record that is not the requested vulnerability is exit 1 with empty array" {
  mkdir "$WORK/records"
  printf '%s\n' '{"code":5,"message":"Vulnerability not found"}' > "$WORK/records/GHSA-xxxx-critical.json"
  cp "$CVE_FIX/go.mod.replace-before-require" "$WORK/go.mod"
  OSV_MOCK_FILE="$CVE_FIX/osv-batch-critical.json" OSV_VULNS_MOCK_DIR="$WORK/records" \
    run --separate-stderr "$SCRIPT" "$WORK/go.mod"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [[ "$stderr" == *"unexpected record for GHSA-xxxx-critical"* ]]
}

# ---------------------------------------------------------------------------
# Batches: a failure after earlier batches keeps their findings, and still fails
# ---------------------------------------------------------------------------

# 1001 exact npm dependencies make two batches; lib0 (first batch) has one advisory, the rest none.
two_batches_with_a_finding_in_the_first() {
  mock_advisory npm lib0 1.0.1
  jq -n '{dependencies: ([range(1001) | {key: "lib\(.)", value: "1.0.0"}] | from_entries)}' > "$WORK/package.json"
  jq -n '{results: ([{vulns: [{id: "GHSA-test-ver", modified: "2025-06-01T00:00:00Z"}]}] + [range(999) | {}])}' > "$WORK/batch1000.json"
}

@test "cve-check: a failing second batch request still reports the findings of the first batch" {
  make_curl_shim
  two_batches_with_a_finding_in_the_first
  SHIM_BATCH="$WORK/batch1000.json" SHIM_VULNS_DIR="$WORK/records" SHIM_FAIL_POST=2 \
    run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^POST ' "$SHIM_LOG")" -eq 2 ]
  echo "$output" | jq -e 'length == 1 and (.[0].finding | endswith("Affects lib0@1.0.0."))' >/dev/null
  grep -qF 'OSV batch API request failed' <<<"$stderr"
  grep -qF 'WARNING: CVE check incomplete' <<<"$stderr"
}

@test "cve-check: a malformed advisory record after a finding in the same batch keeps that finding" {
  make_curl_shim
  mock_advisory npm lib0 1.0.1
  jq '.id = "GHSA-bad" | .severity = [{score: "7.5"}]' "$WORK/records/GHSA-test-ver.json" > "$WORK/records/GHSA-bad.json"
  printf '%s\n' '{"dependencies":{"lib0":"1.0.0","lib1":"1.0.0"}}' > "$WORK/package.json"
  jq -n '{results: [{vulns: [{id: "GHSA-test-ver"}]}, {vulns: [{id: "GHSA-bad"}]}]}' > "$WORK/batch2.json"
  SHIM_BATCH="$WORK/batch2.json" SHIM_VULNS_DIR="$WORK/records" run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e 'length == 1 and (.[0].finding | endswith("Affects lib0@1.0.0."))' >/dev/null
  grep -qF 'Failed to parse OSV findings for npm/lib1@1.0.0' <<<"$stderr"
  grep -qF 'WARNING: CVE check incomplete' <<<"$stderr"
}

# ---------------------------------------------------------------------------
# Advisory fields: CVE alias fallback and fixed-version selection
# ---------------------------------------------------------------------------

@test "cve-check: advisory without a CVE alias reports the GHSA id" {
  printf '%s\n' '{"dependencies":{"lib":"3.5.0"}}' > "$WORK/package.json"
  mock_batch GHSA-aaaa-ghsa-only
  OSV_MOCK_FILE="$WORK/batch.json" OSV_VULNS_MOCK_DIR="$CVE_FIX/vulns" \
    run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].severity == "High"' >/dev/null
  echo "$output" | jq -e '.[0].finding | startswith("GHSA-aaaa-ghsa-only [CVSS 7.5]: Advisory without a CVE alias. Affects lib@3.5.0.")' >/dev/null
}

@test "cve-check: fixed version is the smallest above the queried version, not the first listed" {
  mock_batch GHSA-bbbb-multi-interval

  printf '%s\n' '{"dependencies":{"lib":"3.5.0"}}' > "$WORK/package.json"
  OSV_MOCK_FILE="$WORK/batch.json" OSV_VULNS_MOCK_DIR="$CVE_FIX/vulns" \
    run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].remediation | startswith("Upgrade lib to 4.0.0 or later.")' >/dev/null

  printf '%s\n' '{"dependencies":{"lib":"1.5.0"}}' > "$WORK/package.json"
  OSV_MOCK_FILE="$WORK/batch.json" OSV_VULNS_MOCK_DIR="$CVE_FIX/vulns" \
    run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].remediation | startswith("Upgrade lib to 2.0.0 or later.")' >/dev/null
}

@test "cve-check: a fix published only for another package in the advisory is not recommended" {
  printf '%s\n' '{"dependencies":{"lib":"3.5.0"}}' > "$WORK/package.json"
  mock_batch GHSA-cccc-unfixed
  OSV_MOCK_FILE="$WORK/batch.json" OSV_VULNS_MOCK_DIR="$CVE_FIX/vulns" \
    run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].remediation | startswith("No fixed version published yet.")' >/dev/null
  [[ "$output" != *"9.9.9"* ]]
}

@test "cve-check: a PyPI requirement takes its fix from the advisory entry with the same PEP 503 normalized name" {
  mock_advisory PyPI flask-cors 3.0.5
  add_affected PyPI other-pkg 3.0.1
  add_affected npm flask-cors 3.0.2
  local spelling
  for spelling in flask-cors Flask-Cors Flask_Cors flask.cors FLASK__CORS Flask.-_Cors; do
    printf '%s==3.0.0\n' "$spelling" > "$WORK/requirements.txt"
    run_mocked "$WORK/requirements.txt"
    [ "$status" -eq 0 ]
    [ "$(recommended_fix)" = "3.0.5" ] || { echo "$spelling: recommended $(recommended_fix)" >&2; false; }
  done
}

@test "cve-check: no fix is recommended when no affected entry matches the queried package" {
  mock_advisory PyPI django 3.2.13
  add_affected PyPI other-pkg 9.9.9
  printf 'requests==2.0.0\n' > "$WORK/requirements.txt"
  run_mocked "$WORK/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "none" ]
  echo "$output" | jq -e '.[0].remediation | startswith("No fixed version published yet.")' >/dev/null
}

@test "cve-check: Go, npm and Packagist names match the advisory entry exactly" {
  mock_advisory Go example.com/lib 1.2.4
  printf '%s\n' 'module example.com/app' '' 'go 1.22' '' 'require example.com/Lib v1.2.3' > "$WORK/go.mod"
  run_mocked "$WORK/go.mod"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "none" ]

  mock_advisory npm lib 1.2.4
  printf '%s\n' '{"dependencies":{"Lib":"1.2.3"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "none" ]

  mock_advisory Packagist vendor/lib 1.2.4
  printf '%s\n' '{"require":{"Vendor/Lib":"1.2.3"}}' > "$WORK/composer.json"
  run_mocked "$WORK/composer.json"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "none" ]
}

# ---------------------------------------------------------------------------
# Version ordering: pre-releases sort below their release, .post above it
# ---------------------------------------------------------------------------

@test "cve-check: a stable fix above an installed pre-release is recommended" {
  mock_advisory npm lib 1.2.3
  printf '%s\n' '{"dependencies":{"lib":"1.2.3-rc.1"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "1.2.3" ]
}

@test "cve-check: a pre-release fix below the installed release is not recommended" {
  mock_advisory npm lib 1.2.3-rc.2 1.2.4
  printf '%s\n' '{"dependencies":{"lib":"1.2.3"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "1.2.4" ]
}

@test "cve-check: pre-releases of one release are ordered by their numbers" {
  mock_advisory npm lib 1.2.3-rc.2 1.2.3-rc.10 1.2.3
  printf '%s\n' '{"dependencies":{"lib":"1.2.3-rc.1"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$(recommended_fix)" = "1.2.3-rc.2" ]
  printf '%s\n' '{"dependencies":{"lib":"1.2.3-rc.2"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$(recommended_fix)" = "1.2.3-rc.10" ]
  printf '%s\n' '{"dependencies":{"lib":"1.2.3-rc.10"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$(recommended_fix)" = "1.2.3" ]
}

@test "cve-check: PEP 440 pre-releases sort below their release with or without a separator" {
  mock_advisory PyPI lib 1.2.3
  local v
  for v in 1.2.3rc1 1.2.3.rc1 1.2.3-rc1 1.2.3_rc1 1.2.3a1 1.2.3b2 1.2.3c1 1.2.3alpha1 1.2.3beta2 1.2.3pre1 1.2.3.dev4; do
    printf 'lib==%s\n' "$v" > "$WORK/requirements.txt"
    run_mocked "$WORK/requirements.txt"
    [ "$status" -eq 0 ]
    [ "$(recommended_fix)" = "1.2.3" ] || { echo "installed $v: recommended $(recommended_fix)" >&2; false; }
  done
}

@test "cve-check: PEP 440 post-releases sort above their release" {
  mock_advisory PyPI lib 1.2.3 1.2.3.post1 1.2.4
  printf 'lib==1.2.3\n' > "$WORK/requirements.txt"
  run_mocked "$WORK/requirements.txt"
  [ "$(recommended_fix)" = "1.2.3.post1" ]
  printf 'lib==1.2.3.post1\n' > "$WORK/requirements.txt"
  run_mocked "$WORK/requirements.txt"
  [ "$(recommended_fix)" = "1.2.4" ]

  mock_advisory PyPI lib 1.2.3.post 1.2.4
  printf 'lib==1.2.3\n' > "$WORK/requirements.txt"
  run_mocked "$WORK/requirements.txt"
  [ "$(recommended_fix)" = "1.2.3.post" ]

  mock_advisory PyPI lib 1.2.1 1.2.4
  printf 'lib==1.2.post1\n' > "$WORK/requirements.txt"
  run_mocked "$WORK/requirements.txt"
  [ "$(recommended_fix)" = "1.2.1" ]
}

@test "cve-check: an installed npm beta is below a release candidate fix of the same release" {
  mock_advisory npm lib 2.0.0-rc.1
  printf '%s\n' '{"dependencies":{"lib":"2.0.0-beta.2"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "2.0.0-rc.1" ]
}

@test "cve-check: an installed PEP 440 beta is below a release candidate fix of the same release" {
  mock_advisory PyPI lib 1.0rc1
  printf 'lib==1.0b2\n' > "$WORK/requirements.txt"
  run_mocked "$WORK/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "1.0rc1" ]
}

@test "cve-check: semver pre-release identifiers are ordered per semver 2.0.0 section 11" {
  local chain=(1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0)
  mock_advisory npm lib "${chain[@]}"
  local i
  for (( i=0; i<${#chain[@]}-1; i++ )); do
    printf '{"dependencies":{"lib":"%s"}}\n' "${chain[$i]}" > "$WORK/package.json"
    run_mocked "$WORK/package.json"
    [ "$status" -eq 0 ]
    [ "$(recommended_fix)" = "${chain[$((i + 1))]}" ] || { echo "installed ${chain[$i]}: recommended $(recommended_fix)" >&2; false; }
  done
}

@test "cve-check: PEP 440 classes are ordered dev < a < b < rc < release < post" {
  local chain=(1.0.dev1 1.0a1 1.0b1 1.0b2 1.0rc1 1.0 1.0.post1)
  mock_advisory PyPI lib "${chain[@]}"
  local i
  for (( i=0; i<${#chain[@]}-1; i++ )); do
    printf 'lib==%s\n' "${chain[$i]}" > "$WORK/requirements.txt"
    run_mocked "$WORK/requirements.txt"
    [ "$status" -eq 0 ]
    [ "$(recommended_fix)" = "${chain[$((i + 1))]}" ] || { echo "installed ${chain[$i]}: recommended $(recommended_fix)" >&2; false; }
  done
}

@test "cve-check: a leading v, V or = and build metadata are ignored when comparing versions" {
  printf '%s\n' '{"dependencies":{"lib":"1.2.3"}}' > "$WORK/package.json"
  local p
  for p in v V =; do
    mock_advisory npm lib "${p}1.2.4"
    run_mocked "$WORK/package.json"
    [ "$status" -eq 0 ]
    [ "$(recommended_fix)" = "${p}1.2.4" ] || { echo "prefix $p: recommended $(recommended_fix)" >&2; false; }
  done

  mock_advisory npm lib 1.2.3+build.9 1.2.4
  printf '%s\n' '{"dependencies":{"lib":"1.2.3+build.5"}}' > "$WORK/package.json"
  run_mocked "$WORK/package.json"
  [ "$(recommended_fix)" = "1.2.4" ]
}

@test "cve-check: a Go pseudo-version sorts below the release it precedes" {
  mock_advisory Go example.com/lib 1.2.4
  printf '%s\n' 'module example.com/app' '' 'go 1.22' '' 'require example.com/lib v1.2.4-0.20210817164053-abcdef123456' > "$WORK/go.mod"
  run_mocked "$WORK/go.mod"
  [ "$status" -eq 0 ]
  [ "$(recommended_fix)" = "1.2.4" ]
}

# ---------------------------------------------------------------------------
# Queried versions: exact manifest versions or lockfile-resolved, never a range
# ---------------------------------------------------------------------------

@test "cve-check: ranged npm dependency is queried at the package-lock.json version (lockfileVersion 3)" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0","@scope/pkg":"~1.2"},"devDependencies":{"express":">=4.0.0 <5.0.0"}}' \
    > "$WORK/package.json"
  cat > "$WORK/package-lock.json" <<'EOF'
{"lockfileVersion":3,"packages":{"":{"name":"app"},
 "node_modules/lodash":{"version":"4.17.20"},
 "node_modules/@scope/pkg":{"version":"1.2.9"},
 "node_modules/express":{"version":"4.18.2"},
 "node_modules/other/node_modules/lodash":{"version":"3.0.0"}}}
EOF
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  jq -e '.queries == [
    {"version":"4.17.20","package":{"name":"lodash","ecosystem":"npm"}},
    {"version":"1.2.9","package":{"name":"@scope/pkg","ecosystem":"npm"}},
    {"version":"4.18.2","package":{"name":"express","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" != *"skipped ranged"* ]]
}

@test "cve-check: ranged npm dependency is queried at the package-lock.json version (lockfileVersion 1)" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0"}}' > "$WORK/package.json"
  printf '%s\n' '{"lockfileVersion":1,"dependencies":{"lodash":{"version":"4.17.20","dependencies":{"nested":{"version":"1.0.0"}}}}}' \
    > "$WORK/package-lock.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [{"version":"4.17.20","package":{"name":"lodash","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
}

@test "cve-check: optionalDependencies are queried at their exact version or the package-lock.json version" {
  make_curl_shim
  printf '%s\n' '{"optionalDependencies":{"fsevents":"2.3.2","chokidar":"^3.5.0"}}' > "$WORK/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/chokidar":{"version":"3.5.3"}}}' \
    > "$WORK/package-lock.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"2.3.2","package":{"name":"fsevents","ecosystem":"npm"}},
    {"version":"3.5.3","package":{"name":"chokidar","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" != *"skipped ranged"* ]]
}

@test "cve-check: an optionalDependencies spec overrides the same name in dependencies" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lib":"1.0.0","ranged":"1.0.0","other":"3.0.0"},"optionalDependencies":{"lib":"2.0.0","ranged":"^1.0.0"}}' \
    > "$WORK/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/ranged":{"version":"1.4.0"}}}' \
    > "$WORK/package-lock.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"2.0.0","package":{"name":"lib","ecosystem":"npm"}},
    {"version":"1.4.0","package":{"name":"ranged","ecosystem":"npm"}},
    {"version":"3.0.0","package":{"name":"other","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
}

@test "cve-check: an exact npm alias is queried under the package it points to, scoped or not" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"kpg":"npm:pkg@1.0.0","scoped":"npm:@scope/pkg@=2.0.0","ranged":"npm:pkg@^3.0.0"},"devDependencies":{"devalias":"npm:devpkg@v4.1.0"}}' \
    > "$WORK/package.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = $'pkg@1.0.0\n@scope/pkg@2.0.0\ndevpkg@4.1.0' ]
  grep -qF 'skipped ranged dependencies no lockfile resolves: 1 in' <<<"$stderr"
}

@test "cve-check: a ranged npm alias is queried at the package-lock.json version (lockfileVersion 3)" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"kpg":"npm:pkg@^1.0.0","scoped":"npm:@scope/pkg@~1.2","bare":"npm:other"}}' > "$WORK/package.json"
  cat > "$WORK/package-lock.json" <<'EOF'
{"lockfileVersion":3,"packages":{"":{},
 "node_modules/kpg":{"name":"pkg","version":"1.4.2"},
 "node_modules/scoped":{"name":"@scope/pkg","version":"1.2.9"},
 "node_modules/bare":{"name":"other","version":"7.0.0"}}}
EOF
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = $'pkg@1.4.2\n@scope/pkg@1.2.9\nother@7.0.0' ]
  [ "$(grep -c 'skipped ranged' <<<"$stderr")" -eq 0 ]
}

@test "cve-check: a ranged npm alias is queried at the version package-lock.json lockfileVersion 1 records as npm:<name>@<version>" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"kpg":"npm:pkg@^1.0.0","scoped":"npm:@scope/pkg@~1.2","bare":"npm:other"}}' > "$WORK/package.json"
  cat > "$WORK/package-lock.json" <<'EOF'
{"lockfileVersion":1,"dependencies":{
 "kpg":{"version":"npm:pkg@1.4.2"},"scoped":{"version":"npm:@scope/pkg@1.2.9"},"bare":{"version":"npm:other@7.0.0"}}}
EOF
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = $'pkg@1.4.2\n@scope/pkg@1.2.9\nother@7.0.0' ]
  [ "$(grep -c 'skipped ranged' <<<"$stderr")" -eq 0 ]
}

@test "cve-check: an npm alias finding names the manifest entry and takes its fix from the package it points to" {
  make_curl_shim
  mock_advisory npm pkg 1.0.1
  printf '%s\n' '{' '  "dependencies": {' '    "kpg": "npm:pkg@1.0.0"' '  }' '}' > "$WORK/package.json"
  SHIM_BATCH="$WORK/batch.json" SHIM_VULNS_DIR="$WORK/records" run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = "pkg@1.0.0" ]
  echo "$output" | jq -e '.[0].finding | endswith("Affects kpg@1.0.0.")' >/dev/null
  echo "$output" | jq -e '.[0].remediation | startswith("Upgrade kpg to 1.0.1 or later.")' >/dev/null
  echo "$output" | jq -e '.[0].line == 3' >/dev/null
}

@test "cve-check: ranged Composer dependency is queried at the composer.lock version" {
  make_curl_shim
  printf '%s\n' '{"require":{"php":">=8.1","guzzlehttp/guzzle":"^7.0"},"require-dev":{"monolog/monolog":"~2.5|^3.0"}}' \
    > "$WORK/composer.json"
  printf '%s\n' '{"packages":[{"name":"guzzlehttp/guzzle","version":"7.8.1"}],"packages-dev":[{"name":"monolog/monolog","version":"v3.5.0"}]}' \
    > "$WORK/composer.lock"
  run --separate-stderr "$SCRIPT" "$WORK/composer.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"7.8.1","package":{"name":"guzzlehttp/guzzle","ecosystem":"Packagist"}},
    {"version":"3.5.0","package":{"name":"monolog/monolog","ecosystem":"Packagist"}}]' "$SHIM_BODY" >/dev/null
}

@test "cve-check: Composer platform packages are skipped but php-prefixed vendors are queried" {
  make_curl_shim
  cat > "$WORK/composer.json" <<'EOF'
{"require":{"php":">=8.1","php-64bit":">=8.1","ext-json":">=8.0","lib-curl":">=7.29","composer-plugin-api":"^2.0",
 "monolog/monolog":"2.9.1","php-http/httplug":"2.4.0"},
 "require-dev":{"phpunit/phpunit":"9.5.0"}}
EOF
  run --separate-stderr "$SCRIPT" "$WORK/composer.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"2.9.1","package":{"name":"monolog/monolog","ecosystem":"Packagist"}},
    {"version":"2.4.0","package":{"name":"php-http/httplug","ecosystem":"Packagist"}},
    {"version":"9.5.0","package":{"name":"phpunit/phpunit","ecosystem":"Packagist"}}]' "$SHIM_BODY" >/dev/null
}

@test "cve-check: wildcard npm specs are queried at the package-lock.json version" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"a":"*","b":"x","c":"X","d":"latest","e":""}}' > "$WORK/package.json"
  cat > "$WORK/package-lock.json" <<'EOF'
{"lockfileVersion":3,"packages":{"":{},
 "node_modules/a":{"version":"1.0.0"},"node_modules/b":{"version":"2.0.0"},"node_modules/c":{"version":"3.0.0"},
 "node_modules/d":{"version":"4.0.0"},"node_modules/e":{"version":"5.0.0"}}}
EOF
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"1.0.0","package":{"name":"a","ecosystem":"npm"}},
    {"version":"2.0.0","package":{"name":"b","ecosystem":"npm"}},
    {"version":"3.0.0","package":{"name":"c","ecosystem":"npm"}},
    {"version":"4.0.0","package":{"name":"d","ecosystem":"npm"}},
    {"version":"5.0.0","package":{"name":"e","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" != *"skipped ranged"* ]]
}

@test "cve-check: wildcard npm specs without a lockfile get one stderr note and no OSV request" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"a":"*","b":"latest"}}' > "$WORK/package.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ ! -e "$SHIM_LOG" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'skipped ranged dependencies')" -eq 1 ]
  [[ "$stderr" == *": 2 in "* ]]
}

@test "cve-check: non-registry npm specs are never queried, even when the lockfile has an entry" {
  make_curl_shim
  cat > "$WORK/package.json" <<'EOF'
{"dependencies":{"reg":"*","f":"file:../x","l":"link:../y","w":"workspace:*","g":"git+https://example.com/r.git",
 "h":"github:org/repo","u":"https://example.com/p.tgz","s":"org/repo","p":"../local"}}
EOF
  cat > "$WORK/package-lock.json" <<'EOF'
{"lockfileVersion":3,"packages":{"":{},"node_modules/reg":{"version":"1.0.0"},
 "node_modules/f":{"version":"9.9.9"},"node_modules/l":{"version":"9.9.9"},"node_modules/w":{"version":"9.9.9"},
 "node_modules/g":{"version":"9.9.9"},"node_modules/h":{"version":"9.9.9"},"node_modules/u":{"version":"9.9.9"},
 "node_modules/s":{"version":"9.9.9"},"node_modules/p":{"version":"9.9.9"}}}
EOF
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [{"version":"1.0.0","package":{"name":"reg","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" != *"skipped ranged"* ]]
}

@test "cve-check: npm workspace link with a wildcard spec is skipped without a note" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"sibling":"*","reg":"*"}}' > "$WORK/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{"":{},"node_modules/sibling":{"resolved":"packages/sibling","link":true},"node_modules/reg":{"version":"1.0.0"}}}' \
    > "$WORK/package-lock.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [{"version":"1.0.0","package":{"name":"reg","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" != *"skipped ranged"* ]]
}

@test "cve-check: Composer wildcard specs use composer.lock, dev branches are skipped" {
  make_curl_shim
  printf '%s\n' '{"require":{"vendor/a":"*","vendor/b":"dev-main","vendor/c":"1.x-dev","vendor/d":"^2.0"}}' > "$WORK/composer.json"
  printf '%s\n' '{"packages":[{"name":"vendor/a","version":"2.5.0"},{"name":"vendor/b","version":"dev-main"},{"name":"vendor/c","version":"1.x-dev"},{"name":"vendor/d","version":"2.1.0"}],"packages-dev":[]}' \
    > "$WORK/composer.lock"
  run --separate-stderr "$SCRIPT" "$WORK/composer.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"2.5.0","package":{"name":"vendor/a","ecosystem":"Packagist"}},
    {"version":"2.1.0","package":{"name":"vendor/d","ecosystem":"Packagist"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" != *"skipped ranged"* ]]

  rm "$WORK/composer.lock" "$SHIM_LOG"
  run --separate-stderr "$SCRIPT" "$WORK/composer.json"
  [ "$status" -eq 0 ]
  [ ! -e "$SHIM_LOG" ]
  [[ "$stderr" == *": 2 in "* ]]
}

@test "cve-check: without a lockfile only exact npm versions are queried and ranges get one stderr note" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0","express":">=4.0.0 <5.0.0","left-pad":"1.3.0","pinned":"v2.0.1"},"devDependencies":{"mocha":"=10.2.0","chai":"4.x"}}' \
    > "$WORK/package.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  jq -e '.queries == [
    {"version":"1.3.0","package":{"name":"left-pad","ecosystem":"npm"}},
    {"version":"2.0.1","package":{"name":"pinned","ecosystem":"npm"}},
    {"version":"10.2.0","package":{"name":"mocha","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
  [ "$(printf '%s\n' "$stderr" | grep -c 'skipped ranged dependencies')" -eq 1 ]
  [[ "$stderr" == *": 3 in "* ]]
}

@test "cve-check: ranged-only manifest without a lockfile makes no OSV request" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0"}}' > "$WORK/package.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ ! -e "$SHIM_LOG" ]
  [[ "$stderr" == *"skipped ranged dependencies"* ]]
}

@test "cve-check: unresolved ranges across manifests produce a single stderr note" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0"}}' > "$WORK/package.json"
  printf '%s\n' '{"require":{"guzzlehttp/guzzle":"^7.0"}}' > "$WORK/composer.json"
  printf '%s\n' 'requests>=2.0' > "$WORK/requirements.txt"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"$'\n'"$WORK/composer.json"$'\n'"$WORK/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'skipped ranged dependencies')" -eq 1 ]
  [[ "$stderr" == *": 3 in "*package.json*composer.json*requirements.txt* ]]
}

@test "cve-check: requirements.txt queries only == and === pins" {
  make_curl_shim
  printf '%s\n' 'flask==2.3.3' 'pinned===1.0.0 ; python_version >= "3"' 'requests>=2.0' 'django~=3.2' \
    'wild==1.*' 'upper<=4.0' 'bare' > "$WORK/requirements.txt"
  run --separate-stderr "$SCRIPT" "$WORK/requirements.txt"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"2.3.3","package":{"name":"flask","ecosystem":"PyPI"}},
    {"version":"1.0.0","package":{"name":"pinned","ecosystem":"PyPI"}}]' "$SHIM_BODY" >/dev/null
  [[ "$stderr" == *": 4 in "* ]]
}

@test "cve-check: requirements pin is matched to the lowercased PyPI name OSV returns" {
  make_curl_shim
  printf '%s\n' 'Django==3.2' > "$WORK/requirements.txt"
  mock_batch GHSA-dddd-django
  SHIM_BATCH="$WORK/batch.json" SHIM_VULNS_DIR="$CVE_FIX/vulns" run --separate-stderr "$SCRIPT" "$WORK/requirements.txt"
  [ "$status" -eq 0 ]
  jq -e '.queries == [{"version":"3.2","package":{"name":"Django","ecosystem":"PyPI"}}]' "$SHIM_BODY" >/dev/null
  echo "$output" | jq -e '.[0].remediation | startswith("Upgrade Django to 3.2.13 or later.")' >/dev/null
}

@test "cve-check: -r and --requirement includes of a requirements file are queried too, -c constraints are not" {
  make_curl_shim
  mkdir "$WORK/root"
  printf '%s\n' 'top==1.0.0' '-r short.txt' '-rglued.txt' '--requirement long.txt' '--requirement=longeq.txt' \
    '-r commented.txt # why' '-c constraints.txt' '--constraint=constraints2.txt' > "$WORK/root/requirements.txt"
  local f
  for f in short glued long longeq commented; do printf '%s==2.0.0\n' "$f" > "$WORK/root/$f.txt"; done
  printf '%s\n' 'constrained==9.9.9' > "$WORK/root/constraints.txt"
  printf '%s\n' 'constrained2==9.9.9' > "$WORK/root/constraints2.txt"
  WORKTREE_PATH="$WORK/root" run --separate-stderr "$SCRIPT" "$WORK/root/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = $'top@1.0.0\nshort@2.0.0\nglued@2.0.0\nlong@2.0.0\nlongeq@2.0.0\ncommented@2.0.0' ]
  [ "$(grep -c 'skipped requirements include' <<<"$stderr")" -eq 0 ]
}

@test "cve-check: a nested include resolves against the directory of the file that includes it" {
  make_curl_shim
  mkdir -p "$WORK/root/deps"
  printf '%s\n' '-r deps/dev.txt' > "$WORK/root/requirements.txt"
  printf '%s\n' 'dev==1.0.0' '-r ../base.txt' '-r local.txt' > "$WORK/root/deps/dev.txt"
  printf '%s\n' 'base==2.0.0' > "$WORK/root/base.txt"
  printf '%s\n' 'local==3.0.0' > "$WORK/root/deps/local.txt"
  printf '%s\n' 'decoy==9.9.9' > "$WORK/root/local.txt"
  WORKTREE_PATH="$WORK/root" run --separate-stderr "$SCRIPT" "$WORK/root/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = $'dev@1.0.0\nbase@2.0.0\nlocal@3.0.0' ]
}

@test "cve-check: a finding in an included file points at that file and the line of its pin" {
  make_curl_shim
  mkdir "$WORK/root"
  printf '%s\n' '-r base.txt' > "$WORK/root/requirements.txt"
  printf '%s\n' '# pins' 'flask==2.3.3' > "$WORK/root/base.txt"
  mock_advisory PyPI flask 2.3.4
  SHIM_BATCH="$WORK/batch.json" SHIM_VULNS_DIR="$WORK/records" WORKTREE_PATH="$WORK/root" \
    run --separate-stderr "$SCRIPT" "$WORK/root/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].file')" = "$WORK/root/base.txt" ]
  echo "$output" | jq -e '.[0].line == 2' >/dev/null
}

@test "cve-check: an include cycle is read once and noted" {
  make_curl_shim
  mkdir "$WORK/root"
  printf '%s\n' 'a-pkg==1.0.0' '-r requirements-b.txt' > "$WORK/root/requirements-a.txt"
  printf '%s\n' 'b-pkg==2.0.0' '-r requirements-a.txt' > "$WORK/root/requirements-b.txt"
  printf '%s\n' 'self-pkg==3.0.0' '-r requirements-self.txt' > "$WORK/root/requirements-self.txt"
  WORKTREE_PATH="$WORK/root" run --separate-stderr "$SCRIPT" "$WORK/root/requirements-a.txt"$'\n'"$WORK/root/requirements-self.txt"
  [ "$status" -eq 0 ]
  [ "$(queried_packages | sort)" = $'a-pkg@1.0.0\nb-pkg@2.0.0\nself-pkg@3.0.0' ]
  [ "$(grep -c 'skipped requirements include .*: already checked' <<<"$stderr")" -eq 2 ]
}

@test "cve-check: an include that leaves the review root through .. or an absolute path is refused with a note" {
  make_curl_shim
  mkdir -p "$WORK/root/sub"
  printf '%s\n' 'leak==9.9.9' > "$WORK/outside.txt"
  printf '%s\n' 'inside==1.0.0' > "$WORK/root/inside.txt"
  printf '%s\n' '-r inside.txt' '-r ../outside.txt' '-r sub/../../outside.txt' "-r $WORK/outside.txt" > "$WORK/root/requirements.txt"
  WORKTREE_PATH="$WORK/root" run --separate-stderr "$SCRIPT" "$WORK/root/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = "inside@1.0.0" ]
  [ "$(grep -c 'skipped requirements include .*: outside the review root' <<<"$stderr")" -eq 3 ]
}

@test "cve-check: an include that reaches outside the review root through a symlink is refused with a note" {
  make_curl_shim
  mkdir "$WORK/root"
  printf '%s\n' 'leak==9.9.9' > "$WORK/outside.txt"
  printf '%s\n' 'inside==1.0.0' > "$WORK/root/inside.txt"
  ln -s "$WORK/outside.txt" "$WORK/root/link.txt"
  ln -s "$WORK" "$WORK/root/linkdir"
  printf '%s\n' '-r inside.txt' '-r link.txt' '-r linkdir/outside.txt' > "$WORK/root/requirements.txt"
  WORKTREE_PATH="$WORK/root" run --separate-stderr "$SCRIPT" "$WORK/root/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = "inside@1.0.0" ]
  grep -q 'skipped requirements include link.txt in .*: a symlink' <<<"$stderr"
  grep -q 'skipped requirements include linkdir/outside.txt in .*: outside the review root' <<<"$stderr"
}

@test "cve-check: a missing, URL or directory include is noted without failing the check" {
  make_curl_shim
  mkdir -p "$WORK/root/subdir"
  printf '%s\n' 'top==1.0.0' '-r missing.txt' '-r https://example.invalid/r.txt' '-r subdir' > "$WORK/root/requirements.txt"
  WORKTREE_PATH="$WORK/root" run --separate-stderr "$SCRIPT" "$WORK/root/requirements.txt"
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = "top@1.0.0" ]
  [ "$(grep -c 'skipped requirements include .*: not a readable file' <<<"$stderr")" -eq 3 ]
  [ "$(grep -c 'example.invalid' "$SHIM_LOG")" -eq 0 ]
}

@test "cve-check: without WORKTREE_PATH the review root is the current directory" {
  make_curl_shim
  mkdir -p "$WORK/root/sub"
  printf '%s\n' 'leak==9.9.9' > "$WORK/outside.txt"
  printf '%s\n' 'inside==1.0.0' > "$WORK/root/sub/inside.txt"
  printf '%s\n' '-r sub/inside.txt' '-r ../outside.txt' > "$WORK/root/requirements.txt"
  cd "$WORK/root"
  WORKTREE_PATH= run --separate-stderr "$SCRIPT" requirements.txt
  [ "$status" -eq 0 ]
  [ "$(queried_packages)" = "inside@1.0.0" ]
  grep -qF 'skipped requirements include ../outside.txt in requirements.txt: outside the review root' <<<"$stderr"
}

@test "cve-check: changed lockfiles alone check the manifests beside them" {
  make_curl_shim
  mkdir "$WORK/app"
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0"}}' > "$WORK/app/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{"node_modules/lodash":{"version":"4.17.20"}}}' > "$WORK/app/package-lock.json"
  printf '%s\n' '{"require":{"guzzlehttp/guzzle":"^7.0"}}' > "$WORK/app/composer.json"
  printf '%s\n' '{"packages":[{"name":"guzzlehttp/guzzle","version":"7.8.1"}],"packages-dev":[]}' > "$WORK/app/composer.lock"
  run --separate-stderr "$SCRIPT" "$WORK/app/package-lock.json"$'\n'"$WORK/app/composer.lock"
  [ "$status" -eq 0 ]
  jq -e '.queries == [
    {"version":"4.17.20","package":{"name":"lodash","ecosystem":"npm"}},
    {"version":"7.8.1","package":{"name":"guzzlehttp/guzzle","ecosystem":"Packagist"}}]' "$SHIM_BODY" >/dev/null
}

@test "cve-check: manifest and lockfile changed together are checked once" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0"}}' > "$WORK/package.json"
  printf '%s\n' '{"lockfileVersion":3,"packages":{"node_modules/lodash":{"version":"4.17.20"}}}' > "$WORK/package-lock.json"

  run --separate-stderr "$SCRIPT" "$WORK/package.json"$'\n'"$WORK/package-lock.json"
  [ "$status" -eq 0 ]
  jq -e '.queries == [{"version":"4.17.20","package":{"name":"lodash","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null

  cd "$WORK"
  run --separate-stderr "$SCRIPT" $'package-lock.json\npackage.json'
  [ "$status" -eq 0 ]
  jq -e '.queries == [{"version":"4.17.20","package":{"name":"lodash","ecosystem":"npm"}}]' "$SHIM_BODY" >/dev/null
}

@test "cve-check: unparseable lockfile is exit 1 with empty array and no OSV request" {
  make_curl_shim
  printf '%s\n' '{"dependencies":{"lodash":"^4.17.0"}}' > "$WORK/package.json"
  printf '%s\n' '{not json' > "$WORK/package-lock.json"
  run --separate-stderr "$SCRIPT" "$WORK/package.json"
  [ "$status" -eq 1 ]
  [ "$output" = "[]" ]
  [ ! -e "$SHIM_LOG" ]
}

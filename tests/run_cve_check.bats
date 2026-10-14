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

# curl stand-in on PATH. Logs "<method> <url>" to $SHIM_LOG, saves the last POST body to
# $SHIM_BODY, answers POST from $SHIM_BATCH (default: no vulnerabilities) and GET .../<id>
# from $SHIM_VULNS_DIR/<id>.json (exit 22 when missing, like --fail-with-body on a 404).
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

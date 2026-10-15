#!/usr/bin/env bats
# Tests for the shipped argument parser and roster overlay scripts.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  PROFILE_SCRIPT="${SCRIPTS_DIR}/resolve-profile.sh"
  OVERLAY_SCRIPT="${SCRIPTS_DIR}/apply-roster-overlays.sh"
  GATES_SCRIPT="${SCRIPTS_DIR}/evaluate-gates.sh"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

source_profile() {
  eval "$(bash "$PROFILE_SCRIPT" "$@")"
}

@test "resolve-profile: no args defaults to full roster" {
  source_profile
  [[ "$PROFILE" == "full" ]]
  [[ "$RUN_PR_SUMMARIZER" == "true" ]]
  [[ "$RUN_CODE_REVIEWER" == "true" ]]
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "true" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "true" ]]
  [[ "$RUN_BLIND_HUNTER" == "true" ]]
  [[ "$RUN_EDGE_CASE_HUNTER" == "true" ]]
  [[ "$RUN_ADVERSARIAL_GENERAL" == "true" ]]
  [[ "$RUN_ISSUE_LINKER" == "true" ]]
  [[ "$RUN_CVE" == "true" ]]
  [[ "$EXTENDED_THINKING" == "false" ]]
  [[ "$CVE_REACHABILITY" == "false" ]]
  [[ "$RUN_ENRICH_CONTEXT" == "true" ]]
}

@test "resolve-profile: --profile quick skips specialists" {
  source_profile --profile quick
  [[ "$PROFILE" == "quick" ]]
  [[ "$RUN_PR_SUMMARIZER" == "true" ]]
  [[ "$RUN_CODE_REVIEWER" == "true" ]]
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "false" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "false" ]]
  [[ "$RUN_BLIND_HUNTER" == "false" ]]
  [[ "$RUN_SILENT_FAILURE_HUNTER" == "conditional" ]]
  [[ "$RUN_CVE" == "true" ]]
  [[ "$RUN_ENRICH_CONTEXT" == "false" ]]
}

@test "resolve-profile: --profile security is security-reviewer plus CVE" {
  source_profile --profile security
  [[ "$PROFILE" == "security" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "true" ]]
  [[ "$RUN_CVE" == "true" ]]
  [[ "$RUN_STATIC_ANALYZERS" == "true" ]]
  [[ "$RUN_PR_SUMMARIZER" == "false" ]]
  [[ "$RUN_CODE_REVIEWER" == "false" ]]
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "false" ]]
  [[ "$RUN_ENRICH_CONTEXT" == "false" ]]
}

@test "resolve-profile: --profile deep enables extended thinking and CVE reachability" {
  source_profile --profile deep
  [[ "$PROFILE" == "deep" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "true" ]]
  [[ "$RUN_BLIND_HUNTER" == "true" ]]
  [[ "$EXTENDED_THINKING" == "true" ]]
  [[ "$CVE_REACHABILITY" == "true" ]]
  [[ "$RUN_ENRICH_CONTEXT" == "true" ]]
}

@test "resolve-profile: --summary-only is summarizer only" {
  source_profile --summary-only
  [[ "$PROFILE" == "summary" ]]
  [[ "$SUMMARY_ONLY" == "true" ]]
  [[ "$RUN_PR_SUMMARIZER" == "true" ]]
  [[ "$RUN_CODE_REVIEWER" == "false" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "false" ]]
  [[ "$RUN_CVE" == "false" ]]
  [[ "$RUN_STATIC_ANALYZERS" == "false" ]]
}

@test "resolve-profile: --summary-only and --profile conflict" {
  run -2 bash "$PROFILE_SCRIPT" --summary-only --profile full
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "resolve-profile: rejects removed --quick" {
  run -2 bash "$PROFILE_SCRIPT" --quick
  [[ "$output" == *"--profile quick"* ]]
}

@test "resolve-profile: rejects removed --security-only" {
  run -2 bash "$PROFILE_SCRIPT" --security-only
  [[ "$output" == *"--profile security"* ]]
}

@test "resolve-profile: rejects removed --depth" {
  run -2 bash "$PROFILE_SCRIPT" --depth deep
  [[ "$output" == *"--profile deep"* ]]
}

@test "resolve-profile: rejects removed posting flags" {
  run -2 bash "$PROFILE_SCRIPT" --post-findings
  [[ "$output" == *"local-only"* ]]
  run -2 bash "$PROFILE_SCRIPT" --create-pr
  [[ "$output" == *"local-only"* ]]
  run -2 bash "$PROFILE_SCRIPT" --no-post
  [[ "$output" == *"removed"* ]]
  run -2 bash "$PROFILE_SCRIPT" --local
  [[ "$output" == *"removed"* ]]
  run -2 bash "$PROFILE_SCRIPT" --publish
  [[ "$output" == *"local-only"* ]]
  run -2 bash "$PROFILE_SCRIPT" --read-back
  [[ "$output" == *"local-only"* ]]
}

@test "resolve-profile: rejects unknown profile and unknown flag" {
  run -2 bash "$PROFILE_SCRIPT" --profile turbo
  [[ "$output" == *"Invalid --profile"* ]]
  run -2 bash "$PROFILE_SCRIPT" --wat
  [[ "$output" == *"Unknown flag"* ]]
}

@test "resolve-profile: rejects removed --pr and --provider with a URL hint" {
  run -2 bash "$PROFILE_SCRIPT" --pr 42
  [[ "$output" == *"PR/MR URL"* ]]
  run -2 bash "$PROFILE_SCRIPT" --pr=42
  [[ "$output" == *"PR/MR URL"* ]]
  run -2 bash "$PROFILE_SCRIPT" --provider gitlab
  [[ "$output" == *"PR/MR URL"* ]]
  run -2 bash "$PROFILE_SCRIPT" --provider=github
  [[ "$output" == *"PR/MR URL"* ]]
}

@test "resolve-profile: --from-file tokenizes without executing the file" {
  printf '%s\n' '$(echo pwned) --profile quick' > "$WORK/args"
  eval "$(bash "$PROFILE_SCRIPT" --from-file "$WORK/args")"
  [[ "$PROFILE" == "quick" ]]
  [[ "$GUIDANCE" == '$(echo pwned)' ]]
}

@test "resolve-profile: --from-file keeps quoted values whole and expands nothing" {
  cat > "$WORK/args" <<'EOF'
--output-file "review report.md" $(echo pwned) `id` * "a 'b' c"
EOF
  cd "$WORK"
  _out=$(bash "$PROFILE_SCRIPT" --from-file args)
  eval "$_out"
  [[ "$OUTPUT_FILE" == "review report.md" ]]
  [[ "$GUIDANCE" == "\$(echo pwned) \`id\` * a 'b' c" ]]
  printf '%s\n' '--output-file="review report.md" --base='"'"'release/x y'"'"' focus' > "$WORK/args"
  _out=$(bash "$PROFILE_SCRIPT" --from-file "$WORK/args")
  eval "$_out"
  [[ "$OUTPUT_FILE" == "review report.md" ]]
  [[ "$BASE" == "release/x y" ]]
  [[ "$GUIDANCE" == "focus" ]]
}

@test "resolve-profile: --from-file decodes \\\" and \\\\ inside double quotes only" {
  printf '%s\n' '--output-file "Bob'"'"'s \"review report\".md" focus "a\\b" "C:\temp" '"'"'x\"y'"'"'' > "$WORK/args"
  _out=$(bash "$PROFILE_SCRIPT" --from-file "$WORK/args")
  eval "$_out"
  [[ "$OUTPUT_FILE" == 'Bob'"'"'s "review report".md' ]]
  [[ "$GUIDANCE" == 'focus a\b C:\temp x\"y' ]]
}

@test "resolve-profile: --from-file keeps stray quotes literal" {
  printf '%s\n' "--profile quick focus on the user's session" > "$WORK/args"
  _out=$(bash "$PROFILE_SCRIPT" --from-file "$WORK/args")
  eval "$_out"
  [[ "$PROFILE" == "quick" ]]
  [[ "$GUIDANCE" == "focus on the user's session" ]]
  printf '%s\n' "'unterminated focus --profile quick" > "$WORK/args"
  _out=$(bash "$PROFILE_SCRIPT" --from-file "$WORK/args")
  eval "$_out"
  [[ "$PROFILE" == "quick" ]]
  [[ "$GUIDANCE" == "'unterminated focus" ]]
}

@test "resolve-profile: empty --from-file is the default full profile" {
  : > "$WORK/args"
  _out=$(bash "$PROFILE_SCRIPT" --from-file "$WORK/args")
  eval "$_out"
  [[ "$PROFILE" == "full" ]]
  [[ -z "$GUIDANCE" ]]
}

@test "resolve-profile: empty inline flag values are rejected" {
  run -2 bash "$PROFILE_SCRIPT" --profile=
  [[ "$output" == *"--profile requires a value"* ]]
  run -2 bash "$PROFILE_SCRIPT" --base=
  run -2 bash "$PROFILE_SCRIPT" --output-file=
}

@test "resolve-profile: --base and --min-confidence still parse" {
  source_profile --profile full --base develop --min-confidence 80
  [[ "$BASE" == "develop" ]]
  [[ "$MIN_CONFIDENCE" == "80" ]]
}

@test "resolve-profile: GUIDANCE strips URL userinfo" {
  eval "$(bash "$PROFILE_SCRIPT" "https://oauth2:s3cret-token@github.com/acme/app/pull/42" focus)"
  [[ "$GUIDANCE" != *s3cret-token* ]]
  [[ "$GUIDANCE" == *"github.com/acme/app/pull/42"* ]]
  [[ "$GUIDANCE" == *focus* ]]
}

@test "resolve-profile: free-form leftover is GUIDANCE and does not change the roster" {
  source_profile review https://gitlab.example/group/proj/-/merge_requests/7 focus on auth
  [[ "$PROFILE" == "full" ]]
  [[ "$GUIDANCE" == "review https://gitlab.example/group/proj/-/merge_requests/7 focus on auth" ]]
  [[ "$RUN_CODE_REVIEWER" == "true" ]]
}

@test "resolve-profile: flags then prose keep the flags and collect GUIDANCE" {
  source_profile --profile quick focus on tokens
  [[ "$PROFILE" == "quick" ]]
  [[ "$GUIDANCE" == "focus on tokens" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "false" ]]
}

@test "resolve-profile: -- sends the rest to GUIDANCE" {
  source_profile --profile security -- review this
  [[ "$PROFILE" == "security" ]]
  [[ "$GUIDANCE" == "review this" ]]
}

@test "resolve-profile: empty GUIDANCE when only flags are passed" {
  source_profile --profile full
  [[ -z "$GUIDANCE" ]]
}

@test "resolve-profile: invalid --min-confidence is rejected" {
  run -2 bash "$PROFILE_SCRIPT" --min-confidence 140
  [[ "$output" == *"min-confidence"* ]]
}

@test "resolve-profile: --min-confidence with leading zeros is decimal" {
  _out=$(bash "$PROFILE_SCRIPT" --min-confidence 08)
  eval "$_out"
  [[ "$MIN_CONFIDENCE" == "8" ]]
  run -2 bash "$PROFILE_SCRIPT" --min-confidence 0144
}

@test "overlay: TIER=tiny skips hunters unless architecture/security promoted" {
  eval "$(TIER=tiny ARCH_PROMOTED=false SECURITY_PROMOTED=false \
    bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_BLIND_HUNTER" == "false" ]]
  [[ "$RUN_EDGE_CASE_HUNTER" == "false" ]]
  [[ "$RUN_ADVERSARIAL_GENERAL" == "false" ]]
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "false" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "false" ]]
  [[ "$RUN_CODE_REVIEWER" == "true" ]]
  [[ "$RUN_ENRICH_CONTEXT" == "false" ]]
}

@test "overlay: TIER=tiny promotes security-reviewer when SECURITY_PROMOTED" {
  eval "$(TIER=tiny SECURITY_PROMOTED=true \
    bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_SECURITY_REVIEWER" == "true" ]]
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "false" ]]
}

@test "overlay: security profile keeps security-reviewer at TIER=tiny" {
  eval "$(TIER=tiny SECURITY_PROMOTED=false \
    bash "$OVERLAY_SCRIPT" --profile security)"
  [[ "$RUN_SECURITY_REVIEWER" == "true" ]]
}

@test "overlay: DOCS_ONLY only cheapens full profile, not deep" {
  eval "$(DOCS_ONLY=true bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "false" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "false" ]]
  eval "$(DOCS_ONLY=true bash "$OVERLAY_SCRIPT" --profile deep)"
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "true" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "true" ]]
  [[ "$EXTENDED_THINKING" == "true" ]]
}

@test "overlay: issue-linker skipped on GitLab" {
  eval "$(PROVIDER=gitlab bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_ISSUE_LINKER" == "false" ]]
  eval "$(PROVIDER=github bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_ISSUE_LINKER" == "true" ]]
}

@test "overlay: GATE_CONTROL_FLOW=false skips edge-case-hunter" {
  eval "$(GATE_CONTROL_FLOW=false bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_EDGE_CASE_HUNTER" == "false" ]]
}

@test "overlay: no-args without exported roster still emits full" {
  eval "$(bash "$PROFILE_SCRIPT")"
  # PROFILE is set in this shell only — the child must re-parse.
  run bash "$OVERLAY_SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^PROFILE=full$'
  echo "$output" | grep -q '^RUN_PR_SUMMARIZER=true$'
}

@test "overlay: removed flag exits non-zero and does not emit a stale roster" {
  eval "$(bash "$PROFILE_SCRIPT" --profile full)"
  export PROFILE RUN_PR_SUMMARIZER RUN_CODE_REVIEWER RUN_ARCHITECTURE_REVIEWER \
    RUN_SECURITY_REVIEWER RUN_BLIND_HUNTER RUN_EDGE_CASE_HUNTER \
    RUN_ADVERSARIAL_GENERAL RUN_ISSUE_LINKER RUN_SILENT_FAILURE_HUNTER \
    RUN_PR_TEST_ANALYZER RUN_COMMENT_ANALYZER RUN_TYPE_DESIGN_ANALYZER \
    RUN_CVE RUN_STATIC_ANALYZERS EXTENDED_THINKING CVE_REACHABILITY \
    RUN_ENRICH_CONTEXT
  run bash "$OVERLAY_SCRIPT" --quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"flag '--quick' was removed"* ]]
  if echo "$output" | grep -q '^RUN_PR_SUMMARIZER=true$'; then
    echo "REGRESSION: overlay reprinted a roster after a failed parse" >&2
    return 1
  fi
}

@test "overlay: --from-file does not emit GUIDANCE (preserves GUIDANCE_REST)" {
  printf '%s\n' '--profile full https://github.com/acme/app/pull/42 focus on auth' > "$WORK/invoke"
  GUIDANCE="focus on auth"
  out=$(bash "$OVERLAY_SCRIPT" --from-file "$WORK/invoke")
  if echo "$out" | grep -q '^GUIDANCE='; then
    echo "REGRESSION: overlay re-emits GUIDANCE and would restore the PR/MR URL" >&2
    echo "$out" | grep '^GUIDANCE=' >&2
    return 1
  fi
  eval "$out"
  [[ "$GUIDANCE" == "focus on auth" ]]
}

@test "overlay: LOW_RISK_CONFIG does not skip architecture when ARCH_PROMOTED" {
  eval "$(DOCS_ONLY=false LOW_RISK_CONFIG=true ARCH_PROMOTED=true \
    bash "$OVERLAY_SCRIPT" --profile full)"
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "true" ]]
}

@test "overlay: SKIP_REASONS names only scheduled agents, once each" {
  _out=$(TIER=tiny bash "$OVERLAY_SCRIPT" --profile quick)
  eval "$_out"
  [[ -z "$SKIP_REASONS" ]]
  _out=$(TIER=tiny DOCS_ONLY=true bash "$OVERLAY_SCRIPT" --profile full)
  eval "$_out"
  [[ "$SKIP_REASONS" == *"blind-hunter (DOCS_ONLY)"* ]]
  [[ "$SKIP_REASONS" != *"TIER=tiny"* ]]
}

# bash 3.2 ignores a failing mid-test [[ ]]; a failing function call still aborts the test.
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

@test "overlay: silent-failure-hunter is true or false from GATE_ERROR_PATTERNS, never conditional" {
  eval "$(GATE_ERROR_PATTERNS=true bash "$OVERLAY_SCRIPT" --profile full)"
  [ "$RUN_SILENT_FAILURE_HUNTER" = "true" ]
  [ -z "$SKIP_REASONS" ]
  eval "$(GATE_ERROR_PATTERNS=false bash "$OVERLAY_SCRIPT" --profile full)"
  [ "$RUN_SILENT_FAILURE_HUNTER" = "false" ]
  [ "$SKIP_REASONS" = "silent-failure-hunter (GATE_ERROR_PATTERNS=false)" ]
}

@test "overlay: pr-test-analyzer is true or false from GATE_TEST_PATHS, never conditional" {
  eval "$(GATE_TEST_PATHS=true bash "$OVERLAY_SCRIPT" --profile quick)"
  [ "$RUN_PR_TEST_ANALYZER" = "true" ]
  [ -z "$SKIP_REASONS" ]
  eval "$(GATE_TEST_PATHS=false bash "$OVERLAY_SCRIPT" --profile quick)"
  [ "$RUN_PR_TEST_ANALYZER" = "false" ]
  [ "$SKIP_REASONS" = "pr-test-analyzer (GATE_TEST_PATHS=false)" ]
}

@test "overlay: comment-analyzer is true or false from GATE_COMMENT_CHANGES, never conditional" {
  eval "$(GATE_COMMENT_CHANGES=true bash "$OVERLAY_SCRIPT" --profile full)"
  [ "$RUN_COMMENT_ANALYZER" = "true" ]
  [ -z "$SKIP_REASONS" ]
  eval "$(GATE_COMMENT_CHANGES=false bash "$OVERLAY_SCRIPT" --profile full)"
  [ "$RUN_COMMENT_ANALYZER" = "false" ]
  [ "$SKIP_REASONS" = "comment-analyzer (GATE_COMMENT_CHANGES=false)" ]
}

@test "overlay: type-design-analyzer is true or false from GATE_TYPE_DEFINITIONS, never conditional" {
  eval "$(GATE_TYPE_DEFINITIONS=true bash "$OVERLAY_SCRIPT" --profile deep)"
  [ "$RUN_TYPE_DESIGN_ANALYZER" = "true" ]
  [ -z "$SKIP_REASONS" ]
  eval "$(GATE_TYPE_DEFINITIONS=false bash "$OVERLAY_SCRIPT" --profile deep)"
  [ "$RUN_TYPE_DESIGN_ANALYZER" = "false" ]
  [ "$SKIP_REASONS" = "type-design-analyzer (GATE_TYPE_DEFINITIONS=false)" ]
}

@test "overlay: a true gate does not schedule a conditional agent the profile leaves off" {
  eval "$(GATE_COMMENT_CHANGES=true GATE_TYPE_DEFINITIONS=true GATE_ERROR_PATTERNS=true \
    bash "$OVERLAY_SCRIPT" --profile quick)"
  [ "$RUN_COMMENT_ANALYZER" = "false" ]
  [ "$RUN_TYPE_DESIGN_ANALYZER" = "false" ]
  [ "$RUN_SILENT_FAILURE_HUNTER" = "true" ]
}

@test "overlay: no profile or gate setting leaves a conditional agent as conditional" {
  for profile in quick security full deep; do
    for gates in true false unset; do
      unset GATE_ERROR_PATTERNS GATE_TEST_PATHS GATE_COMMENT_CHANGES GATE_TYPE_DEFINITIONS
      if [[ "$gates" != "unset" ]]; then
        export GATE_ERROR_PATTERNS="$gates" GATE_TEST_PATHS="$gates" \
          GATE_COMMENT_CHANGES="$gates" GATE_TYPE_DEFINITIONS="$gates"
      fi
      _out=$(bash "$OVERLAY_SCRIPT" --profile "$profile")
      if echo "$_out" | grep -q '=conditional$'; then
        echo "REGRESSION: conditional left for --profile $profile with gates $gates" >&2
        return 1
      fi
    done
  done
}

@test "overlay: a gate adds no second reason for an agent an earlier overlay skipped" {
  eval "$(TIER=tiny GATE_TEST_PATHS=false GATE_COMMENT_CHANGES=false GATE_TYPE_DEFINITIONS=false \
    bash "$OVERLAY_SCRIPT" --profile full)"
  contains "$SKIP_REASONS" "comment-analyzer (TIER=tiny)"
  contains "$SKIP_REASONS" "type-design-analyzer (TIER=tiny)"
  lacks "$SKIP_REASONS" "GATE_COMMENT_CHANGES"
  lacks "$SKIP_REASONS" "GATE_TYPE_DEFINITIONS"
  contains "$SKIP_REASONS" "pr-test-analyzer (GATE_TEST_PATHS=false)"
}

# Run evaluate-gates.sh on a diff and feed its GATE_* output to the overlay.
overlay_for_diff() {
  local diff_content="$1" diff_paths="$2" profile="$3"
  printf '%s\n' "$diff_content" > "$WORK/gate.diff"
  _gates=$(DIFF_FILE="$WORK/gate.diff" DIFF_PATHS="$diff_paths" bash "$GATES_SCRIPT")
  eval "$_gates"
  export GATE_ERROR_PATTERNS GATE_CONTROL_FLOW GATE_TEST_PATHS GATE_COMMENT_CHANGES GATE_TYPE_DEFINITIONS
  _out=$(bash "$OVERLAY_SCRIPT" --profile "$profile")
  eval "$_out"
}

@test "gates + overlay: a diff that trips every trigger schedules all four conditional agents" {
  overlay_for_diff $'+// Reader reads.\n+type Reader interface {\n+  if err != nil { return err }' \
    $'pkg/reader.go\npkg/reader_test.go' full
  [ "$RUN_SILENT_FAILURE_HUNTER" = "true" ]
  [ "$RUN_PR_TEST_ANALYZER" = "true" ]
  [ "$RUN_COMMENT_ANALYZER" = "true" ]
  [ "$RUN_TYPE_DESIGN_ANALYZER" = "true" ]
  [ -z "$SKIP_REASONS" ]
}

@test "gates + overlay: a diff that trips no trigger skips the conditional agents and says why" {
  overlay_for_diff "+total := 1" "pkg/reader.go" full
  [ "$RUN_SILENT_FAILURE_HUNTER" = "false" ]
  [ "$RUN_PR_TEST_ANALYZER" = "false" ]
  [ "$RUN_COMMENT_ANALYZER" = "false" ]
  [ "$RUN_TYPE_DESIGN_ANALYZER" = "false" ]
  contains "$SKIP_REASONS" "silent-failure-hunter (GATE_ERROR_PATTERNS=false)"
  contains "$SKIP_REASONS" "pr-test-analyzer (GATE_TEST_PATHS=false)"
  contains "$SKIP_REASONS" "comment-analyzer (GATE_COMMENT_CHANGES=false)"
  contains "$SKIP_REASONS" "type-design-analyzer (GATE_TYPE_DEFINITIONS=false)"
}

@test "gates + overlay: a quick review resolves silent-failure-hunter and pr-test-analyzer from the diff" {
  overlay_for_diff $'+  } catch (Exception e) {\n+  throw e;' $'src/Service.java\nsrc/ServiceTest.java' quick
  [ "$RUN_SILENT_FAILURE_HUNTER" = "true" ]
  [ "$RUN_PR_TEST_ANALYZER" = "true" ]
  [ "$RUN_COMMENT_ANALYZER" = "false" ]
  overlay_for_diff "+total := 1" "src/Service.java" quick
  [ "$RUN_SILENT_FAILURE_HUNTER" = "false" ]
  [ "$RUN_PR_TEST_ANALYZER" = "false" ]
}

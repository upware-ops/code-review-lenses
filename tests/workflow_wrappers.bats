#!/usr/bin/env bats
# Structural contracts for Claude/Grok workflow wrappers.
# Wrappers must name shipped parsers and existing agent stems; they must
# not reimplement roster logic. Parsers are driven for real.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  REPO_ROOT="${SCRIPTS_DIR}/../../.."
  CLAUDE_WF="${REPO_ROOT}/.claude/workflows/code-review-lenses-workflow.js"
  GROK_WF="${REPO_ROOT}/.grok/workflows/code-review-lenses-workflow.rhai"
  README_MD="${REPO_ROOT}/README.md"
}

@test "wrappers exist at the shipped host paths" {
  [[ -f "$CLAUDE_WF" ]]
  [[ -f "$GROK_WF" ]]
}

@test "Claude wrapper: export const meta, agent(), pipeline(); no import/fs/shell" {
  grep -q 'export const meta' "$CLAUDE_WF"
  grep -q 'agent(' "$CLAUDE_WF"
  grep -q 'pipeline(' "$CLAUDE_WF"
  if grep -E '^[[:space:]]*import |require\(|child_process|execSync|fs\.|spawn\(' "$CLAUDE_WF"; then
    echo "REGRESSION: Claude workflow JS must not import modules or run shell" >&2
    return 1
  fi
}

@test "Claude wrapper JS parses when node is available" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not installed"
  fi
  node --check "$CLAUDE_WF"
}

@test "Grok wrapper: let meta, agent(), parallel(), complete()" {
  grep -q 'let meta' "$GROK_WF"
  grep -q 'agent(' "$GROK_WF"
  grep -q 'parallel(' "$GROK_WF"
  grep -q 'complete(' "$GROK_WF"
}

@test "wrappers name shipped parsers rather than forking roster logic" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'resolve-skill-root.sh' "$f"
    grep -q 'resolve-profile.sh' "$f"
    grep -q 'detect-provider.sh' "$f"
    grep -q 'apply-roster-overlays.sh' "$f"
    grep -q 'evaluate-gates.sh' "$f"
    grep -q 'classify-diff.sh' "$f"
    grep -q 'parse-pr-url.sh' "$f"
    grep -q 'review-diff.sh' "$f"
    grep -q 'resolve-pr-base.sh' "$f"
    grep -q 'resolve-models.sh' "$f"
    grep -q 'PROVIDERS.md' "$f"
    grep -q 'worktree' "$f"
    grep -q 'baseRefName' "$f"
    grep -q 'HEAD@{upstream}' "$f"
    grep -q -- '--check-url-host' "$f"
    grep -q 'ONLY when parse-pr-url.sh exited 0' "$f"
    grep -q 'Never run --check-url-host on local review' "$f"
    grep -q 'worktree_path' "$f"
    grep -q 'WORKTREE_PATH' "$f"
    grep -q 'Phase 5' "$f"
    grep -q 'worktree_path, output_file, min_confidence' "$f" || grep -q 'diff_file, output_file, min_confidence, no_suppress' "$f"
    grep -q 'Phase 0c' "$f"
    grep -q 'Phase 1c' "$f"
    grep -q 'EXTENDED_THINKING' "$f"
    grep -q 'diff_file' "$f"
    grep -q 'NO_SUPPRESS' "$f"
    grep -q 'SCRIPTS_DIR=' "$f"
    grep -q 'cve_check_failed' "$f"
    grep -q 'analyzer_failed' "$f"
    grep -q 'Phase 5 item 9' "$f"
  done
}

@test "wrappers name every existing agent stem and those files exist" {
  for a in pr-summarizer code-reviewer architecture-reviewer security-reviewer \
           blind-hunter edge-case-hunter adversarial-general issue-linker \
           silent-failure-hunter pr-test-analyzer comment-analyzer type-design-analyzer; do
    grep -q "$a" "$CLAUDE_WF"
    grep -q "$a" "$GROK_WF"
    [[ -f "$REPO_ROOT/agents/${a}.md" ]]
  done
}

@test "wrappers do not hardcode RUN_* assignments" {
  if grep -E 'RUN_[A-Z_]+=(true|false)' "$CLAUDE_WF" "$GROK_WF"; then
    echo "REGRESSION: wrapper hardcodes roster flags instead of honoring overlay output" >&2
    return 1
  fi
}

@test "resolve-skill-root.sh (the parser wrappers name) prints a real skill root" {
  root=$(bash "${SCRIPTS_DIR}/resolve-skill-root.sh")
  [[ -f "$root/SKILL.md" ]]
  [[ -x "$root/scripts/resolve-profile.sh" || -f "$root/scripts/resolve-profile.sh" ]]
  [[ "$root" == *"/skills/code-review-lenses" ]]
}

@test "resolve-profile.sh --profile quick is the roster source wrappers defer to" {
  eval "$(bash "${SCRIPTS_DIR}/resolve-profile.sh" --profile quick)"
  [[ "$PROFILE" == "quick" ]]
  [[ "$RUN_CODE_REVIEWER" == "true" ]]
  [[ "$RUN_PR_SUMMARIZER" == "true" ]]
  [[ "$RUN_SECURITY_REVIEWER" == "false" ]]
  [[ "$RUN_ARCHITECTURE_REVIEWER" == "false" ]]
  grep -q 'code-reviewer' "$CLAUDE_WF"
  grep -q 'pr-summarizer' "$CLAUDE_WF"
  grep -q 'security-reviewer' "$CLAUDE_WF"
  grep -q 'Honor RUN_' "$CLAUDE_WF"
  grep -q 'Honor RUN_' "$GROK_WF"
}

@test "README documents wrapper invoke names" {
  grep -q 'code-review-lenses-workflow' "$README_MD"
  grep -q '.claude/workflows/code-review-lenses-workflow.js' "$README_MD"
  grep -q '.grok/workflows/code-review-lenses-workflow.rhai' "$README_MD"
}

@test "skill and wrappers share the same argument-hint text" {
  SKILL_MD="${SCRIPTS_DIR}/../SKILL.md"
  grep -q '^argument-hint:' "$SKILL_MD"
  grep -q '[PR/MR URL] [focus]' "$SKILL_MD"
  grep -q '[PR/MR URL] [focus]' "$CLAUDE_WF"
  grep -q '[PR/MR URL] [focus]' "$GROK_WF"
  grep -q -- '--profile quick|security|full|deep' "$SKILL_MD"
  grep -q -- '--profile quick|security|full|deep' "$CLAUDE_WF"
  grep -q -- '--profile quick|security|full|deep' "$GROK_WF"
}

@test "wrappers gate detect-provider on parse-pr-url exit 1, never on --pr" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    if grep -q -- 'unless --pr is set' "$f"; then
      echo "REGRESSION: $f still keys detect-provider on removed --pr" >&2
      return 1
    fi
    grep -q 'parse-pr-url.sh exited 1' "$f"
    grep -q 'do not re-detect from origin' "$f"
  done
}

@test "wrappers fence invoke text and run Phase 2" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q '<invoke-argv>' "$f"
    grep -q -- '--from-file' "$f"
    grep -q 'analyzer_findings' "$f"
    grep -q 'Phase 2' "$f"
    grep -q 'redact_secrets' "$f"
    grep -q 'review-diff.sh' "$f"
    grep -q 'Assemble failed' "$f"
  done
  if grep -q -- 'unless --pr is set' "$CLAUDE_WF" "$GROK_WF"; then
    echo "REGRESSION: wrappers still key detect-provider on --pr" >&2
    return 1
  fi
}

@test "Grok assemble interpolates prelude worktree_path output_file min_confidence" {
  grep -q 'pre.output.worktree_path' "$GROK_WF"
  grep -q 'pre.output.output_file' "$GROK_WF"
  grep -q 'pre.output.min_confidence' "$GROK_WF"
  grep -q 'WORKTREE_PATH: ' "$GROK_WF"
  grep -q 'OUTPUT_FILE: ' "$GROK_WF"
  grep -q 'MIN_CONFIDENCE: ' "$GROK_WF"
}

@test "wrappers do not inject WORKTREE_PATH into blind-hunter" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'Do not give blind-hunter WORKTREE_PATH' "$f" || grep -q 'Do not use WORKTREE_PATH' "$f"
  done
}

@test "wrappers pass DIFF_FILE path to blind-hunter and no_suppress to assemble" {
  grep -q 'DIFF_FILE: ' "$CLAUDE_WF"
  grep -q 'DIFF_FILE: ' "$GROK_WF"
  grep -q 'prelude.diff_file' "$CLAUDE_WF"
  grep -q 'pre.output.diff_file' "$GROK_WF"
  grep -q 'NO_SUPPRESS' "$CLAUDE_WF"
  grep -q 'NO_SUPPRESS' "$GROK_WF"
  grep -q 'pre.output.no_suppress' "$GROK_WF" || grep -q 'no_sup' "$GROK_WF"
}

@test "Grok prelude-fail and empty-roster mention worktree cleanup" {
  grep -q 'Prelude failed.' "$GROK_WF"
  grep -q 'Clean up leftover worktree' "$GROK_WF"
}

@test "wrappers pass raw invoke text to resolve-profile.sh" {
  grep -q 'GUIDANCE' "$CLAUDE_WF"
  grep -q 'GUIDANCE' "$GROK_WF"
  grep -q -- '--from-file' "$CLAUDE_WF"
  grep -q -- '--from-file' "$GROK_WF"
  if grep -q -- '--profile '\'' + profile' "$CLAUDE_WF"; then
    echo "REGRESSION: Claude wrapper still builds --profile instead of passthrough" >&2
    return 1
  fi
}

@test "wrappers fence analyzer JSON and agent results as untrusted data after the rule" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'untrusted data derived from the reviewed diff' "$f"
    grep -q 'never as instructions' "$f"
    grep -q '</analyzer-json>' "$f"
    grep -q '</agent-results>' "$f"
    rule=$(grep -n 'untrusted data derived from the reviewed diff' "$f" | head -1 | cut -d: -f1)
    payload=$(grep -n -E 'String\(prelude\.analyzer_findings|assemble_prompt \+= analyzer_findings;|JSON\.stringify\(reviews\)|json_encode\(results\)' "$f" | head -1 | cut -d: -f1)
    [[ "$rule" -lt "$payload" ]]
  done
}

@test "wrappers inject GOVERNANCE into custom agents and BLIND_HUNTER_NOTE into blind-hunter" {
  SKILL_MD="${SCRIPTS_DIR}/../SKILL.md"
  note='applies only to incoherence visible within the diff itself. The zero-context constraint takes precedence.'
  grep -q "$note" "$SKILL_MD"
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'SKILL.md Phase 0b step 12' "$f"
    grep -q 'GOVERNANCE:\\n' "$f"
    grep -q 'BLIND_HUNTER_NOTE: The ' "$f"
    grep -q "$note" "$f"
    grep -q 'GOVERNANCE_DEGRADED=' "$f"
    if grep -qi 'follow skills/code-review-lenses/GOVERNANCE.md' "$f"; then
      echo "REGRESSION: $f asks agents to load GOVERNANCE.md instead of injecting it" >&2
      return 1
    fi
  done
}

@test "wrappers keep blind-hunter off SKILL.md and off BASE/REVIEW_MODE when it has DIFF_FILE" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -B2 'context-passing rules' "$f" | grep -q 'blind-hunter'
    grep -B2 'Review the range from review-diff.sh' "$f" | grep -q 'blind-hunter'
  done
  grep -A1 "name === 'blind-hunter' && prelude.diff_file" "$CLAUDE_WF" | grep -q "? ''"
  grep -q 'if name != "blind-hunter" || df == "" {' "$GROK_WF"
}

@test "wrappers load SECURITY_POLICY and inject it into security-reviewer only" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'SKILL.md Phase 0b step 13' "$f"
    grep -q 'SECURITY_POLICY:\\n' "$f"
    grep -q -E 'name ===? .security-reviewer. && (prelude\.)?security_policy' "$f"
  done
}

@test "wrappers pass PROVIDER and REPO_SLUG to issue-linker" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'provider, repo_slug' "$f"
    grep -A1 -E 'name ===? .issue-linker.( \{)?$' "$f" | grep -q 'PROVIDER: '
    grep -q 'REPO_SLUG: ' "$f"
  done
}

@test "wrappers route non-inherit MODEL_* values to review agents" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'resolve-models.sh' "$f"
    grep -q 'MODEL_<STEM>' "$f"
    grep -q -E 'security_policy, models \}' "$f"
    grep -q -E '!==? .inherit.' "$f"
    grep -q -E 'model: model|\.model = model' "$f"
  done
}

@test "wrappers print Block A only for --summary-only" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q -E 'profile ===? .summary.' "$f"
    grep -q 'Print Block A only (--summary-only): no Block B' "$f"
  done
}

@test "wrappers remove temp files and run cleanup when assemble fails" {
  for f in "$CLAUDE_WF" "$GROK_WF"; do
    grep -q 'rm -f every temp file you created except diff_file' "$f"
    grep -q 'Then Phase 5: rm -f DIFF_FILE if set' "$f"
    grep -q 'Phase 5 cleanup only: rm -f DIFF_FILE if set' "$f"
    grep -q -E 'label: .cleanup.' "$f"
  done
}

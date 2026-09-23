#!/usr/bin/env bats
# Structural contracts for the orchestrator after the host-agnostic reshape.
#
# Roster/flag/provider behavior is tested against the shipped scripts in
# resolve_profile.bats and detect_provider.bats. This file guards the
# documents and the "no posting / no Claude plugin" invariants.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  WORK=$(mktemp -d)
  SKILL_MD="${SCRIPTS_DIR}/../SKILL.md"
  SEVERITY_MD="${SCRIPTS_DIR}/../SEVERITY.md"
  PROVIDERS_MD="${SCRIPTS_DIR}/../PROVIDERS.md"
  HELP_MD="${SCRIPTS_DIR}/../HELP.md"
  README_MD="${SCRIPTS_DIR}/../../../README.md"
  AGENTS_MD="${SCRIPTS_DIR}/../../../AGENTS.md"
  GATE_SCRIPT="${SCRIPTS_DIR}/evaluate-gates.sh"
  REPO_ROOT="${SCRIPTS_DIR}/../../.."
}

teardown() {
  rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# SKILL.md structural integrity
# ---------------------------------------------------------------------------

@test "SKILL.md: contains required phase headings and no Phase 4 posting" {
  grep -q "### Phase 0:" "$SKILL_MD"
  grep -q "### Phase 1:" "$SKILL_MD"
  grep -q "### Phase 2:" "$SKILL_MD"
  grep -q "### Phase 3:" "$SKILL_MD"
  grep -q "### Phase 5:" "$SKILL_MD"
  if grep -q "### Phase 4" "$SKILL_MD"; then
    echo "REGRESSION: Phase 4 posting section is back" >&2
    return 1
  fi
}

@test "SKILL.md: invokes shipped parsers rather than re-implementing them" {
  grep -q 'resolve-profile.sh' "$SKILL_MD"
  grep -q 'apply-roster-overlays.sh' "$SKILL_MD"
  grep -q 'detect-provider.sh' "$SKILL_MD"
  grep -q 'resolve-skill-root.sh' "$SKILL_MD"
  grep -q 'resolve-models.sh' "$SKILL_MD"
  grep -q 'evaluate-gates.sh' "$SKILL_MD"
  grep -q 'classify-diff.sh' "$SKILL_MD"
  grep -q 'parse-pr-url.sh' "$SKILL_MD"
  grep -q 'review-diff.sh' "$SKILL_MD"
  grep -q 'resolve-pr-base.sh' "$SKILL_MD"
  grep -q 'git diff --no-index' "$SKILL_MD"
  grep -q -- '--check-url-host' "$SKILL_MD"
  grep -q 'origin match is not enough' "$SKILL_MD"
  grep -q '_gates_rc' "$SKILL_MD"
  grep -q 'evaluate-gates.sh failed' "$SKILL_MD"
  grep -q 'JSON.stringify' "$REPO_ROOT/.claude/workflows/code-review-lenses-workflow.js"
}

@test "SKILL.md: captures parser stdout then evals; never eval \"\$(parser)\"" {
  if grep -E 'eval "\$\(bash' "$SKILL_MD"; then
    echo "REGRESSION: eval \"\$(parser)\" swallows exit status" >&2
    return 1
  fi
  grep -q '_profile_out=$(bash' "$SKILL_MD"
  grep -q '_url_out=$(bash' "$SKILL_MD"
  grep -q '_rd_out=$(bash' "$SKILL_MD"
  grep -q '_detect_out=$(bash' "$SKILL_MD"
  grep -q '_overlay_out=$(' "$SKILL_MD"
  grep -q '_gates_rc=0' "$SKILL_MD"
  grep -q -- '--from-file' "$SKILL_MD"
  if grep -E 'resolve-profile\.sh" \$ARGUMENTS' "$SKILL_MD"; then
    echo "REGRESSION: unquoted \$ARGUMENTS on resolve-profile.sh" >&2
    return 1
  fi
  if grep -E 'OVERLAY_ARGS=\(\$ARGUMENTS\)' "$SKILL_MD"; then
    echo "REGRESSION: unquoted \$ARGUMENTS into OVERLAY_ARGS" >&2
    return 1
  fi
}

@test "SKILL.md: Agent Skills frontmatter has name and description" {
  awk 'NR==1{exit !($0=="---")}' "$SKILL_MD"
  grep -q '^name: code-review-lenses$' "$SKILL_MD"
  grep -q '^description:' "$SKILL_MD"
  grep -q 'spec: agent-skills' "$SKILL_MD"
}

@test "SKILL.md: argument-hint lists current flags and free-form GUIDANCE" {
  grep -q '^argument-hint:' "$SKILL_MD"
  grep -q 'GUIDANCE' "$SKILL_MD"
  if grep -qE '^argument-hint:.*--pr |^argument-hint:.*--provider ' "$SKILL_MD"; then
    echo "REGRESSION: --pr/--provider still in argument-hint" >&2
    return 1
  fi
}

@test "SKILL.md: commit lists use two-dot log, not three-dot" {
  grep -q 'log --no-merges --oneline "${BASE}..HEAD"' "$SKILL_MD"
  if grep -E 'git log.*\.\.\.HEAD' "$SKILL_MD"; then
    echo "REGRESSION: git log still uses three-dot range" >&2
    return 1
  fi
}

@test "SKILL.md: PR/MR compare base is fetched target, never main/master/dev" {
  grep -q 'parse-pr-url.sh' "$SKILL_MD"
  grep -q 'never invent `main`, `master`, or `dev`' "$SKILL_MD"
  grep -q 'HEAD@{upstream}' "$SKILL_MD"
  if grep -q 'else `main`' "$SKILL_MD"; then
    echo "REGRESSION: hardcoded main fallback still in SKILL.md" >&2
    return 1
  fi
}

@test "SKILL.md: local provider detection never overrides a URL-derived identity" {
  grep -qF 'if [[ -z "${PR_NUMBER:-}" ]]; then' "$SKILL_MD"
  grep -qF '_detect_out=$(bash "$SCRIPTS_DIR/detect-provider.sh" --fallback unknown)' "$SKILL_MD"
}

@test "classify-diff.sh: defines TIER=tiny with 50-line / 3-file threshold" {
  grep -q "TIER=tiny" "$SCRIPTS_DIR/classify-diff.sh"
  grep -q 'LINES_CHANGED" -lt 50' "$SCRIPTS_DIR/classify-diff.sh"
  grep -q 'FILES_CHANGED" -le 3' "$SCRIPTS_DIR/classify-diff.sh"
}

@test "SKILL.md: --output-file uses the Write tool" {
  grep -q "Write tool\|via the Write" "$SKILL_MD"
}

@test "SKILL.md: defines DOCS_ONLY and LOW_RISK_CONFIG auto-cheap" {
  grep -q "DOCS_ONLY=true\|DOCS_ONLY=false" "$SKILL_MD"
  grep -q "LOW_RISK_CONFIG=true\|LOW_RISK_CONFIG=false" "$SKILL_MD"
  grep -q "Auto-cheap: DOCS_ONLY" "$SKILL_MD"
  grep -q "Auto-cheap: LOW_RISK_CONFIG" "$SKILL_MD"
}

@test "SKILL.md: local-only — no posting or PR-create operations" {
  # Mentions inside the "removed flags" list are required. Live ops are not.
  grep -qE -- '--post-findings|--post-summary|--create-pr|--publish|--read-back|--no-post|--local' "$SKILL_MD"
  if grep -q 'OP: Post\|OP: Create PR\|OP: Stage draft\|POST_MODE=' "$SKILL_MD"; then
    echo "REGRESSION: posting operation found in SKILL.md" >&2
    return 1
  fi
  grep -qi "never posts\|Do not create, comment" "$SKILL_MD"
}

@test "SKILL.md: PR/MR-URL checks read worktree paths and report repo-relative files" {
  grep -qF '"$WORKTREE_PATH/$_p"' "$SKILL_MD"
  grep -qF '<<<"$CHECK_PATHS"' "$SKILL_MD"
  grep -qF '(.[].file | strings) |= ltrimstr($p)' "$SKILL_MD"
  if grep -qF '<<<"$MANIFEST_FILES"' "$SKILL_MD"; then
    echo "REGRESSION: CVE check resolves manifest paths against the reviewer checkout" >&2
    return 1
  fi
}

@test "SKILL.md: dirty DIFF_PATHS stops on ls-files failure and adds no blank line" {
  grep -qF 'if ! _untracked=$("${_git[@]}" ls-files --others --exclude-standard); then' "$SKILL_MD"
  grep -qF '[[ -n "$DIFF_PATHS" && -n "$_untracked" ]]' "$SKILL_MD"
}

@test "SKILL.md: redact_secrets redacts JWTs with any payload, unsecured JWTs, and JWE" {
  command -v perl >/dev/null 2>&1 || skip "perl not available"
  load_function "$SKILL_MD" redact_secrets
  out=$(printf '%s\n' \
    'eyJhbGciOiJIUzI1NiJ9.aGVsbG8gd29ybGQ.c2lnbmF0dXJl' \
    'eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0.' \
    'eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..aXZpdml2aXZp.Y2lwaGVy.dGFn' \
    'lodash 4.17.21 in src/a.test.ts' | redact_secrets)
  [[ "$out" != *eyJ* ]]
  [[ "$out" == *'lodash 4.17.21 in src/a.test.ts'* ]]
}

@test "SKILL.md: code-reviewer is told the supplied diff is its review scope" {
  grep -q 'code-reviewer\*\* — full diff, stated as its review scope' "$SKILL_MD"
}

@test "SKILL.md: spawn is bare agent name, model only when not inherit" {
  grep -q 'bare agent name' "$SKILL_MD"
  grep -q 'MODEL_\*' "$SKILL_MD"
  if grep -q 'comprehensive-review:' "$SKILL_MD"; then
    echo "REGRESSION: plugin-namespace spawn prefix found" >&2
    return 1
  fi
  if grep -q 'pr-review-toolkit:' "$SKILL_MD"; then
    echo "REGRESSION: toolkit plugin-namespace spawn prefix found" >&2
    return 1
  fi
}

@test "SKILL.md: no host plugin cache or CLAUDE_PLUGIN_ROOT paths" {
  if grep -qE 'CLAUDE_PLUGIN_ROOT|~/.claude/plugins|claude-mem|tag1consulting' "$SKILL_MD"; then
    echo "REGRESSION: Claude plugin path or claude-mem reference in SKILL.md" >&2
    return 1
  fi
}

@test "docs and skill: --profile quick/security/full/deep are documented" {
  for f in "$SKILL_MD" "$README_MD" "$HELP_MD" "$AGENTS_MD"; do
    grep -q -- '--profile' "$f"
    grep -q 'quick' "$f"
    grep -q 'security' "$f"
    grep -q 'full' "$f"
    grep -q 'deep' "$f"
  done
}

@test "README.md: documents each profile in a table" {
  grep -q '| \*\*quick\*\*' "$README_MD"
  grep -q '| \*\*security\*\*' "$README_MD"
  grep -q '| \*\*full\*\*' "$README_MD"
  grep -q '| \*\*deep\*\*' "$README_MD"
}

@test "repo has no Claude plugin manifest" {
  if [[ -e "$REPO_ROOT/.claude-plugin/plugin.json" ]]; then
    echo "REGRESSION: .claude-plugin/plugin.json still present" >&2
    return 1
  fi
  if [[ -e "$REPO_ROOT/CLAUDE.md" ]]; then
    echo "REGRESSION: CLAUDE.md still present (use AGENTS.md)" >&2
    return 1
  fi
}

@test "agents: no model: or color: frontmatter" {
  if grep -R --include='*.md' -E '^(model|color):' "$REPO_ROOT/agents"; then
    echo "REGRESSION: host-specific model/color frontmatter in agents/" >&2
    return 1
  fi
}

@test "agents: blind-hunter dirty range is two-dot plus Read untracked" {
  grep -q 'REVIEW_MODE=dirty' "$REPO_ROOT/agents/blind-hunter.md"
  grep -q 'git diff <base> -- <file>' "$REPO_ROOT/agents/blind-hunter.md"
  grep -q 'Untracked files: Read the file' "$REPO_ROOT/agents/blind-hunter.md"
}

@test "agents: all twelve review agents are present" {
  for a in pr-summarizer code-reviewer architecture-reviewer security-reviewer \
           blind-hunter edge-case-hunter adversarial-general issue-linker \
           silent-failure-hunter pr-test-analyzer comment-analyzer type-design-analyzer; do
    [[ -f "$REPO_ROOT/agents/${a}.md" ]]
  done
}

@test "PROVIDERS.md: read-only fetch/checkout only, no post/create/draft" {
  grep -q "OP: Fetch PR/MR metadata" "$PROVIDERS_MD"
  grep -q "OP: Checkout PR/MR branch" "$PROVIDERS_MD"
  grep -q "mr view" "$PROVIDERS_MD"
  grep -q "mr checkout" "$PROVIDERS_MD"
  if grep -q "OP: Post\|OP: Create PR\|OP: Stage draft" "$PROVIDERS_MD"; then
    echo "REGRESSION: write OP still in PROVIDERS.md" >&2
    return 1
  fi
}

@test "PROVIDERS.md: GitHub OPs pin GH_HOST and --repo" {
  grep -q 'GH_HOST="$HOST" gh pr view' "$PROVIDERS_MD"
  grep -q 'GH_HOST="$HOST" gh pr checkout' "$PROVIDERS_MD"
  grep -q -- '--repo "$REPO_SLUG"' "$PROVIDERS_MD"
  grep -q 'baseRefName,baseRefOid' "$PROVIDERS_MD"
}

@test "PROVIDERS.md: GitLab works via glab on any authenticated host" {
  grep -qi "any host" "$PROVIDERS_MD"
  grep -q "glab auth login --hostname" "$PROVIDERS_MD"
}

@test "PROVIDERS.md: GitLab OPs pin GITLAB_HOST and a full-URL -R to the detected host/slug" {
  grep -q 'GITLAB_HOST="$HOST" glab mr view <N> -R "https://$HOST/$REPO_SLUG"' "$PROVIDERS_MD"
  grep -q 'GITLAB_HOST="$HOST" glab mr checkout <N> -R "https://$HOST/$REPO_SLUG"' "$PROVIDERS_MD"
  grep -q 'diff_refs.base_sha→baseRefOid' "$PROVIDERS_MD"
  if grep -q 'glab --hostname' "$PROVIDERS_MD"; then
    echo "REGRESSION: glab has no global --hostname flag (Unknown flag: --hostname)" >&2
    return 1
  fi
  if grep -E '^\s*- \*\*gitlab:\*\* `glab mr (view|checkout|list)' "$PROVIDERS_MD"; then
    echo "REGRESSION: unqualified glab mr OP (no GITLAB_HOST / -R)" >&2
    return 1
  fi
}

@test "docs/architecture.md: no posting-matrix leftover" {
  ARCH_MD="${SCRIPTS_DIR}/../../../docs/architecture.md"
  if grep -q 'usage#posting-behavior\|What gets posted remotely' "$ARCH_MD"; then
    echo "REGRESSION: posting-matrix leftover in docs/architecture.md" >&2
    return 1
  fi
}

@test "CHANGELOG 2.0 documents migration paths and 1.13.0 rollback" {
  grep -q 'Migration (1.13' "$README_MD" || grep -q 'Migration (1.13' "${SCRIPTS_DIR}/../../../CHANGELOG.md"
  CHANGELOG="${SCRIPTS_DIR}/../../../CHANGELOG.md"
  grep -q '.claude/comprehensive-review/suppressions.json' "$CHANGELOG"
  grep -q '.code-review-lenses/suppressions.json' "$CHANGELOG"
  grep -q 'claude-security-guidance.md' "$CHANGELOG"
  grep -q 'v1.13.0' "$CHANGELOG"
}

@test "SEVERITY.md: category field and taxonomy documented" {
  grep -q "category" "$SEVERITY_MD"
  grep -q "authz" "$SEVERITY_MD"
  grep -q "injection" "$SEVERITY_MD"
  grep -q "dependency-cve" "$SEVERITY_MD"
  grep -q "secret" "$SEVERITY_MD"
  grep -q "architecture-coupling" "$SEVERITY_MD"
  grep -q "edge-case" "$SEVERITY_MD"
}

@test "SEVERITY.md: toolkit scales follow the vendored rating guidelines" {
  grep -qF 'gap [9,10] / [7,8] / [5,6] / [1,4]' "$SEVERITY_MD"
  grep -qF '9-10: Critical functionality' "$REPO_ROOT/agents/pr-test-analyzer.md"
  grep -q 'lowest of its four ratings' "$SEVERITY_MD"
}

# ---------------------------------------------------------------------------
# Gate decisions for synthetic fixture diffs
# ---------------------------------------------------------------------------

@test "gates: tiny docs-only diff: GATE_CODE_OR_INFRA=false, all security gates false" {
  printf '+Updated docs\n+More content\n' > "${WORK}/docs.diff"
  DIFF_FILE="${WORK}/docs.diff" DIFF_PATHS="README.md" \
    run bash "$GATE_SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GATE_CODE_OR_INFRA=false"
  echo "$output" | grep -q "GATE_SECURITY_PATTERNS=false"
  echo "$output" | grep -q "GATE_ERROR_PATTERNS=false"
}

@test "gates: Go source with error handling: GATE_ERROR_PATTERNS=true, GATE_CODE_OR_INFRA=true" {
  printf '+if err != nil { return err }\n+func main() {}\n' > "${WORK}/go.diff"
  DIFF_FILE="${WORK}/go.diff" DIFF_PATHS="cmd/main.go" \
    run bash "$GATE_SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GATE_ERROR_PATTERNS=true"
  echo "$output" | grep -q "GATE_CODE_OR_INFRA=true"
}

@test "gates: dep manifest change triggers GATE_SECURITY_PATTERNS" {
  printf '+  "lodash": "4.17.21"\n' > "${WORK}/pkg.diff"
  DIFF_FILE="${WORK}/pkg.diff" DIFF_PATHS="package.json" \
    run bash "$GATE_SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GATE_SECURITY_PATTERNS=true"
}

@test "gates: GitHub Actions workflow triggers GATE_CODE_OR_INFRA even if diff is docs-like" {
  printf '+    runs-on: ubuntu-latest\n' > "${WORK}/ci.diff"
  DIFF_FILE="${WORK}/ci.diff" DIFF_PATHS=".github/workflows/ci.yml" \
    run bash "$GATE_SCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GATE_CODE_OR_INFRA=true"
}

@test "cve-check: findings include category=dependency-cve" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  cp "${FIXTURES_DIR}/cve/go.mod.replace-before-require" "${WORK}/go.mod"
  OSV_MOCK_FILE="${FIXTURES_DIR}/cve/osv-batch-critical.json" \
    run --separate-stderr bash "${SCRIPTS_DIR}/run-cve-check.sh" "${WORK}/go.mod"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].category == "dependency-cve"' >/dev/null
}

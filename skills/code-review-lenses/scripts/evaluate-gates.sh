#!/usr/bin/env bash
#
# evaluate-gates.sh — Evaluate the agent-dispatch gates and emit
# shell-sourceable key=value assignments to stdout.
#
# Usage (capture then eval — do not source <(…) or eval "$(…)"; that
# discards a non-zero exit):
#   _gates_tmp=$(mktemp)
#   DIFF_FILE=<path> DIFF_PATHS=<newline-list> bash evaluate-gates.sh > "$_gates_tmp" || exit $?
#   source "$_gates_tmp"
#
# Required environment:
#   DIFF_FILE   Path to the aggregate diff temp file
#   DIFF_PATHS  Newline-separated list of changed repo-relative file paths
#
# Output (sourced by the orchestrator):
#   GATE_ERROR_PATTERNS=true|false
#   GATE_CONTROL_FLOW=true|false
#   GATE_SECURITY_PATTERNS=true|false
#   GATE_CODE_OR_INFRA=true|false
#   GATE_TEST_PATHS=true|false
#   GATE_COMMENT_CHANGES=true|false
#   GATE_TYPE_DEFINITIONS=true|false
#
# When DIFF_FILE is absent or DIFF_PATHS is empty, all gates default to true
# (conservative — avoids silently skipping agents due to missing data).

set -euo pipefail

DIFF_FILE="${DIFF_FILE:-}"
DIFF_PATHS="${DIFF_PATHS:-}"

if [[ -z "$DIFF_FILE" || ! -f "$DIFF_FILE" || -z "$DIFF_PATHS" ]]; then
  echo "GATE_ERROR_PATTERNS=true"
  echo "GATE_CONTROL_FLOW=true"
  echo "GATE_SECURITY_PATTERNS=true"
  echo "GATE_CODE_OR_INFRA=true"
  echo "GATE_TEST_PATHS=true"
  echo "GATE_COMMENT_CHANGES=true"
  echo "GATE_TYPE_DEFINITIONS=true"
  exit 0
fi

# Gate: has_error_patterns — fires silent-failure-hunter
# Exit 0 = match → set gate true; exit 1 = no match → leave false; exit 2 = I/O error → abort.
GATE_ERROR_PATTERNS=false
_rc=0
grep -qE 'catch\b|if err|try \{|rescue\b|Result<|unwrap\b|\.error\(|\.expect\(|runCatching|guard\b|throws\b' "$DIFF_FILE" || _rc=$?
if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed reading $DIFF_FILE" >&2; exit 1; fi
if [[ $_rc -eq 0 ]]; then GATE_ERROR_PATTERNS=true; fi

# Gate: has_control_flow — fires edge-case-hunter (added lines only via + prefix filter)
# The first grep (extract + lines) may legitimately exit 1 (no added lines); treat that as false.
# The second grep exits 2 only on I/O error, which we abort on.
GATE_CONTROL_FLOW=false
_rc=0
_added_lines=$(grep -E '^\+' "$DIFF_FILE") || _rc=$?
if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed reading $DIFF_FILE" >&2; exit 1; fi
if [[ -n "$_added_lines" ]]; then
  _rc=0
  grep -qE '\b(if|elif|else|for|while|do|case|switch|match|try|catch|except|rescue|unless|when|loop|break|continue|return|goto|defer|finally)\b' <<< "$_added_lines" || _rc=$?
  if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed on added lines" >&2; exit 1; fi
  if [[ $_rc -eq 0 ]]; then GATE_CONTROL_FLOW=true; fi
fi

# Gate: has_security_patterns — when false, SKILL.md may classify the diff as
# LOW_RISK_CONFIG (full profile only). Does not schedule security-reviewer.
GATE_SECURITY_PATTERNS=false
_rc=0
grep -qiE 'auth|token|secret|password|crypt|hash|\bsign\b|verify|exec\b|eval\b|sql|sanitize|escape|xss|csrf|cors|header|redirect|deserialize|cookie|session|jwt|oauth|ldap|saml|rbac|acl|permission|privilege|sudo|chmod|chown|setuid|x509|tls|ssl|cert|certificate|keystore|nonce|salt|hmac|aes|rsa|ecdsa|pbkdf2|bcrypt|scrypt|curl\b|wget\b|\bsource\b|\bIFS\b|LD_PRELOAD|\$\{\{' "$DIFF_FILE" || _rc=$?
if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed reading $DIFF_FILE" >&2; exit 1; fi
if [[ $_rc -eq 0 ]]; then GATE_SECURITY_PATTERNS=true; fi
_rc=0
grep -qiE '(auth|passwords?|credentials?|tokens?|secrets?)|(^|/)(api|routes?)/|(^|/)(package\.json|package-lock\.json|go\.mod|go\.sum|composer\.json|composer\.lock|requirements[^/]*\.txt|pyproject\.toml|Pipfile(\.lock)?|Gemfile(\.lock)?|[Cc]argo\.(toml|lock)|yarn\.lock|pnpm-lock\.yaml)$|(^|/)\.env|(^|/)settings\.(py|ya?ml|json|toml)$|(^|/)(Dockerfile|Containerfile)$|\.sh$|\.bash$|(^|/)\.github/workflows/' <<< "$DIFF_PATHS" || _rc=$?
if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed reading DIFF_PATHS" >&2; exit 1; fi
if [[ $_rc -eq 0 ]]; then GATE_SECURITY_PATTERNS=true; fi

# Gate: has_code_or_infra — suppresses architecture-reviewer on pure docs/meta diffs
GATE_CODE_OR_INFRA=false
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Workflow files always count as infra
  if echo "$f" | grep -qE '(^|/)(\.github|\.claude|\.grok)/workflows/'; then
    GATE_CODE_OR_INFRA=true; break
  fi
  # Pure doc extensions → skip
  echo "$f" | grep -qE '\.(md|markdown|txt|rst|adoc)$' && continue
  # Meta directories and GitHub's documentary files → skip (other .github files, such as actions/, are infra)
  echo "$f" | grep -qE '(^|/)(docs|memory-bank|\.claude)/|(^|/)\.github/((ISSUE|DISCUSSION|PULL_REQUEST)_TEMPLATE/|FUNDING\.ya?ml$)' && continue
  # Meta filenames → skip
  echo "$f" | grep -qiE '(^|/)(CHANGELOG|README|LICENSE|NOTICE|AUTHORS|CONTRIBUTING|CODEOWNERS|CODE_OF_CONDUCT)(\..+)?$' && continue
  # Anything else is code or infra
  GATE_CODE_OR_INFRA=true; break
done <<< "$DIFF_PATHS"

# Gate: has_test_paths — fires pr-test-analyzer
GATE_TEST_PATHS=false
_rc=0
grep -qE '(^|/)([^/]*_test\.go|test_[^/]*\.py|[^/]*\.test\.ts|[^/]*\.spec\.ts|[^/]*_test\.[^/]*|[^/]*\.test\.[^/]*|[^/]*\.spec\.[^/]*|[^/]*_spec\.rb|[^/]*Test\.java|[^/]*Tests\.cs)$|(^|/)(spec|__tests__|test|tests|src/test)/' <<< "$DIFF_PATHS" || _rc=$?
if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed reading DIFF_PATHS" >&2; exit 1; fi
if [[ $_rc -eq 0 ]]; then GATE_TEST_PATHS=true; fi

# Gates: has_comment_changes, has_type_definitions — fire comment-analyzer and type-design-analyzer
# on added or removed lines; the +++ / --- file headers are excluded.
GATE_COMMENT_CHANGES=false
GATE_TYPE_DEFINITIONS=false
_rc=0
_changed_lines=$(grep -E '^([+][^+]|[-][^-])' "$DIFF_FILE") || _rc=$?
if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed reading $DIFF_FILE" >&2; exit 1; fi
if [[ -n "$_changed_lines" ]]; then
  _rc=0
  grep -qE "^[+-][[:space:]]*(//|#|/\\*|\"\"\"|''')" <<< "$_changed_lines" || _rc=$?
  if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed on changed lines" >&2; exit 1; fi
  if [[ $_rc -eq 0 ]]; then GATE_COMMENT_CHANGES=true; fi
  _rc=0
  grep -qE '\btype .* struct\b|\binterface |\bclass |\benum ' <<< "$_changed_lines" || _rc=$?
  if [[ $_rc -eq 2 ]]; then echo "ERROR: grep failed on changed lines" >&2; exit 1; fi
  if [[ $_rc -eq 0 ]]; then GATE_TYPE_DEFINITIONS=true; fi
fi

echo "GATE_ERROR_PATTERNS=${GATE_ERROR_PATTERNS}"
echo "GATE_CONTROL_FLOW=${GATE_CONTROL_FLOW}"
echo "GATE_SECURITY_PATTERNS=${GATE_SECURITY_PATTERNS}"
echo "GATE_CODE_OR_INFRA=${GATE_CODE_OR_INFRA}"
echo "GATE_TEST_PATHS=${GATE_TEST_PATHS}"
echo "GATE_COMMENT_CHANGES=${GATE_COMMENT_CHANGES}"
echo "GATE_TYPE_DEFINITIONS=${GATE_TYPE_DEFINITIONS}"

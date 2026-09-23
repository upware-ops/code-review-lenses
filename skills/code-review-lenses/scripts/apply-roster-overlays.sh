#!/usr/bin/env bash
# apply-roster-overlays.sh — apply TIER / docs-only / gate overlays to a
# profile roster produced by resolve-profile.sh.
#
# Usage:
#   TIER=tiny DOCS_ONLY=false ... bash apply-roster-overlays.sh --profile full
#   # No args: re-runs resolve-profile.sh only when PROFILE is unset.
#   # If PROFILE is set, every RUN_* must already be in the environment.
#
# Remaining CLI args are forwarded to resolve-profile.sh (the shipped parser).
# Overlay env (defaults shown):
#   TIER=medium
#   DOCS_ONLY=false
#   LOW_RISK_CONFIG=false
#   ARCH_PROMOTED=false
#   SECURITY_PROMOTED=false
#   GATE_CONTROL_FLOW=true
#   GATE_ERROR_PATTERNS=true
#   GATE_CODE_OR_INFRA=true
#   PROVIDER=          (empty keeps issue-linker; any non-github value skips it)
#
# Output: the same KEY=value roster, after overlays. Safe to eval.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $# -gt 0 ]]; then
  _profile_out=$(bash "$SCRIPT_DIR/resolve-profile.sh" "$@") || exit $?
  eval "$_profile_out"
  unset _profile_out
elif [[ -z "${PROFILE:-}" ]]; then
  _profile_out=$(bash "$SCRIPT_DIR/resolve-profile.sh") || exit $?
  eval "$_profile_out"
  unset _profile_out
fi

: "${PROFILE:?PROFILE is required (pass --profile or eval resolve-profile.sh first)}"
: "${GUIDANCE:=}"
: "${RUN_PR_SUMMARIZER:?}"
: "${RUN_CODE_REVIEWER:?}"
: "${RUN_ARCHITECTURE_REVIEWER:?}"
: "${RUN_SECURITY_REVIEWER:?}"
: "${RUN_BLIND_HUNTER:?}"
: "${RUN_EDGE_CASE_HUNTER:?}"
: "${RUN_ADVERSARIAL_GENERAL:?}"
: "${RUN_ISSUE_LINKER:?}"
: "${RUN_SILENT_FAILURE_HUNTER:?}"
: "${RUN_PR_TEST_ANALYZER:?}"
: "${RUN_COMMENT_ANALYZER:?}"
: "${RUN_TYPE_DESIGN_ANALYZER:?}"
: "${RUN_CVE:?}"
: "${RUN_STATIC_ANALYZERS:?}"
: "${EXTENDED_THINKING:?}"
: "${CVE_REACHABILITY:?}"
: "${RUN_ENRICH_CONTEXT:?}"

TIER="${TIER:-medium}"
DOCS_ONLY="${DOCS_ONLY:-false}"
LOW_RISK_CONFIG="${LOW_RISK_CONFIG:-false}"
ARCH_PROMOTED="${ARCH_PROMOTED:-false}"
SECURITY_PROMOTED="${SECURITY_PROMOTED:-false}"
GATE_CONTROL_FLOW="${GATE_CONTROL_FLOW:-true}"
GATE_ERROR_PATTERNS="${GATE_ERROR_PATTERNS:-true}"
GATE_CODE_OR_INFRA="${GATE_CODE_OR_INFRA:-true}"
PROVIDER="${PROVIDER:-}"

SKIP_REASONS=()

skip() {
  local var="$1"
  local reason="$2"
  [[ "${!var}" == "false" ]] && return 0
  printf -v "$var" '%s' "false"
  SKIP_REASONS+=("$reason")
}

# Auto-cheap overlays apply only to the default full profile. Explicit
# quick / security / summary / deep contracts are not rewritten.
if [[ "$PROFILE" == "full" && "$DOCS_ONLY" == "true" ]]; then
  skip RUN_ARCHITECTURE_REVIEWER "architecture-reviewer (DOCS_ONLY)"
  skip RUN_SECURITY_REVIEWER "security-reviewer (DOCS_ONLY)"
  skip RUN_BLIND_HUNTER "blind-hunter (DOCS_ONLY)"
  skip RUN_EDGE_CASE_HUNTER "edge-case-hunter (DOCS_ONLY)"
  skip RUN_ADVERSARIAL_GENERAL "adversarial-general (DOCS_ONLY)"
  skip RUN_ISSUE_LINKER "issue-linker (DOCS_ONLY)"
  skip RUN_COMMENT_ANALYZER "comment-analyzer (DOCS_ONLY)"
  skip RUN_TYPE_DESIGN_ANALYZER "type-design-analyzer (DOCS_ONLY)"
fi

if [[ "$PROFILE" == "full" && "$LOW_RISK_CONFIG" == "true" && "$DOCS_ONLY" != "true" ]]; then
  if [[ "$ARCH_PROMOTED" != "true" ]]; then
    skip RUN_ARCHITECTURE_REVIEWER "architecture-reviewer (LOW_RISK_CONFIG)"
  fi
  if [[ "$SECURITY_PROMOTED" != "true" ]]; then
    skip RUN_SECURITY_REVIEWER "security-reviewer (LOW_RISK_CONFIG)"
  fi
  skip RUN_BLIND_HUNTER "blind-hunter (LOW_RISK_CONFIG)"
  skip RUN_EDGE_CASE_HUNTER "edge-case-hunter (LOW_RISK_CONFIG)"
  skip RUN_ADVERSARIAL_GENERAL "adversarial-general (LOW_RISK_CONFIG)"
  skip RUN_COMMENT_ANALYZER "comment-analyzer (LOW_RISK_CONFIG)"
  skip RUN_TYPE_DESIGN_ANALYZER "type-design-analyzer (LOW_RISK_CONFIG)"
fi

# TIER=tiny: skip blind-hunter, edge-case-hunter, adversarial-general,
# comment-analyzer, and type-design-analyzer. silent-failure-hunter and
# pr-test-analyzer stay scheduled (conditional). Architecture and security
# run only when their promotion triggers fired — except that an explicit
# security profile always keeps security-reviewer.
if [[ "$TIER" == "tiny" ]]; then
  skip RUN_BLIND_HUNTER "blind-hunter (TIER=tiny)"
  skip RUN_EDGE_CASE_HUNTER "edge-case-hunter (TIER=tiny)"
  skip RUN_ADVERSARIAL_GENERAL "adversarial-general (TIER=tiny)"
  skip RUN_COMMENT_ANALYZER "comment-analyzer (TIER=tiny)"
  skip RUN_TYPE_DESIGN_ANALYZER "type-design-analyzer (TIER=tiny)"
  if [[ "$RUN_ARCHITECTURE_REVIEWER" == "true" && "$ARCH_PROMOTED" != "true" ]]; then
    skip RUN_ARCHITECTURE_REVIEWER "architecture-reviewer (TIER=tiny, not promoted)"
  fi
  if [[ "$RUN_SECURITY_REVIEWER" == "true" && "$SECURITY_PROMOTED" != "true" && "$PROFILE" != "security" ]]; then
    skip RUN_SECURITY_REVIEWER "security-reviewer (TIER=tiny, not promoted)"
  fi
  RUN_ENRICH_CONTEXT=false
fi

# Gate overlays (only turn scheduled agents off).
if [[ "$RUN_EDGE_CASE_HUNTER" == "true" && "$GATE_CONTROL_FLOW" == "false" ]]; then
  skip RUN_EDGE_CASE_HUNTER "edge-case-hunter (GATE_CONTROL_FLOW=false)"
fi
# Same contract as DOCS_ONLY: only the default full profile is cheapened.
# --profile deep must keep architecture-reviewer (HELP / overlay header).
if [[ "$PROFILE" == "full" && "$RUN_ARCHITECTURE_REVIEWER" == "true" && "$GATE_CODE_OR_INFRA" == "false" && "$ARCH_PROMOTED" != "true" ]]; then
  skip RUN_ARCHITECTURE_REVIEWER "architecture-reviewer (GATE_CODE_OR_INFRA=false)"
fi
if [[ "$RUN_SILENT_FAILURE_HUNTER" != "false" && "$GATE_ERROR_PATTERNS" == "false" ]]; then
  skip RUN_SILENT_FAILURE_HUNTER "silent-failure-hunter (GATE_ERROR_PATTERNS=false)"
fi

# issue-linker is GitHub-only.
if [[ "$RUN_ISSUE_LINKER" == "true" && -n "$PROVIDER" && "$PROVIDER" != "github" ]]; then
  skip RUN_ISSUE_LINKER "issue-linker (PROVIDER=$PROVIDER, GitHub only)"
fi

# Tiny / summary / security / quick already disable enrichment; keep that.
if [[ "$PROFILE" == "summary" || "$PROFILE" == "quick" || "$PROFILE" == "security" ]]; then
  RUN_ENRICH_CONTEXT=false
fi

emit() {
  printf '%s=%q\n' "$1" "$2"
}

emit PROFILE "$PROFILE"
# Do not emit GUIDANCE. The caller already stripped the PR/MR URL
# (GUIDANCE_REST). Re-parsing --from-file would restore the URL as focus.
emit TIER "$TIER"
emit DOCS_ONLY "$DOCS_ONLY"
emit LOW_RISK_CONFIG "$LOW_RISK_CONFIG"
emit ARCH_PROMOTED "$ARCH_PROMOTED"
emit SECURITY_PROMOTED "$SECURITY_PROMOTED"
emit RUN_PR_SUMMARIZER "$RUN_PR_SUMMARIZER"
emit RUN_CODE_REVIEWER "$RUN_CODE_REVIEWER"
emit RUN_ARCHITECTURE_REVIEWER "$RUN_ARCHITECTURE_REVIEWER"
emit RUN_SECURITY_REVIEWER "$RUN_SECURITY_REVIEWER"
emit RUN_BLIND_HUNTER "$RUN_BLIND_HUNTER"
emit RUN_EDGE_CASE_HUNTER "$RUN_EDGE_CASE_HUNTER"
emit RUN_ADVERSARIAL_GENERAL "$RUN_ADVERSARIAL_GENERAL"
emit RUN_ISSUE_LINKER "$RUN_ISSUE_LINKER"
emit RUN_SILENT_FAILURE_HUNTER "$RUN_SILENT_FAILURE_HUNTER"
emit RUN_PR_TEST_ANALYZER "$RUN_PR_TEST_ANALYZER"
emit RUN_COMMENT_ANALYZER "$RUN_COMMENT_ANALYZER"
emit RUN_TYPE_DESIGN_ANALYZER "$RUN_TYPE_DESIGN_ANALYZER"
emit RUN_CVE "$RUN_CVE"
emit RUN_STATIC_ANALYZERS "$RUN_STATIC_ANALYZERS"
emit EXTENDED_THINKING "$EXTENDED_THINKING"
emit CVE_REACHABILITY "$CVE_REACHABILITY"
emit RUN_ENRICH_CONTEXT "$RUN_ENRICH_CONTEXT"
if [[ ${#SKIP_REASONS[@]} -gt 0 ]]; then
  emit SKIP_REASONS "$(IFS='|'; echo "${SKIP_REASONS[*]}")"
else
  emit SKIP_REASONS ""
fi

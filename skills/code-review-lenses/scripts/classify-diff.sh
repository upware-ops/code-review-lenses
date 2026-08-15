#!/usr/bin/env bash
# classify-diff.sh — emit TIER, ARCH_PROMOTED, SECURITY_PROMOTED,
# DOCS_ONLY, and LOW_RISK_CONFIG from DIFF_FILE / DIFF_PATHS (and gates).
#
# Usage (capture then eval — do not eval "$(…)"):
#   _cls=$(DIFF_FILE=... DIFF_PATHS=... GATE_CODE_OR_INFRA=... \
#     GATE_SECURITY_PATTERNS=... bash classify-diff.sh) || exit $?
#   eval "$_cls"
#
# Required:
#   DIFF_FILE   aggregate diff
#   DIFF_PATHS  newline-separated changed paths
# Optional (from evaluate-gates.sh; default true so missing gates do not
# invent docs-only cheapening):
#   GATE_CODE_OR_INFRA GATE_SECURITY_PATTERNS
#
# Exit 0 on success. Exit 1 if DIFF_FILE is set but unreadable.

set -euo pipefail

emit() { printf '%s=%q\n' "$1" "$2"; }

if [[ -n "${DIFF_FILE:-}" && ! -r "$DIFF_FILE" ]]; then
  echo "Error: classify-diff.sh: DIFF_FILE '${DIFF_FILE}' is not readable." >&2
  exit 1
fi

FILES_CHANGED=$(printf '%s\n' "${DIFF_PATHS-}" | sed '/^$/d' | wc -l | tr -d ' ')
LINES_CHANGED=0
if [[ -n "${DIFF_FILE:-}" && -r "$DIFF_FILE" ]]; then
  LINES_CHANGED=$(grep -cE '^[+-]' "$DIFF_FILE" || true)
fi

TIER=medium
if [[ "$LINES_CHANGED" -lt 50 && "$FILES_CHANGED" -le 3 ]]; then
  TIER=tiny
elif [[ "$LINES_CHANGED" -lt 300 ]]; then
  TIER=small
fi

ARCH_PROMOTED=false
SECURITY_PROMOTED=false
if [[ "$TIER" == "tiny" ]]; then
  TINY_DIFF_NAMES="${DIFF_PATHS-}"
  if echo "$TINY_DIFF_NAMES" | grep -qE '(auth|passwords?|routes?/|/api/|credentials?|token|secret)' \
    || echo "$TINY_DIFF_NAMES" | grep -qE '(^|/)(package\.json|go\.mod|composer\.json|requirements.*\.txt|pyproject\.toml|Gemfile|Pipfile|[Cc]argo\.toml)$' \
    || echo "$TINY_DIFF_NAMES" | grep -qE '(^|/)\.env' \
    || echo "$TINY_DIFF_NAMES" | grep -qE 'settings\.(py|ya?ml|json|toml)$'; then
    SECURITY_PROMOTED=true
  fi
  if echo "$TINY_DIFF_NAMES" | grep -qE '(^|/)(Dockerfile|\.nvmrc|\.node-version|\.ddev/|\.github/workflows/|\.claude/workflows/|\.grok/workflows/|\.gitlab-ci\.yml|bitbucket-pipelines\.yml|lagoon/|helm/|k8s/|kubernetes/|terraform/|docker-compose)'; then
    ARCH_PROMOTED=true
  elif [[ $(echo "$TINY_DIFF_NAMES" | sed '/^$/d' | awk -F/ '{print $1}' | sort -u | wc -l | tr -d ' ') -ge 2 ]]; then
    ARCH_PROMOTED=true
  fi
fi

GATE_CODE_OR_INFRA="${GATE_CODE_OR_INFRA:-true}"
GATE_SECURITY_PATTERNS="${GATE_SECURITY_PATTERNS:-true}"

DOCS_ONLY=false
[[ "$GATE_CODE_OR_INFRA" == "false" ]] && DOCS_ONLY=true
LOW_RISK_CONFIG=false
if [[ "$DOCS_ONLY" == "false" && "$GATE_SECURITY_PATTERNS" == "false" ]]; then
  _nonempty=$(printf '%s\n' "${DIFF_PATHS-}" | sed '/^$/d')
  if [[ -n "$_nonempty" ]] && ! echo "$_nonempty" | grep -qiEv '\.(ya?ml|toml|ini|conf|cfg|env\.example)$'; then
    LOW_RISK_CONFIG=true
  fi
fi

emit TIER "$TIER"
emit ARCH_PROMOTED "$ARCH_PROMOTED"
emit SECURITY_PROMOTED "$SECURITY_PROMOTED"
emit DOCS_ONLY "$DOCS_ONLY"
emit LOW_RISK_CONFIG "$LOW_RISK_CONFIG"
emit LINES_CHANGED "$LINES_CHANGED"
emit FILES_CHANGED "$FILES_CHANGED"

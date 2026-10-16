#!/usr/bin/env bash
# resolve-models.sh — load optional models.conf and emit per-agent model ids.
#
# Usage:
#   bash resolve-models.sh [path-to-models.conf]
#
# If the file is omitted, looks for ../models.conf relative to this script.
# Missing file → every agent is `inherit`.
#
# Output: MODEL_<AGENT>=value lines, plus the five ROLE_* values.
# `inherit` means: do not pass a model when spawning; let the host decide.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF="${1:-$SCRIPT_DIR/../models.conf}"

ROLE_SUMMARIZER=inherit
ROLE_REVIEWER=inherit
ROLE_SPECIALIST=inherit
ROLE_HUNTER=inherit
ROLE_LINKER=inherit
OVERRIDES=""

if [[ -f "$CONF" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    [[ -z "$key" || -z "$val" ]] && continue
    case "$key" in
      summarizer) ROLE_SUMMARIZER="$val" ;;
      reviewer) ROLE_REVIEWER="$val" ;;
      specialist) ROLE_SPECIALIST="$val" ;;
      hunter) ROLE_HUNTER="$val" ;;
      linker) ROLE_LINKER="$val" ;;
      *) OVERRIDES="${OVERRIDES}${key}=${val}"$'\n' ;;
    esac
  done < "$CONF"
fi

override_for() {
  local name="$1"
  local row
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    if [[ "${row%%=*}" == "$name" ]]; then
      printf '%s\n' "${row#*=}"
      return 0
    fi
  done <<EOF
$OVERRIDES
EOF
  return 1
}

agent_model() {
  local name="$1"
  local role="$2"
  local over
  if over=$(override_for "$name"); then
    printf '%s\n' "$over"
  else
    printf '%s\n' "$role"
  fi
}

MODEL_PR_SUMMARIZER=$(agent_model pr-summarizer "$ROLE_SUMMARIZER")
MODEL_CODE_REVIEWER=$(agent_model code-reviewer "$ROLE_REVIEWER")
MODEL_SILENT_FAILURE_HUNTER=$(agent_model silent-failure-hunter "$ROLE_REVIEWER")
MODEL_PR_TEST_ANALYZER=$(agent_model pr-test-analyzer "$ROLE_REVIEWER")
MODEL_COMMENT_ANALYZER=$(agent_model comment-analyzer "$ROLE_REVIEWER")
MODEL_TYPE_DESIGN_ANALYZER=$(agent_model type-design-analyzer "$ROLE_REVIEWER")
MODEL_ARCHITECTURE_REVIEWER=$(agent_model architecture-reviewer "$ROLE_SPECIALIST")
MODEL_SECURITY_REVIEWER=$(agent_model security-reviewer "$ROLE_SPECIALIST")
MODEL_ADVERSARIAL_GENERAL=$(agent_model adversarial-general "$ROLE_SPECIALIST")
MODEL_BLIND_HUNTER=$(agent_model blind-hunter "$ROLE_HUNTER")
MODEL_EDGE_CASE_HUNTER=$(agent_model edge-case-hunter "$ROLE_HUNTER")
MODEL_ISSUE_LINKER=$(agent_model issue-linker "$ROLE_LINKER")

emit() {
  printf '%s=%q\n' "$1" "$2"
}

emit ROLE_SUMMARIZER "$ROLE_SUMMARIZER"
emit ROLE_REVIEWER "$ROLE_REVIEWER"
emit ROLE_SPECIALIST "$ROLE_SPECIALIST"
emit ROLE_HUNTER "$ROLE_HUNTER"
emit ROLE_LINKER "$ROLE_LINKER"
emit MODEL_PR_SUMMARIZER "$MODEL_PR_SUMMARIZER"
emit MODEL_CODE_REVIEWER "$MODEL_CODE_REVIEWER"
emit MODEL_SILENT_FAILURE_HUNTER "$MODEL_SILENT_FAILURE_HUNTER"
emit MODEL_PR_TEST_ANALYZER "$MODEL_PR_TEST_ANALYZER"
emit MODEL_COMMENT_ANALYZER "$MODEL_COMMENT_ANALYZER"
emit MODEL_TYPE_DESIGN_ANALYZER "$MODEL_TYPE_DESIGN_ANALYZER"
emit MODEL_ARCHITECTURE_REVIEWER "$MODEL_ARCHITECTURE_REVIEWER"
emit MODEL_SECURITY_REVIEWER "$MODEL_SECURITY_REVIEWER"
emit MODEL_ADVERSARIAL_GENERAL "$MODEL_ADVERSARIAL_GENERAL"
emit MODEL_BLIND_HUNTER "$MODEL_BLIND_HUNTER"
emit MODEL_EDGE_CASE_HUNTER "$MODEL_EDGE_CASE_HUNTER"
emit MODEL_ISSUE_LINKER "$MODEL_ISSUE_LINKER"

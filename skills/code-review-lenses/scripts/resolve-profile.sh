#!/usr/bin/env bash
# resolve-profile.sh — parse skill arguments and emit the requested profile
# plus the pre-overlay agent roster.
#
# Usage:
#   bash resolve-profile.sh [skill-arguments...]
#
# Output: KEY=value lines on stdout, safe to `eval` / source.
# Exit 0 on success. Exit 2 on flag / usage errors (message on stderr).
#
# This script is the shipped argument parser. Orchestrator SKILL.md must
# invoke it rather than re-implement flag handling.

set -euo pipefail

PROFILE=""
SUMMARY_ONLY=false
BASE=""
OUTPUT_FILE=""
MIN_CONFIDENCE=75
NO_ENRICH_CONTEXT=false
NO_SUPPRESS=false

REMOVED_FLAGS=(
  --quick
  --security-only
  --depth
  --pr
  --provider
  --post-findings
  --post-summary
  --create-pr
  --no-post
  --local
  --publish
  --draft
  --read-back
  --no-mem
  --no-findings
)

die() {
  echo "Error: $*" >&2
  exit 2
}

is_removed() {
  local flag="$1"
  local f
  for f in "${REMOVED_FLAGS[@]}"; do
    [[ "$flag" == "$f" ]] && return 0
  done
  return 1
}

removed_hint() {
  local flag="$1"
  case "$flag" in
    --quick) echo "Use --profile quick." ;;
    --security-only) echo "Use --profile security." ;;
    --depth) echo "Use --profile deep (or --profile full)." ;;
    --pr|--provider)
      echo "Pass a PR/MR URL in the invoke text (not a number or --provider). Host and number come from the URL."
      ;;
    --post-findings|--post-summary|--create-pr|--publish|--draft|--read-back|--no-findings)
      echo "This pipeline is local-only and does not post to or create PRs/MRs."
      ;;
    --no-post|--local)
      echo "Local-only is the only mode; these flags were removed."
      ;;
    --no-mem)
      echo "Host-specific memory integrations were removed."
      ;;
    *) echo "Flag removed." ;;
  esac
}

need_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value."
  fi
}

GUIDANCE_TOKENS=()
PROFILE_SET=false

# --from-file: tokenize invoke text without a shell eval or glob.
# The file is data. Command substitution in the file is not executed.
if [[ "${1:-}" == --from-file || "${1:-}" == --from-file=* ]]; then
  _args_file=""
  if [[ "$1" == --from-file ]]; then
    need_value "$1" "${2-}"
    _args_file="$2"
    shift 2
  else
    _args_file="${1#--from-file=}"
    shift
  fi
  if [[ $# -gt 0 ]]; then
    die "--from-file cannot be mixed with other arguments."
  fi
  [[ -n "$_args_file" && -f "$_args_file" ]] || die "--from-file requires an existing file."
  _line=$(cat "$_args_file")
  set -f
  # noglob word-split only — not eval, so $(...) stays literal.
  # shellcheck disable=SC2086
  set -- ${_line}
  set +f
  unset _args_file _line
fi

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --profile)
      need_value "$arg" "${2-}"
      PROFILE="$2"
      PROFILE_SET=true
      shift 2
      ;;
    --profile=*)
      PROFILE="${arg#--profile=}"
      PROFILE_SET=true
      shift
      ;;
    --summary-only)
      SUMMARY_ONLY=true
      shift
      ;;
    --base)
      need_value "$arg" "${2-}"
      BASE="$2"
      shift 2
      ;;
    --base=*)
      BASE="${arg#--base=}"
      shift
      ;;
    --output-file)
      need_value "$arg" "${2-}"
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --output-file=*)
      OUTPUT_FILE="${arg#--output-file=}"
      shift
      ;;
    --min-confidence)
      need_value "$arg" "${2-}"
      MIN_CONFIDENCE="$2"
      shift 2
      ;;
    --min-confidence=*)
      MIN_CONFIDENCE="${arg#--min-confidence=}"
      shift
      ;;
    --no-enrich-context)
      NO_ENRICH_CONTEXT=true
      shift
      ;;
    --no-suppress)
      NO_SUPPRESS=true
      shift
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        GUIDANCE_TOKENS+=("$1")
        shift
      done
      break
      ;;
    --*)
      flag="${arg%%=*}"
      if is_removed "$flag"; then
        die "flag '$flag' was removed. $(removed_hint "$flag")"
      fi
      die "Unknown flag '$arg'."
      ;;
    *)
      GUIDANCE_TOKENS+=("$arg")
      shift
      ;;
  esac
done

GUIDANCE=""
if [[ ${#GUIDANCE_TOKENS[@]} -gt 0 ]]; then
  _san=()
  for _tok in "${GUIDANCE_TOKENS[@]}"; do
    case "$_tok" in
      *://*@*) _tok="$(printf '%s://%s' "${_tok%%://*}" "${_tok#*@}")" ;;
    esac
    _san+=("$_tok")
  done
  GUIDANCE="${_san[*]}"
  unset _san _tok
fi

if [[ "$SUMMARY_ONLY" == true && "$PROFILE_SET" == true ]]; then
  die "--summary-only and --profile are mutually exclusive."
fi

if [[ "$SUMMARY_ONLY" == true ]]; then
  PROFILE=summary
elif [[ -z "$PROFILE" ]]; then
  PROFILE=full
fi

case "$PROFILE" in
  quick|security|full|deep|summary) ;;
  *)
    die "Invalid --profile value '$PROFILE'. Valid values: quick, security, full, deep."
    ;;
esac

if [[ ! "$MIN_CONFIDENCE" =~ ^[0-9]+$ ]] || (( MIN_CONFIDENCE < 0 || MIN_CONFIDENCE > 100 )); then
  die "Invalid --min-confidence value '$MIN_CONFIDENCE'. Must be an integer 0–100."
fi

# Roster defaults: everything off.
RUN_PR_SUMMARIZER=false
RUN_CODE_REVIEWER=false
RUN_ARCHITECTURE_REVIEWER=false
RUN_SECURITY_REVIEWER=false
RUN_BLIND_HUNTER=false
RUN_EDGE_CASE_HUNTER=false
RUN_ADVERSARIAL_GENERAL=false
RUN_ISSUE_LINKER=false
RUN_SILENT_FAILURE_HUNTER=false
RUN_PR_TEST_ANALYZER=false
RUN_COMMENT_ANALYZER=false
RUN_TYPE_DESIGN_ANALYZER=false
RUN_CVE=false
RUN_STATIC_ANALYZERS=false
EXTENDED_THINKING=false
CVE_REACHABILITY=false
RUN_ENRICH_CONTEXT=false

enable_conditional_findings() {
  RUN_SILENT_FAILURE_HUNTER=conditional
  RUN_PR_TEST_ANALYZER=conditional
  RUN_COMMENT_ANALYZER=conditional
  RUN_TYPE_DESIGN_ANALYZER=conditional
}

enable_full_roster() {
  RUN_PR_SUMMARIZER=true
  RUN_CODE_REVIEWER=true
  RUN_ARCHITECTURE_REVIEWER=true
  RUN_SECURITY_REVIEWER=true
  RUN_BLIND_HUNTER=true
  RUN_EDGE_CASE_HUNTER=true
  RUN_ADVERSARIAL_GENERAL=true
  RUN_ISSUE_LINKER=true
  enable_conditional_findings
  RUN_CVE=true
  RUN_STATIC_ANALYZERS=true
  RUN_ENRICH_CONTEXT=true
}

case "$PROFILE" in
  summary)
    RUN_PR_SUMMARIZER=true
    ;;
  quick)
    RUN_PR_SUMMARIZER=true
    RUN_CODE_REVIEWER=true
    RUN_SILENT_FAILURE_HUNTER=conditional
    RUN_PR_TEST_ANALYZER=conditional
    RUN_CVE=true
    RUN_STATIC_ANALYZERS=true
    ;;
  security)
    RUN_SECURITY_REVIEWER=true
    RUN_CVE=true
    RUN_STATIC_ANALYZERS=true
    ;;
  full)
    enable_full_roster
    ;;
  deep)
    enable_full_roster
    EXTENDED_THINKING=true
    CVE_REACHABILITY=true
    ;;
esac

if [[ "$NO_ENRICH_CONTEXT" == true ]]; then
  RUN_ENRICH_CONTEXT=false
fi

# shellcheck disable=SC2016
emit() {
  printf '%s=%q\n' "$1" "$2"
}

emit PROFILE "$PROFILE"
emit GUIDANCE "$GUIDANCE"
emit SUMMARY_ONLY "$SUMMARY_ONLY"
emit BASE "$BASE"
emit OUTPUT_FILE "$OUTPUT_FILE"
emit MIN_CONFIDENCE "$MIN_CONFIDENCE"
emit NO_ENRICH_CONTEXT "$NO_ENRICH_CONTEXT"
emit NO_SUPPRESS "$NO_SUPPRESS"
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

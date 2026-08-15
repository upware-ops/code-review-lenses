#!/usr/bin/env bash
# review-diff.sh — choose the local review range.
#
# Usage:
#   bash review-diff.sh --base <ref>
#
# Output (eval-safe KEY=value):
#   REVIEW_MODE=committed|dirty|empty
#   DIFF_RANGE=<git range or ref>
#
# committed: unique commits vs base → use <base>...HEAD (do not mix in dirty files).
# dirty:     no unique commits, working tree dirty → DIFF_RANGE=$BASE
#            (orchestrator adds untracked). Never used for a PR/MR-URL
#            worktree (orchestrator skips this script there and always uses
#            <base>...HEAD).
# empty:     nothing to review (exit 1).
# exit 2:    invalid --base, option-shaped ref, or git failed.
#
# Never invents main/master/dev.

set -euo pipefail

BASE=""

die() {
  echo "Error: $*" >&2
  exit 2
}

need_value() {
  local flag="$1" value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      need_value "$1" "${2-}"
      BASE="$2"
      shift 2
      ;;
    --base=*)
      BASE="${1#--base=}"
      shift
      ;;
    *)
      die "Unknown flag '$1'."
      ;;
  esac
done

[[ -n "$BASE" ]] || die "--base is required."
case "$BASE" in
  -*)
    die "--base must be a git ref, not an option: $BASE"
    ;;
esac
if ! git rev-parse --verify "${BASE}^{commit}" >/dev/null 2>&1; then
  die "Invalid --base ref '$BASE'."
fi

emit() {
  printf '%s=%q\n' "$1" "$2"
}

committed=""
if ! committed=$(git diff --name-only "${BASE}...HEAD"); then
  die "git diff ${BASE}...HEAD failed."
fi
if [[ -n "$committed" ]]; then
  emit REVIEW_MODE committed
  emit DIFF_RANGE "${BASE}...HEAD"
  exit 0
fi

porcelain=""
if ! porcelain=$(git status --porcelain); then
  die "git status failed."
fi
if [[ -n "$porcelain" ]]; then
  emit REVIEW_MODE dirty
  emit DIFF_RANGE "$BASE"
  exit 0
fi

emit REVIEW_MODE empty
emit DIFF_RANGE ""
exit 1

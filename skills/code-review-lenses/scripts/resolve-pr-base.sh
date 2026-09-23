#!/usr/bin/env bash
# resolve-pr-base.sh — pin the compare base of a PR/MR-URL review to the target
# branch as origin has it now (never the parent clone's local branch).
#
# Usage (inside $WORKTREE_PATH, after the PR/MR head is checked out):
#   bash resolve-pr-base.sh --ref <baseRefName> [--provider-base <sha>]
#
# --provider-base: GitLab diff_refs.base_sha or GitHub baseRefOid (empty skips
# the check). merge-base(<sha>, HEAD) must equal merge-base(BASE, HEAD).
#
# Output (exit 0): BASE=<sha>
# Exit 2: missing/invalid --ref or --provider-base, shallow clone, fetch failed,
#         or merge-base mismatch. Never invents main/master/dev.

set -euo pipefail

REF=""
PROVIDER_BASE=""

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
    --ref)
      need_value "$1" "${2-}"
      REF="$2"
      shift 2
      ;;
    --ref=*)
      REF="${1#--ref=}"
      shift
      ;;
    --provider-base)
      [[ $# -ge 2 ]] || die "--provider-base requires a value (empty skips the check)."
      PROVIDER_BASE="$2"
      shift 2
      ;;
    --provider-base=*)
      PROVIDER_BASE="${1#--provider-base=}"
      shift
      ;;
    *)
      die "Unknown flag '$1'."
      ;;
  esac
done

[[ -n "$REF" ]] || die "--ref is required."
git check-ref-format "refs/heads/$REF" || die "Invalid target branch '$REF'."
if [[ -n "$PROVIDER_BASE" && ! "$PROVIDER_BASE" =~ ^[0-9a-f]{7,64}$ ]]; then
  die "--provider-base must be a commit SHA: $PROVIDER_BASE"
fi
[[ "$(git rev-parse --is-shallow-repository)" != true ]] || die "Shallow clone: the merge-base of origin/$REF and HEAD may be missing. Run: git fetch --unshallow origin"

git fetch --no-tags origin "refs/heads/$REF" || die "git fetch origin $REF failed. Pass --base <ref> to choose the compare base."
BASE=$(git rev-parse --verify 'FETCH_HEAD^{commit}') || die "Fetched origin/$REF is not a commit."

if [[ -n "$PROVIDER_BASE" ]]; then
  expected=$(git merge-base "$PROVIDER_BASE" HEAD) || die "Provider base $PROVIDER_BASE is not in the history fetched from origin/$REF."
  actual=$(git merge-base "$BASE" HEAD) || die "origin/$REF and HEAD have no common history."
  if [[ "$actual" != "$expected" ]]; then
    die "Merge-base of origin/$REF and HEAD is $actual, but the provider diffs from $expected. Pass --base <ref> to override."
  fi
fi

printf 'BASE=%q\n' "$BASE"

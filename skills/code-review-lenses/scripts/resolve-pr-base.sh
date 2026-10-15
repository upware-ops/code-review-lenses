#!/usr/bin/env bash
# resolve-pr-base.sh — pin the compare base of a PR/MR-URL review to the target
# branch as the PR/MR's repository has it now (never the parent clone's local
# branch).
#
# Usage (inside $WORKTREE_PATH, after the PR/MR head is checked out):
#   bash resolve-pr-base.sh --ref <baseRefName> [--provider-base <sha>] \
#     [--provider NAME --host HOST --repo REPO_SLUG]
#
# --provider-base: GitLab diff_refs.base_sha or GitHub baseRefOid (empty skips
# the check). merge-base(<sha>, HEAD) must equal merge-base(BASE, HEAD).
#
# --provider/--host/--repo (all three or none): the PR/MR URL's repository. The
# target branch is fetched from the first git remote (origin first) whose URL
# points at HOST/REPO_SLUG, compared case-insensitively; an http:// or git://
# remote never matches (nothing authenticates the server, so anyone on the path
# could answer the fetch). Without them it is fetched from origin.
#
# Output (exit 0): BASE=<sha>
# Exit 2: missing/invalid --ref, --provider-base, or --provider/--host/--repo,
#         no remote for HOST/REPO_SLUG, shallow clone, fetch failed, or
#         merge-base mismatch. Never invents main/master/dev.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REF=""
PROVIDER_BASE=""
PROVIDER=""
HOST=""
REPO=""

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
    --provider)
      need_value "$1" "${2-}"
      PROVIDER="$2"
      shift 2
      ;;
    --host)
      need_value "$1" "${2-}"
      HOST="$2"
      shift 2
      ;;
    --repo)
      need_value "$1" "${2-}"
      REPO="$2"
      shift 2
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

REMOTE=origin
if [[ -n "$PROVIDER$HOST$REPO" ]]; then
  [[ -n "$PROVIDER" && -n "$HOST" && -n "$REPO" ]] || die "--provider, --host and --repo must be passed together."
  case "$PROVIDER" in
    github|gitlab|bitbucket) ;;
    *) die "--provider must be github, gitlab, or bitbucket." ;;
  esac

  target=$(printf '%s/%s' "$HOST" "$REPO" | tr '[:upper:]' '[:lower:]')
  REMOTE=""
  for name in origin $(git remote | grep -vx origin); do
    url=$(git remote get-url "$name" 2>/dev/null) || continue
    out=$(bash "$SCRIPT_DIR/detect-provider.sh" --provider "$PROVIDER" --authenticated-transport --remote-url "$url" 2>/dev/null) || continue
    found=$(eval "$out"; printf '%s/%s' "$HOST" "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')
    if [[ "$found" == "$target" ]]; then
      REMOTE="$name"
      break
    fi
  done
  [[ -n "$REMOTE" ]] || die "No git remote points at https://$HOST/$REPO. Run: git remote add <name> https://$HOST/$REPO.git, or pass --base <ref> to choose the compare base."
fi

[[ "$(git rev-parse --is-shallow-repository)" != true ]] || die "Shallow clone: the merge-base of $REMOTE/$REF and HEAD may be missing. Run: git fetch --unshallow $REMOTE"

# A relative core.hooksPath resolves inside the PR worktree, so its reference-transaction hook would be the PR author's.
_fetch=(git -c core.hooksPath=/dev/null)
[[ "$PROVIDER" != github ]] || _fetch+=(-c "credential.https://$HOST.helper=!gh auth git-credential")
"${_fetch[@]}" fetch --no-tags "$REMOTE" "refs/heads/$REF" || die "git fetch $REMOTE $REF failed. Pass --base <ref> to choose the compare base."
BASE=$(git rev-parse --verify 'FETCH_HEAD^{commit}') || die "Fetched $REMOTE/$REF is not a commit."

if [[ -n "$PROVIDER_BASE" ]]; then
  expected=$(git merge-base "$PROVIDER_BASE" HEAD) || die "Provider base $PROVIDER_BASE is not in the history fetched from $REMOTE/$REF."
  actual=$(git merge-base "$BASE" HEAD) || die "$REMOTE/$REF and HEAD have no common history."
  if [[ "$actual" != "$expected" ]]; then
    die "Merge-base of $REMOTE/$REF and HEAD is $actual, but the provider diffs from $expected. Pass --base <ref> to override."
  fi
fi

printf 'BASE=%q\n' "$BASE"

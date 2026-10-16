#!/usr/bin/env bash
# review-diff.sh — choose the local review range.
#
# Usage:
#   bash review-diff.sh --base <ref> [--diff-file <path>]
#
# Output (eval-safe KEY=value):
#   REVIEW_MODE=committed|dirty|empty
#   DIFF_RANGE=<git range or ref>
#
# committed: unique commits vs base → use <base>...HEAD (do not mix in dirty files).
# dirty:     no unique commits, working tree dirty → DIFF_RANGE=$BASE.
#            Never used for a PR/MR-URL worktree (orchestrator skips this
#            script there and always uses <base>...HEAD).
# empty:     nothing to review (exit 1).
# exit 2:    invalid --base, option-shaped ref, or git failed.
#
# --diff-file <path>: also write the diff for REVIEW_MODE to <path> (nothing
#            when empty). dirty = tracked changes vs $BASE plus every untracked
#            file and symlink, rendered from a temporary copy of the index so
#            the real index is never touched.
#
# Never invents main/master/dev.

set -euo pipefail

BASE=""
DIFF_FILE=""

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
    --diff-file)
      need_value "$1" "${2-}"
      DIFF_FILE="$2"
      shift 2
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

write_dirty_diff() {
  # In the git dir, not TMPDIR: untracked listing skips .git but not a TMPDIR inside the checkout.
  git_dir=$(git rev-parse --absolute-git-dir) || die "Cannot resolve the git dir."
  INDEX_DIR=$(mktemp -d "$git_dir/review-diff.XXXXXX") || die "mktemp failed."
  trap 'rm -rf "$INDEX_DIR"' EXIT

  cp "$(git rev-parse --git-path index)" "$INDEX_DIR/index" || die "Cannot copy the git index."

  # xargs -r: GNU xargs runs git once on empty input, BSD xargs never does.
  # Files and symlinks only: untracked nested repos list as "dir/" and git add would embed them.
  # Not the diff file: inside the checkout it lists as untracked and the redirect below truncates it.
  git ls-files -z --others --exclude-standard \
    | while IFS= read -r -d '' path; do
        if [[ ( -f "$path" || -L "$path" ) && ! "$path" -ef "$DIFF_FILE" ]]; then
          printf '%s\0' "$path"
        fi
      done \
    | GIT_LITERAL_PATHSPECS=1 GIT_INDEX_FILE="$INDEX_DIR/index" xargs -0 -r git add -N -- \
    || die "Cannot add untracked files to the temporary index."

  GIT_INDEX_FILE="$INDEX_DIR/index" git diff "$BASE" > "$DIFF_FILE" || die "git diff $BASE failed."
}

committed=""
if ! committed=$(git diff --name-only "${BASE}...HEAD"); then
  die "git diff ${BASE}...HEAD failed."
fi
if [[ -n "$committed" ]]; then
  if [[ -n "$DIFF_FILE" ]]; then
    git diff "${BASE}...HEAD" > "$DIFF_FILE" || die "git diff ${BASE}...HEAD failed."
  fi

  emit REVIEW_MODE committed
  emit DIFF_RANGE "${BASE}...HEAD"
  exit 0
fi

porcelain=""
if ! porcelain=$(git status --porcelain); then
  die "git status failed."
fi
if [[ -n "$porcelain" ]]; then
  if [[ -n "$DIFF_FILE" ]]; then
    write_dirty_diff
  fi

  emit REVIEW_MODE dirty
  emit DIFF_RANGE "$BASE"
  exit 0
fi

emit REVIEW_MODE empty
emit DIFF_RANGE ""
exit 1

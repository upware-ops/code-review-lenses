#!/usr/bin/env bats
# Drive shipped review-diff.sh: committed vs dirty vs empty.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  REVIEW="${SCRIPTS_DIR}/review-diff.sh"
  WORK=$(mktemp -d)
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@t
  git -C "$WORK" config user.name t
  git -C "$WORK" config gc.auto 0
  echo a > "$WORK/a"
  git -C "$WORK" add a
  git -C "$WORK" commit -qm init
  git -C "$WORK" branch -M main
  git -C "$WORK" checkout -qb feature
}

teardown() {
  # macOS APFS: a just-packed .git/objects can refuse unlink once.
  if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
    chmod -R u+w "$WORK" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || {
      sleep 0.2
      rm -rf "$WORK" || true
    }
  fi
}

@test "review-diff: empty when HEAD equals base and tree is clean" {
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'REVIEW_MODE=empty'
}

@test "review-diff: dirty when HEAD equals base and working tree has changes" {
  echo dirty > "$WORK/a"
  eval "$(cd "$WORK" && bash "$REVIEW" --base main)"
  [[ "$REVIEW_MODE" == "dirty" ]]
  [[ "$DIFF_RANGE" == "main" ]]
}

@test "review-diff: committed when feature has a unique commit" {
  echo b >> "$WORK/a"
  git -C "$WORK" add a
  git -C "$WORK" commit -qm feat
  eval "$(cd "$WORK" && bash "$REVIEW" --base main)"
  [[ "$REVIEW_MODE" == "committed" ]]
  [[ "$DIFF_RANGE" == "main...HEAD" ]]
}

@test "review-diff: unique commits win over a dirty working tree" {
  echo b >> "$WORK/a"
  git -C "$WORK" add a
  git -C "$WORK" commit -qm feat
  echo dirtied >> "$WORK/a"
  eval "$(cd "$WORK" && bash "$REVIEW" --base main)"
  [[ "$REVIEW_MODE" == "committed" ]]
  [[ "$DIFF_RANGE" == "main...HEAD" ]]
}

@test "review-diff: untracked-only working tree is dirty" {
  echo x > "$WORK/new"
  eval "$(cd "$WORK" && bash "$REVIEW" --base main)"
  [[ "$REVIEW_MODE" == "dirty" ]]
  [[ "$DIFF_RANGE" == "main" ]]
}

@test "review-diff: unknown ref is exit 2, not empty" {
  run bash -c "cd '$WORK' && bash '$REVIEW' --base not-a-ref"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid --base ref"* ]]
}

@test "review-diff: option-shaped --base is exit 2 and writes no file" {
  run bash -c "cd '$WORK' && bash '$REVIEW' --base=--output=/tmp/crl-review-diff-pwned"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not an option"* ]]
  [[ ! -e /tmp/crl-review-diff-pwned ]]
  [[ ! -e /tmp/crl-review-diff-pwned...HEAD ]]
}

#!/usr/bin/env bats
# Drive shipped resolve-pr-base.sh: a PR/MR-URL compare base comes from origin,
# never the parent clone's (possibly stale) local branch of the same name.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  RESOLVE="${SCRIPTS_DIR}/resolve-pr-base.sh"
  WORK=$(mktemp -d)

  git init -q --bare "$WORK/origin.git"
  git init -q "$WORK/pusher"
  git -C "$WORK/pusher" config user.email t@t
  git -C "$WORK/pusher" config user.name t
  git -C "$WORK/pusher" config gc.auto 0
  git -C "$WORK/pusher" remote add origin "$WORK/origin.git"
  git -C "$WORK/pusher" checkout -qb release/x
  commit_file a
  A=$(git -C "$WORK/pusher" rev-parse HEAD)
  git -C "$WORK/pusher" push -q origin release/x

  # Parent clone: local release/x stays at A while origin moves on.
  git clone -q -b release/x "$WORK/origin.git" "$WORK/parent"

  # origin: release/x = A-B-D, feature = A-B-F (merge-base B).
  commit_file b
  B=$(git -C "$WORK/pusher" rev-parse HEAD)
  git -C "$WORK/pusher" checkout -qb feature
  commit_file f
  git -C "$WORK/pusher" checkout -q release/x
  commit_file d
  D=$(git -C "$WORK/pusher" rev-parse HEAD)
  git -C "$WORK/pusher" push -q origin release/x feature

  # URL review: temporary worktree off the parent with the PR/MR head checked out.
  WT="$WORK/wt"
  git -C "$WORK/parent" worktree add -q --detach "$WT"
  git -C "$WT" fetch -q origin feature
  git -C "$WT" checkout -q --detach FETCH_HEAD
}

commit_file() {
  echo "$1" > "$WORK/pusher/$1"
  git -C "$WORK/pusher" add "$1"
  git -C "$WORK/pusher" commit -qm "$1"
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

@test "resolve-pr-base: stale local target branch is not the compare base" {
  [[ "$(git -C "$WT" rev-parse release/x)" == "$A" ]]
  [[ "$(git -C "$WT" diff --name-only release/x...HEAD | tr '\n' ' ')" == "b f " ]]

  eval "$(cd "$WT" && bash "$RESOLVE" --ref release/x)"
  [[ "$BASE" == "$D" ]]
  [[ "$(git -C "$WT" diff --name-only "${BASE}...HEAD")" == "f" ]]
}

@test "resolve-pr-base: provider merge-base (GitLab) or target tip (GitHub) must agree" {
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base '$B'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base '$D'"
  [ "$status" -eq 0 ]
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base ''"
  [ "$status" -eq 0 ]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base '$A'"
  [[ "$output" == *"the provider diffs from $A"* ]]
}

@test "resolve-pr-base: provider base missing from fetched history is exit 2" {
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base 0123456789abcdef0123456789abcdef01234567"
  [[ "$output" == *"not in the history fetched from origin/release/x"* ]]
}

@test "resolve-pr-base: shallow clone is exit 2 with an unshallow hint" {
  git clone -q --depth 1 -b release/x "file://$WORK/origin.git" "$WORK/shallow"
  run -2 bash -c "cd '$WORK/shallow' && bash '$RESOLVE' --ref release/x"
  [[ "$output" == *"git fetch --unshallow"* ]]
}

@test "resolve-pr-base: refspec-shaped or missing target and non-SHA provider base are exit 2" {
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref 'feature:refs/heads/release/x'"
  [[ "$output" == *"Invalid target branch"* ]]
  [[ "$(git -C "$WORK/parent" rev-parse release/x)" == "$A" ]]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref no-such-branch"
  [[ "$output" == *"git fetch origin no-such-branch failed"* ]]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base --all"
  [[ "$output" == *"must be a commit SHA"* ]]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE'"
  [[ "$output" == *"--ref is required"* ]]
}

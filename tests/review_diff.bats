#!/usr/bin/env bats
# Drive shipped review-diff.sh: committed vs dirty vs empty.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  REVIEW="${SCRIPTS_DIR}/review-diff.sh"
  WORK=$(mktemp -d)
  OUT="$BATS_TEST_TMPDIR/review.diff"
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

@test "review-diff: --diff-file in dirty mode has tracked changes, untracked files and both symlink kinds" {
  echo changed > "$WORK/a"
  echo hello > "$WORK/new.txt"
  ln -s /nonexistent/secret "$WORK/broken"
  ln -s "$BATS_TEST_TMPDIR" "$WORK/dirlink"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  [ "$output" = $'REVIEW_MODE=dirty\nDIFF_RANGE=main' ]
  grep -qxF '+changed' "$OUT"
  grep -qxF 'diff --git a/new.txt b/new.txt' "$OUT"
  grep -qxF '+hello' "$OUT"
  grep -A1 -xF 'diff --git a/broken b/broken' "$OUT" | grep -qxF 'new file mode 120000'
  grep -qxF '+/nonexistent/secret' "$OUT"
  grep -A1 -xF 'diff --git a/dirlink b/dirlink' "$OUT" | grep -qxF 'new file mode 120000'
  grep -qxF "+$BATS_TEST_TMPDIR" "$OUT"
}

@test "review-diff: --diff-file leaves the real index and status untouched and no temp dir in the git dir" {
  echo hello > "$WORK/new.txt"
  ln -s /nonexistent/secret "$WORK/broken"
  git -C "$WORK" status --porcelain > "$BATS_TEST_TMPDIR/status.before"
  git -C "$WORK" ls-files --stage > "$BATS_TEST_TMPDIR/stage.before"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  grep -qxF 'diff --git a/new.txt b/new.txt' "$OUT"
  git -C "$WORK" status --porcelain | cmp - "$BATS_TEST_TMPDIR/status.before"
  git -C "$WORK" ls-files --stage | cmp - "$BATS_TEST_TMPDIR/stage.before"
  git -C "$WORK" diff --cached --quiet
  [ -z "$(find "$WORK/.git" -name 'review-diff.*')" ]
}

@test "review-diff: --diff-file without untracked files is exactly git diff <base> and runs no empty git add" {
  echo changed > "$WORK/a"
  run --separate-stderr bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  git -C "$WORK" diff main | cmp - "$OUT"
}

@test "review-diff: --diff-file keeps untracked names with spaces, newlines, a leading colon and glob characters" {
  echo SPACE > "$WORK/with space.txt"
  echo NEWLINE > "$WORK/$(printf 'two\nlines.txt')"
  echo COLON > "$WORK/:colon"
  echo GLOB > "$WORK/g[1].txt"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  grep -qxF '+SPACE' "$OUT"
  grep -qxF '+NEWLINE' "$OUT"
  grep -qxF '+COLON' "$OUT"
  grep -qxF '+GLOB' "$OUT"
}

@test "review-diff: --diff-file skips an untracked nested repo without noise" {
  git init -q "$WORK/nested"
  git -C "$WORK/nested" -c user.email=t@t -c user.name=t commit -q --allow-empty -m n
  echo hello > "$WORK/new.txt"
  run --separate-stderr bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  grep -qxF '+hello' "$OUT"
  [ "$(grep -c nested "$OUT")" -eq 0 ]
}

@test "review-diff: --diff-file in committed mode writes <base>...HEAD and leaves the stdout contract alone" {
  echo b >> "$WORK/a"
  git -C "$WORK" add a
  git -C "$WORK" commit -qm feat
  echo dirtied >> "$WORK/a"
  ln -s /nonexistent/secret "$WORK/broken"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main"
  [ "$output" = $'REVIEW_MODE=committed\nDIFF_RANGE=main...HEAD' ]
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  [ "$output" = $'REVIEW_MODE=committed\nDIFF_RANGE=main...HEAD' ]
  git -C "$WORK" diff main...HEAD | cmp - "$OUT"
}

@test "review-diff: --diff-file writes nothing when empty" {
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
}

@test "review-diff: --diff-file works from a subdirectory" {
  mkdir "$WORK/sub"
  echo hello > "$WORK/sub/new.txt"
  ln -s /nonexistent/secret "$WORK/sub/broken"
  run bash -c "cd '$WORK/sub' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  grep -qxF 'diff --git a/sub/new.txt b/sub/new.txt' "$OUT"
  grep -A1 -xF 'diff --git a/sub/broken b/sub/broken' "$OUT" | grep -qxF 'new file mode 120000'
}

@test "review-diff: --diff-file works from a linked worktree and leaves no temp dir behind" {
  git -C "$WORK" worktree add -q -b wt "$BATS_TEST_TMPDIR/wt" main
  echo hello > "$BATS_TEST_TMPDIR/wt/new.txt"
  run bash -c "cd '$BATS_TEST_TMPDIR/wt' && bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 0 ]
  grep -qxF '+hello' "$OUT"
  [ -z "$(find "$WORK/.git" -name 'review-diff.*')" ]
}

@test "review-diff: an unwritable --diff-file is exit 2, emits nothing and leaves no temp index" {
  echo hello > "$WORK/new.txt"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$BATS_TEST_TMPDIR/missing/out.diff'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Error:"* ]]
  [[ "$output" != *REVIEW_MODE* ]]
  [ -z "$(find "$WORK/.git" -name 'review-diff.*')" ]
}

@test "review-diff: a failing git add is exit 2, emits nothing and leaves no temp index" {
  echo hello > "$WORK/new.txt"
  mkdir "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" <<STUB
#!/bin/sh
[ "\$1" = add ] && { printf '%s\n' "\$GIT_INDEX_FILE" > '$BATS_TEST_TMPDIR/index_file'; exit 1; }
exec '$(command -v git)' "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\$PATH bash '$REVIEW' --base main --diff-file '$OUT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Error: Cannot add untracked files"* ]]
  [[ "$output" != *REVIEW_MODE* ]]
  [[ "$(cat "$BATS_TEST_TMPDIR/index_file")" == */.git/review-diff.*/index ]]
  [ -z "$(find "$WORK/.git" -name 'review-diff.*')" ]
}

@test "review-diff: --diff-file pre-created inside the checkout is not diffed as its own untracked input" {
  echo changed > "$WORK/a"
  echo hello > "$WORK/new.txt"
  : > "$WORK/self.diff"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$WORK/self.diff'"
  [ "$status" -eq 0 ]
  grep -qxF '+changed' "$WORK/self.diff"
  grep -qxF 'diff --git a/new.txt b/new.txt' "$WORK/self.diff"
  [ "$(grep -cF self.diff "$WORK/self.diff")" -eq 0 ]
}

@test "review-diff: --diff-file inside the checkout is excluded however its path is spelled" {
  mkdir "$WORK/sub"
  echo hello > "$WORK/new.txt"
  : > "$WORK/sub/self.diff"
  ln -s "$WORK" "$BATS_TEST_TMPDIR/link"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$BATS_TEST_TMPDIR/link/sub/self.diff'"
  [ "$status" -eq 0 ]
  grep -qxF '+hello' "$WORK/sub/self.diff"
  [ "$(grep -cF self.diff "$WORK/sub/self.diff")" -eq 0 ]
}

@test "review-diff: --diff-file inside the checkout that does not exist yet is written normally" {
  echo hello > "$WORK/new.txt"
  run bash -c "cd '$WORK' && bash '$REVIEW' --base main --diff-file '$WORK/self.diff'"
  [ "$status" -eq 0 ]
  grep -qxF '+hello' "$WORK/self.diff"
  [ "$(grep -cF self.diff "$WORK/self.diff")" -eq 0 ]
}

@test "review-diff: with TMPDIR inside the checkout neither the diff file nor the temp index reaches the diff" {
  echo changed > "$WORK/a"
  mkdir "$WORK/.tmp"
  diff_file=$(mktemp "$WORK/.tmp/diff.XXXXXX")
  run bash -c "cd '$WORK' && TMPDIR='$WORK/.tmp' bash '$REVIEW' --base main --diff-file '$diff_file'"
  [ "$status" -eq 0 ]
  grep -qxF '+changed' "$diff_file"
  [ "$(grep -cF review-diff. "$diff_file")" -eq 0 ]
  git -C "$WORK" diff main | cmp - "$diff_file"
}

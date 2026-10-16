#!/usr/bin/env bats
# Drive shipped resolve-pr-base.sh: a PR/MR-URL compare base comes from the remote
# that owns the PR/MR repository (origin by default), never the parent clone's
# (possibly stale) local branch of the same name.

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

# git remote get-url expands insteadOf, so hosted-looking remote URLs are served by a fake ssh
# (user-level url.*.insteadOf is ignored so nothing can reroute them to the network).
hosted_remotes() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export FAKE_SSH_ROOT="$WORK/ssh" GIT_SSH_COMMAND="$WORK/fake-ssh" GIT_SSH_VARIANT=simple
  cat > "$WORK/fake-ssh" <<'EOF'
#!/bin/sh
cd "$FAKE_SSH_ROOT/$1" && exec sh -c "$2"
EOF
  chmod +x "$WORK/fake-ssh"

  mkdir -p "$WORK/ssh/git@github.com/acme" "$WORK/ssh/git@github.com/me"
  git clone -q --bare "$WORK/origin.git" "$WORK/ssh/git@github.com/acme/app.git"
  git clone -q --bare "$WORK/parent" "$WORK/ssh/git@github.com/me/app.git"
  git -C "$WORK/parent" remote set-url origin git@github.com:me/app.git
  git -C "$WORK/parent" remote add upstream git@github.com:acme/app.git
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

@test "resolve-pr-base: --provider/--host/--repo fetch from the remote that owns the PR/MR repository" {
  hosted_remotes

  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$A"* ]]
}

@test "resolve-pr-base: messages name the matched remote" {
  hosted_remotes

  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref no-such-branch --provider github --host github.com --repo acme/app"
  [[ "$output" == *"git fetch upstream no-such-branch failed"* ]]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider-base '$A' --provider github --host github.com --repo acme/app"
  [[ "$output" == *"Merge-base of upstream/release/x and HEAD"* ]]
  git clone -q --depth 1 -b release/x "file://$WORK/origin.git" "$WORK/shallow"
  git -C "$WORK/shallow" remote add upstream git@github.com:acme/app.git
  run -2 bash -c "cd '$WORK/shallow' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/app"
  [[ "$output" == *"git fetch --unshallow upstream"* ]]
}

@test "resolve-pr-base: remote match ignores case and prefers origin over an earlier-sorting remote" {
  hosted_remotes

  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host GitHub.COM --repo ACME/App"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]

  mkdir -p "$WORK/ssh/git@GitHub.com/Acme"
  git clone -q --bare "$WORK/origin.git" "$WORK/ssh/git@GitHub.com/Acme/Lib.git"
  git -C "$WORK/parent" remote add mixed git@GitHub.com:Acme/Lib.git
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/lib"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]

  mkdir -p "$WORK/ssh/other@github.com/me"
  git clone -q --bare "$WORK/origin.git" "$WORK/ssh/other@github.com/me/app.git"
  git -C "$WORK/parent" remote add aaa other@github.com:me/app.git
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo me/app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$A"* ]]

  git -C "$WORK/parent" remote remove origin
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo me/app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]
}

@test "resolve-pr-base: a www.github.com remote matches the github.com repository of a PR URL" {
  hosted_remotes

  mkdir -p "$WORK/ssh/git@www.github.com/acme"
  git clone -q --bare "$WORK/origin.git" "$WORK/ssh/git@www.github.com/acme/web.git"
  git -C "$WORK/parent" remote add www git@www.github.com:acme/web.git
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/web"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]
}

@test "resolve-pr-base: a GitHub base fetch can use the gh login through gh's git credential helper, other providers' cannot" {
  hosted_remotes
  real_git=$(command -v git)
  mkdir -p "$WORK/gitlog-bin"
  cat > "$WORK/gitlog-bin/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/git.log"
exec "$real_git" "\$@"
EOF
  chmod +x "$WORK/gitlog-bin/git"

  run bash -c "cd '$WT' && PATH='$WORK/gitlog-bin':\"\$PATH\" bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/app"
  [ "$status" -eq 0 ]
  grep -qF -- '-c core.hooksPath=/dev/null -c credential.https://github.com.helper=!gh auth git-credential fetch --no-tags upstream refs/heads/release/x' "$WORK/git.log"

  mkdir -p "$WORK/ssh/git@git.example.test/group"
  git clone -q --bare "$WORK/origin.git" "$WORK/ssh/git@git.example.test/group/proj.git"
  git -C "$WORK/parent" remote add gl git@git.example.test:group/proj.git
  : > "$WORK/git.log"
  run bash -c "cd '$WT' && PATH='$WORK/gitlog-bin':\"\$PATH\" bash '$RESOLVE' --ref release/x --provider gitlab --host git.example.test --repo group/proj"
  [ "$status" -eq 0 ]
  grep -qF -- '-c core.hooksPath=/dev/null fetch --no-tags gl refs/heads/release/x' "$WORK/git.log"
  if grep -qF 'credential.' "$WORK/git.log"; then
    echo "REGRESSION: a non-GitHub fetch got gh's credential helper" >&2
    return 1
  fi
}

@test "resolve-pr-base: a GitLab nested-group project matches on a self-hosted host" {
  hosted_remotes

  mkdir -p "$WORK/ssh/git@git.example.test/group/sub"
  git clone -q --bare "$WORK/origin.git" "$WORK/ssh/git@git.example.test/group/sub/proj.git"
  git -C "$WORK/parent" remote add gl git@git.example.test:group/sub/proj.git
  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider gitlab --host git.example.test --repo group/sub/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]
}

@test "resolve-pr-base: no remote for the PR/MR repository, or a bad flag group, is exit 2" {
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/app"
  [[ "$output" == *"No git remote points at https://github.com/acme/app"* ]]
  [[ "$output" == *"git remote add <name> https://github.com/acme/app.git"* ]]
  [[ "$output" == *"--base <ref>"* ]]

  hosted_remotes
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host ghe.example.test --repo acme/app"
  [[ "$output" == *"No git remote points at https://ghe.example.test/acme/app"* ]]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/other"
  [[ "$output" == *"No git remote points at https://github.com/acme/other"* ]]

  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --host github.com"
  [[ "$output" == *"--provider, --host and --repo must be passed together"* ]]
  run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider svn --host github.com --repo acme/app"
  [[ "$output" == *"--provider must be github, gitlab, or bitbucket"* ]]
}

@test "resolve-pr-base: an http:// or git:// remote never matches the PR/MR repository, an https:// or ssh:// one does" {
  # git refuses a transport outside this list before any network access, so a regression fails here instead of fetching
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_ALLOW_PROTOCOL=file

  for url in http://git.example.test/acme/app.git git://git.example.test/acme/app.git; do
    git -C "$WORK/parent" remote set-url origin "$url"
    run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host git.example.test --repo acme/app"
    [[ "$output" == *"No git remote points at https://git.example.test/acme/app"* ]] || return 1
  done

  for url in https://git.example.test/acme/app.git ssh://git@git.example.test/acme/app.git; do
    git -C "$WORK/parent" remote set-url origin "$url"
    run -2 bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host git.example.test --repo acme/app"
    [[ "$output" == *"git fetch origin release/x failed"* ]] || return 1
  done
}

@test "resolve-pr-base: plaintext remotes of the PR/MR repository are skipped for an authenticated one" {
  hosted_remotes
  export GIT_ALLOW_PROTOCOL=ssh:file
  git -C "$WORK/parent" remote set-url origin http://github.com/acme/app.git
  git -C "$WORK/parent" remote add aaa git://github.com/acme/app.git

  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x --provider github --host github.com --repo acme/app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=$D"* ]]
}

@test "resolve-pr-base: its fetch runs no hook of the PR worktree's own relative core.hooksPath" {
  git -C "$WORK/parent" config core.hooksPath .githooks
  mkdir "$WT/.githooks"
  printf '#!/bin/sh\ntouch "%s/ran"\n' "$WORK" > "$WT/.githooks/reference-transaction"
  chmod +x "$WT/.githooks/reference-transaction"
  git -C "$WORK/pusher" push -q origin release/x:refs/heads/probe

  git -C "$WT" fetch -q --no-tags origin probe
  [ -e "$WORK/ran" ]
  rm "$WORK/ran"

  run bash -c "cd '$WT' && bash '$RESOLVE' --ref release/x"
  [ "$status" -eq 0 ]
  grep -qF "BASE=$D" <<<"$output"
  [ ! -e "$WORK/ran" ]
}

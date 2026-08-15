# Provider Operations Reference

Read-only operations used when a PR/MR URL is checked out for local analysis.
This pipeline never creates, comments on, or reviews a PR/MR. Host and number
come from the URL (`parse-pr-url.sh`), not from `--pr` / `--provider`.

The following operations are referenced by name from SKILL.md. Use the command
for the detected `PROVIDER`. GitLab commands go through `glab` and work for
any host that CLI is authenticated to (`glab auth login --hostname <host>`).

## OP: Fetch PR/MR metadata

Returns JSON mapped to: `number`, `title`, `baseRefName`, `headRefName`, `state`, `body`.

Run `detect-provider.sh --check-url-host --provider "$PROVIDER" --host "$HOST"` before any `gh` / `glab` OP. GitHub: github.com / `*.github.com` / `*.ghe.com` or `gh auth status` (origin match is not enough). GitLab: `GITLAB_HOST` / `GL_HOST` or `glab auth status` (origin match is not enough). Refuse rather than send env tokens to an unknown host.

- **github:** `GH_HOST="$HOST" gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json number,title,baseRefName,headRefName,state,body`. Map `body` to canonical `body`. Always pin `GH_HOST` and `--repo` to the URL-parsed host/slug (including GitHub Enterprise).
- **gitlab:** After `--check-url-host` succeeds: `glab --hostname "$HOST" -R "$REPO_SLUG" mr view <N> --output json` (fields: iid, title, source_branch, target_branch, state, description). Map: iid→number, target_branch→baseRefName, source_branch→headRefName, description→body. State values: "opened"→OPEN, "closed"→CLOSED, "merged"→MERGED. If state is unrecognized, warn "Unrecognized MR state '<value>' — proceeding as OPEN." and treat as OPEN. Always pass `--hostname` and `-R` so a non-default `glab` host is the one invoked.
- **bitbucket:** `curl -sf --user "${BITBUCKET_EMAIL}:${BITBUCKET_TOKEN}" "https://api.bitbucket.org/2.0/repositories/${REPO_SLUG}/pullrequests/<N>"`. Map: id→number, destination.branch.name→baseRefName, source.branch.name→headRefName, description→body. State values: "OPEN", "DECLINED"→CLOSED, "MERGED".

If the provider response has no body/description or the value is null/empty, set `body=""`. Do not error.

## OP: Checkout PR/MR branch into `$WORKTREE_PATH`

Run every command **inside** the temporary worktree created in Phase 0b. Do not checkout in the parent clone.

- **github:** `(cd "$WORKTREE_PATH" && GH_HOST="$HOST" gh pr checkout "$PR_NUMBER" --repo "$REPO_SLUG")`
- **gitlab:** Same host-auth check as fetch, then `(cd "$WORKTREE_PATH" && glab --hostname "$HOST" -R "$REPO_SLUG" mr checkout <N>)`
- **bitbucket:** Extract source branch name from PR metadata, then `git -C "$WORKTREE_PATH" fetch origin <branch> && git -C "$WORKTREE_PATH" checkout FETCH_HEAD`

## GitLab host notes

`detect-provider.sh` treats a remote as GitLab when the hostname is `gitlab.com`,
contains `gitlab`, equals `GITLAB_HOST`/`GL_HOST` (URL form is stripped to a
hostname), equals `glab config get host`, or appears on `glab auth status` stdout
(non-zero exit is not a match). Nested groups stay in `REPO_SLUG` (`group/sub/project`).
Every `glab` OP above pins `--hostname "$HOST" -R "$REPO_SLUG"`.
`glab` must already be logged in to that host; this skill does not run `glab auth login`.

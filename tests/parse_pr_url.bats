#!/usr/bin/env bats
# Drive the shipped parse-pr-url.sh. A number is never a PR identity.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  PARSE="${SCRIPTS_DIR}/parse-pr-url.sh"
}

source_url() {
  eval "$(bash "$PARSE" "$@")"
}

@test "parse-pr-url: GitHub pull URL" {
  source_url "review https://github.com/acme/app/pull/42 focus on auth"
  [[ "$PROVIDER" == "github" ]]
  [[ "$HOST" == "github.com" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
  [[ "$PR_NUMBER" == "42" ]]
  [[ "$CLI_TOOL" == "gh" ]]
}

@test "parse-pr-url: GitLab nested group on any host" {
  source_url "https://git.example.com/group/sub/proj/-/merge_requests/7"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$HOST" == "git.example.com" ]]
  [[ "$REPO_SLUG" == "group/sub/proj" ]]
  [[ "$PR_NUMBER" == "7" ]]
  [[ "$PR_TERM" == "MR" ]]
  [[ "$CLI_TOOL" == "glab" ]]
}

@test "parse-pr-url: Bitbucket pull-requests URL" {
  source_url "https://bitbucket.org/team/repo/pull-requests/9/overview"
  [[ "$PROVIDER" == "bitbucket" ]]
  [[ "$HOST" == "bitbucket.org" ]]
  [[ "$REPO_SLUG" == "team/repo" ]]
  [[ "$PR_NUMBER" == "9" ]]
  [[ "$CLI_TOOL" == "curl" ]]
}

@test "parse-pr-url: non-Cloud Bitbucket URL is exit 2" {
  run -2 bash "$PARSE" "https://bitbucket.example.com/team/repo/pull-requests/9"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Bitbucket Cloud only"* ]]
  if echo "$output" | grep -q '^PROVIDER='; then
    echo "REGRESSION: refused Bitbucket URL still emitted PROVIDER=" >&2
    return 1
  fi
}

@test "parse-pr-url: www.github.com is normalized to github.com" {
  source_url "https://oauth2:s3cret@WWW.GitHub.com/acme/app/pull/42"
  [[ "$HOST" == "github.com" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
  run -2 bash "$PARSE" "http://www.github.com/acme/app/pull/42"
  [[ "$output" == *"refused http:// PR/MR URL"* ]]
}

@test "parse-pr-url: GitHub Enterprise /pull/ on a custom host" {
  source_url "https://git.company.com/org/repo/pull/42/files"
  [[ "$PROVIDER" == "github" ]]
  [[ "$HOST" == "git.company.com" ]]
  [[ "$REPO_SLUG" == "org/repo" ]]
  [[ "$PR_NUMBER" == "42" ]]
}

@test "parse-pr-url: number-only is not a complete PR identity" {
  run bash "$PARSE" "42"
  [ "$status" -eq 1 ]
  [[ "$output" != *"PR_NUMBER="* ]]
  run bash "$PARSE" "pr 42"
  [ "$status" -eq 1 ]
  [[ "$output" != *"PR_NUMBER="* ]]
}

@test "parse-pr-url: no URL is exit 1 (local review)" {
  run bash "$PARSE" "focus on tokens"
  [ "$status" -eq 1 ]
}

@test "parse-pr-url: scheme-less github.com paste" {
  source_url "github.com/acme/app/pull/42"
  [[ "$PROVIDER" == "github" ]]
  [[ "$HOST" == "github.com" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
  [[ "$PR_NUMBER" == "42" ]]
}

@test "parse-pr-url: GitHub /pulls/N on github.com" {
  source_url "https://github.com/acme/app/pulls/3"
  [[ "$PROVIDER" == "github" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
  [[ "$PR_NUMBER" == "3" ]]
}

@test "parse-pr-url: GitLab merge_requests without /-/ " {
  source_url "https://gitlab.com/g/p/merge_requests/8"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$REPO_SLUG" == "g/p" ]]
  [[ "$PR_NUMBER" == "8" ]]
}

@test "parse-pr-url: first matching PR/MR URL wins" {
  source_url "see https://example.com/blog and https://github.com/acme/app/pull/42"
  [[ "$PR_NUMBER" == "42" ]]
  [[ "$HOST" == "github.com" ]]
}

@test "parse-pr-url: strips query fragment and userinfo from PR_URL" {
  source_url "https://oauth2:s3cret-token@github.com/acme/app/pull/42?foo=1#discussion"
  [[ "$PR_NUMBER" == "42" ]]
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
  [[ "$PR_URL" != *s3cret-token* ]]
  [[ "$PR_URL" != *oauth2:* ]]
  [[ "$HOST" == "github.com" ]]
}

@test "parse-pr-url: GUIDANCE_REST drops the URL and any leftover userinfo" {
  source_url "https://oauth2:s3cret-token@github.com/acme/app/pull/42 focus on auth"
  [[ "$GUIDANCE_REST" == "focus on auth" ]]
  [[ "$GUIDANCE_REST" != *s3cret-token* ]]
}

@test "parse-pr-url: GUIDANCE_REST leftover glob stays literal" {
  WORK=$(mktemp -d)
  touch "$WORK/secret.pem" "$WORK/other.pem"
  eval "$(cd "$WORK" && bash "$PARSE" "https://github.com/acme/app/pull/42 review *.pem")"
  [[ "$GUIDANCE_REST" == "review *.pem" ]]
  [[ "$GUIDANCE_REST" != *secret.pem* ]]
  rm -rf "$WORK"
}

@test "parse-pr-url: stdin GUIDANCE works" {
  eval "$(printf '%s' "https://github.com/acme/app/pull/11" | bash "$PARSE")"
  [[ "$PR_NUMBER" == "11" ]]
}

@test "parse-pr-url: issues and pull/0 are not identities" {
  run bash "$PARSE" "https://github.com/acme/app/issues/42"
  [ "$status" -eq 1 ]
  run bash "$PARSE" "https://github.com/acme/app/pull/0"
  [ "$status" -eq 1 ]
}

@test "parse-pr-url: javascript: and api.github.com pulls are refused" {
  run bash "$PARSE" "javascript:alert(1)/pull/1"
  [ "$status" -eq 2 ]
  run bash "$PARSE" "https://api.github.com/repos/acme/app/pulls/42"
  [ "$status" -eq 2 ]
}

@test "parse-pr-url: non-http(s) scheme with userinfo is refused" {
  run -2 bash "$PARSE" "ssh://git@github.com/acme/app/pull/42"
  [[ "$output" == *"refused non-http(s) scheme"* ]]
}

@test "parse-pr-url: surrounding prose or Markdown punctuation is not part of the host" {
  source_url "review (https://github.com/acme/app/pull/42)"
  [[ "$HOST" == "github.com" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
  source_url "review [PR](https://github.com/acme/app/pull/42)"
  [[ "$HOST" == "github.com" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
  source_url "see **https://github.com/acme/app/pull/42**."
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
}

@test "parse-pr-url: text glued to the number is exit 2; .diff, .patch, and sub-pages are not" {
  run -2 bash "$PARSE" "https://github.com/acme/app/pull/42abc"
  [[ "$output" == *"may follow the PR/MR number"* ]]
  run -2 bash "$PARSE" "github.com/acme/app/pull/42abc"
  run -2 bash "$PARSE" "https://gitlab.com/g/p/-/merge_requests/7x/diffs"
  source_url "https://github.com/acme/app/pull/42.diff"
  [[ "$PR_NUMBER" == "42" ]]
  source_url "https://gitlab.com/g/p/-/merge_requests/7.patch"
  [[ "$PR_NUMBER" == "7" ]]
  source_url "https://gitlab.com/g/p/-/merge_requests/7/diffs"
  [[ "$PR_NUMBER" == "7" ]]
  source_url "review \`https://github.com/acme/app/pull/42\` and _github.com/acme/app/pull/43_"
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
  source_url "_github.com/acme/app/pull/43_"
  [[ "$PR_NUMBER" == "43" ]]
}

@test "parse-pr-url: a repos/ namespace is a review URL" {
  source_url "https://git.example.com/repos/proj/-/merge_requests/7"
  [[ "$REPO_SLUG" == "repos/proj" ]]
  source_url "https://github.com/repos/app/pull/42"
  [[ "$REPO_SLUG" == "repos/app" ]]
}

@test "parse-pr-url: GitHub slug that is not owner/repo is exit 2 (gh reads HOST/OWNER/REPO)" {
  run -2 bash "$PARSE" "https://github.com/acme/pull/42"
  run -2 bash "$PARSE" "https://github.com/evil.example/acme/app/pull/42"
  [[ "$output" == *"owner/repo"* ]]
}

@test "parse-pr-url: a non-default port is exit 2 (auth checks and API calls would hit the default port)" {
  run -2 bash "$PARSE" "https://git.example.test:8443/group/project/-/merge_requests/7"
  [[ "$output" == *"non-default port"* ]]
  run -2 bash "$PARSE" "git.example.test:8443/group/project/-/merge_requests/7"
  run -2 bash "$PARSE" "https://github.com:80/acme/app/pull/42"
  run -2 bash "$PARSE" "http://github.com:443/acme/app/pull/42"
  run -2 bash "$PARSE" "https://oauth2:s3cret@git.example.test:8443/group/project/-/merge_requests/7"
  [[ "$output" != *s3cret* ]]
}

@test "parse-pr-url: the default port :443 is accepted and dropped" {
  source_url "https://oauth2:s3cret@git.example.test:443/group/sub/proj/-/merge_requests/7"
  [[ "$HOST" == "git.example.test" ]]
  [[ "$REPO_SLUG" == "group/sub/proj" ]]
  [[ "$PR_URL" == "https://git.example.test/group/sub/proj/-/merge_requests/7" ]]
  source_url "git.example.test:443/group/proj/-/merge_requests/7"
  [[ "$HOST" == "git.example.test" ]]
}

@test "parse-pr-url: an http:// PR/MR URL is exit 2 (provider calls would send credentials unencrypted)" {
  run -2 bash "$PARSE" "http://git.example.test/group/project/-/merge_requests/7"
  [[ "$output" == *"refused http:// PR/MR URL"* ]]
  run -2 bash "$PARSE" "http://github.com:80/acme/app/pull/42.diff"
  [[ "$output" == *"refused http:// PR/MR URL"* ]]
  run -2 bash "$PARSE" "http://oauth2:s3cret@github.com/acme/app/pull/42"
  [[ "$output" != *s3cret* ]]
}

@test "parse-pr-url: an http:// non-PR link does not block the first PR/MR URL" {
  source_url "see http://example.com/docs and https://github.com/acme/app/pull/42"
  [[ "$HOST" == "github.com" ]]
  [[ "$PR_URL" == "https://github.com/acme/app/pull/42" ]]
}

@test "parse-pr-url: a port on a non-PR link does not block the first PR/MR URL" {
  source_url "see https://example.com:8443/docs and https://github.com/acme/app/pull/42"
  [[ "$HOST" == "github.com" ]]
  run bash "$PARSE" "https://example.com:8443/docs"
  [ "$status" -eq 1 ]
}

@test "parse-pr-url: a repository named after a route segment keeps its slug" {
  source_url "https://github.com/acme/pull/pull/12"
  [ "$REPO_SLUG" = "acme/pull" ]
  [ "$PR_NUMBER" = "12" ]
  source_url "https://github.com/pull/12/pull/5/files"
  [ "$REPO_SLUG" = "pull/12" ]
  [ "$PR_NUMBER" = "5" ]
  source_url "https://github.com/acme/app/pull/42/commits/0123abc"
  [ "$REPO_SLUG" = "acme/app" ]
  [ "$PR_NUMBER" = "42" ]
  source_url "https://bitbucket.org/team/pull-requests/pull-requests/9"
  [ "$REPO_SLUG" = "team/pull-requests" ]
  [ "$PR_NUMBER" = "9" ]
  source_url "https://gitlab.com/g/merge_requests/-/merge_requests/3/diffs"
  [ "$REPO_SLUG" = "g/merge_requests" ]
  [ "$PR_NUMBER" = "3" ]
}

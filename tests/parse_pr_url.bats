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

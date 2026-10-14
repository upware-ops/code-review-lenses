#!/usr/bin/env bash
# fetch-pr-metadata.sh — run PROVIDERS.md "OP: Fetch PR/MR metadata" for a
# parsed PR/MR URL without printing author-written text: the title is not
# fetched and the description is written to PR_BODY_FILE.
#
# Usage (after detect-provider.sh --check-url-host succeeded for HOST):
#   bash fetch-pr-metadata.sh --provider github|gitlab|bitbucket \
#     --host <HOST> --repo <REPO_SLUG> --number <PR_NUMBER>
#
# Output (exit 0): KEY=value lines safe to eval —
#   baseRefName baseRefOid headRefName PR_BODY_FILE
# Exit 2: missing/invalid argument, fetch failed, PR/MR closed or merged,
#         Bitbucket fork PR, or a branch name / base SHA that fails validation.

set -euo pipefail

PROVIDER=""
HOST=""
REPO=""
NUMBER=""

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
    --provider) need_value "$1" "${2-}"; PROVIDER="$2"; shift 2 ;;
    --host) need_value "$1" "${2-}"; HOST="$2"; shift 2 ;;
    --repo) need_value "$1" "${2-}"; REPO="$2"; shift 2 ;;
    --number) need_value "$1" "${2-}"; NUMBER="$2"; shift 2 ;;
    *) die "unknown argument '$1'." ;;
  esac
done

[[ -n "$HOST" && -n "$REPO" ]] || die "--host and --repo are required."
[[ "$NUMBER" =~ ^[1-9][0-9]*$ ]] || die "--number must be a positive integer."

case "$PROVIDER" in
  github)
    RAW=$(GH_HOST="$HOST" gh pr view "$NUMBER" --repo "$REPO" \
      --json baseRefName,baseRefOid,headRefName,state,body) || die "gh pr view failed."
    MAP='{base: .baseRefName, oid: .baseRefOid, head: .headRefName, state, body}'
    ;;
  gitlab)
    RAW=$(GITLAB_HOST="$HOST" glab mr view "$NUMBER" -R "https://$HOST/$REPO" --output json) \
      || die "glab mr view failed."
    MAP='{base: .target_branch, oid: .diff_refs.base_sha, head: .source_branch,
      state: ({opened: "OPEN", closed: "CLOSED", merged: "MERGED"}[.state] // .state),
      body: .description}'
    ;;
  bitbucket)
    RAW=$(curl -sf --user "${BITBUCKET_EMAIL:-}:${BITBUCKET_TOKEN:-${BITBUCKET_APP_PASSWORD:-}}" \
      "https://api.bitbucket.org/2.0/repositories/${REPO}/pullrequests/${NUMBER}") \
      || die "Bitbucket API request failed."
    MAP='{base: .destination.branch.name, oid: "", head: .source.branch.name,
      fork: (.source.repository.full_name != .destination.repository.full_name),
      state: ({DECLINED: "CLOSED", SUPERSEDED: "CLOSED"}[.state] // .state),
      body: .description}'
    ;;
  *)
    die "--provider must be github, gitlab, or bitbucket."
    ;;
esac

META=$(jq -c "$MAP" <<<"$RAW") || die "unparseable ${PROVIDER} metadata."
STATE=$(jq -r '.state // ""' <<<"$META")
BASE_REF=$(jq -r '.base // ""' <<<"$META")
BASE_OID=$(jq -r '.oid // ""' <<<"$META")
HEAD_REF=$(jq -r '.head // ""' <<<"$META")

case "$STATE" in
  OPEN) ;;
  CLOSED|MERGED) die "the PR/MR is ${STATE}." ;;
  *) echo "Unrecognized PR/MR state '${STATE}' — proceeding as OPEN." >&2 ;;
esac
[[ "$(jq -r '.fork // false' <<<"$META")" != true ]] || die "Bitbucket fork PRs are not supported."
git check-ref-format "refs/heads/$BASE_REF" || die "invalid target branch name."
git check-ref-format "refs/heads/$HEAD_REF" || die "invalid source branch name."
[[ "$BASE_REF" != -* && "$HEAD_REF" != -* ]] || die "branch names must not start with '-'."
[[ -z "$BASE_OID" || "$BASE_OID" =~ ^[0-9a-f]{7,64}$ ]] || die "invalid base commit SHA."

PR_BODY_FILE=$(mktemp)
jq -j '.body // ""' <<<"$META" > "$PR_BODY_FILE"

emit() {
  printf '%s=%q\n' "$1" "$2"
}

emit baseRefName "$BASE_REF"
emit baseRefOid "$BASE_OID"
emit headRefName "$HEAD_REF"
emit PR_BODY_FILE "$PR_BODY_FILE"

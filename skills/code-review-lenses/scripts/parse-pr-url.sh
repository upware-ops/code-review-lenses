#!/usr/bin/env bash
# parse-pr-url.sh — extract host, provider, repo slug, and PR/MR number from
# invoke text. The first http(s) (or scheme-less) PR/MR URL wins.
#
# Usage:
#   bash parse-pr-url.sh [text...]
#   printf '%s' "$GUIDANCE" | bash parse-pr-url.sh
#
# Output (exit 0): KEY=value lines safe to eval —
#   PR_URL PROVIDER HOST REPO_SLUG PR_NUMBER PR_TERM PR_TERM_LONG CLI_TOOL
#   GUIDANCE_REST (invoke text with the matched URL removed; userinfo stripped)
# Exit 1: no PR/MR URL in the text (local branch review).
# Exit 2: invalid / refused URL (scheme, api.github.com, non-owner/repo path,
#         text glued to the number, non-Cloud Bitbucket, or grep failure).
#         A bare number is never a complete identity.
#
# This is the shipped URL parser. Orchestrator SKILL.md must invoke it
# rather than re-implement host/number extraction.

set -euo pipefail

TEXT="$*"
if [[ $# -eq 0 && ! -t 0 ]]; then
  TEXT=$(cat)
fi

emit() {
  printf '%s=%q\n' "$1" "$2"
}

sanitize_url() {
  local u="$1"
  case "$u" in
    *://*@*)
      printf '%s://%s\n' "${u%%://*}" "${u#*@}"
      ;;
    *)
      printf '%s\n' "$u"
      ;;
  esac
}

# First matching URL-shaped token. Scheme optional so pasted host/path works.
_grep_rc=0
urls=$(printf '%s\n' "$TEXT" | grep -oE 'https?://[^[:space:]<>"'\'']+|[[:alnum:]][^][:space:]<>"'\'']*/(pulls?|pull-requests|(-/)?merge_requests)/[0-9]+[^][:space:]<>"'\'']*') || _grep_rc=$?
if [[ "$_grep_rc" -ne 0 && "$_grep_rc" -ne 1 ]]; then
  echo "Error: parse-pr-url.sh: grep failed (exit ${_grep_rc})." >&2
  exit 2
fi
unset _grep_rc

while IFS= read -r raw; do
  [[ -z "$raw" ]] && continue
  url="$raw"
  _trail='[].,;:!?)*`_~]$'
  while [[ "$url" =~ $_trail ]]; do
    url="${url%?}"
  done
  case "$url" in
    http://*|https://*) ;;
    *://*|javascript:*|data:*|file:*|vbscript:*)
      echo "Error: parse-pr-url.sh: refused non-http(s) scheme." >&2
      exit 2
      ;;
    *) url="https://${url}" ;;
  esac

  clean="${url%%#*}"
  clean="${clean%%\?*}"
  clean="${clean%/}"

  rest="${clean#*://}"
  rest="${rest#*@}"
  host="${rest%%/*}"
  host="${host%%:*}"
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  if [[ "$rest" == */* ]]; then
    path="/${rest#*/}"
  else
    path="/"
  fi

  provider=""
  number=""
  suffix=""
  slug=""

  if [[ "$path" =~ /-/merge_requests/([1-9][0-9]*)([^/]*) ]]; then
    provider=gitlab
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    slug="${path%%/-/merge_requests/*}"
  elif [[ "$path" =~ /merge_requests/([1-9][0-9]*)([^/]*) ]]; then
    provider=gitlab
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    slug="${path%%/merge_requests/*}"
  elif [[ "$path" =~ /pull-requests/([1-9][0-9]*)([^/]*) ]]; then
    provider=bitbucket
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    slug="${path%%/pull-requests/*}"
  elif [[ "$path" =~ /pulls/([1-9][0-9]*)([^/]*) ]]; then
    provider=github
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    slug="${path%%/pulls/*}"
  elif [[ "$path" =~ /pull/([1-9][0-9]*)([^/]*) ]]; then
    provider=github
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    slug="${path%%/pull/*}"
  else
    continue
  fi

  if [[ -n "$suffix" && "$suffix" != .diff && "$suffix" != .patch ]]; then
    echo "Error: parse-pr-url.sh: only /, .diff, or .patch may follow the PR/MR number." >&2
    exit 2
  fi

  slug="${slug#/}"
  slug="${slug%/}"
  slug="${slug%.git}"
  if [[ -z "$host" || -z "$slug" || -z "$number" ]]; then
    continue
  fi
  if [[ "$host" == "api.github.com" ]]; then
    echo "Error: parse-pr-url.sh: api.github.com /repos/…/pulls/N is not a review URL." >&2
    exit 2
  fi
  if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ || ( "$provider" != gitlab && "$slug" == */*/* ) ]]; then
    echo "Error: parse-pr-url.sh: repository path must be owner/repo (GitLab: group/…/project)." >&2
    exit 2
  fi
  if [[ "$provider" == bitbucket && "$host" != bitbucket.org && "$host" != *.bitbucket.org ]]; then
    echo "Error: parse-pr-url.sh: Bitbucket Cloud only (bitbucket.org)." >&2
    exit 2
  fi

  pr_term=PR
  pr_term_long="pull request"
  cli=gh
  case "$provider" in
    gitlab)
      pr_term=MR
      pr_term_long="merge request"
      cli=glab
      ;;
    bitbucket)
      cli=curl
      ;;
  esac

  _rest="${TEXT/"$raw"/}"
  while [[ "$_rest" == *"  "* ]]; do
    _rest="${_rest//  / }"
  done
  _rest="${_rest#"${_rest%%[![:space:]]*}"}"
  _rest="${_rest%"${_rest##*[![:space:]]}"}"
  _guidance=""
  set -f
  for _tok in $_rest; do
    case "$_tok" in
      *://*@*) _tok="$(printf '%s://%s' "${_tok%%://*}" "${_tok#*@}")" ;;
    esac
    _guidance+="${_guidance:+ }${_tok}"
  done
  set +f

  emit PR_URL "$(sanitize_url "$clean")"
  emit PROVIDER "$provider"
  emit HOST "$host"
  emit REPO_SLUG "$slug"
  emit PR_NUMBER "$number"
  emit PR_TERM "$pr_term"
  emit PR_TERM_LONG "$pr_term_long"
  emit CLI_TOOL "$cli"
  emit GUIDANCE_REST "$_guidance"
  unset _rest _tok _guidance
  exit 0
done <<< "$urls"

exit 1

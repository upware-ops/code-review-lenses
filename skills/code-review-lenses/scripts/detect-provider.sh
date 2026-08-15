#!/usr/bin/env bash
# detect-provider.sh — detect github / gitlab / bitbucket from a git remote
# and (for GitLab) any host already authenticated in `glab`.
#
# Usage:
#   bash detect-provider.sh [--provider NAME] [--remote-url URL] [--fallback unknown]
#   bash detect-provider.sh --check-url-host --provider NAME --host HOST
#
# If --remote-url is omitted, uses `git remote get-url origin`.
# If --provider is passed, auto-detection is skipped (host/slug still parsed).
# --fallback unknown: emit PROVIDER=unknown instead of dying when the remote
# is missing or the host cannot be classified (local branch review).
# --check-url-host: after parse-pr-url only. GitHub: github.com / *.github.com /
# *.ghe.com, or a host on `gh auth status` (origin match is not enough).
# GitLab: GITLAB_HOST / GL_HOST or `glab auth status` (origin match is not
# enough). Bitbucket: Cloud hosts only. Exit 0 if allowed, 2 if refused.
# Does not emit a roster. Never run on local PROVIDER=unknown.
#
# GitLab self-hosted / dedicated hosts are detected when ANY of:
#   - the hostname is gitlab.com or contains "gitlab"
#   - GITLAB_HOST / GL_HOST equals the remote hostname (URL form is stripped)
#   - `glab config get host` equals the remote hostname
#   - `glab auth status` stdout (exit 0) lists the remote hostname
#
# Output: KEY=value lines (PROVIDER, HOST, PR_TERM, PR_TERM_LONG, CLI_TOOL, REPO_SLUG).
# Never emits REMOTE_URL. Userinfo is stripped from any error text.
# Exit 0 on success. Exit 2 on detection / validation failure.

set -euo pipefail

PROVIDER_OVERRIDE=""
REMOTE_URL=""
FALLBACK=""
CHECK_URL_HOST=false
CHECK_HOST=""

# Strip userinfo (user:pass@) from a URL so it is safe to print.
sanitize_url() {
  local url="$1"
  case "$url" in
    *://*@*)
      printf '%s://%s\n' "${url%%://*}" "${url#*@}"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

# Official glab GITLAB_HOST is a URL; compare as a hostname.
gitlab_host_name() {
  local raw="${1:-}"
  raw="${raw#http://}"
  raw="${raw#https://}"
  raw="${raw%%/*}"
  raw="${raw%%:*}"
  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

die() {
  echo "Error: $*" >&2
  exit 2
}

need_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      need_value "$1" "${2-}"
      PROVIDER_OVERRIDE="$2"
      shift 2
      ;;
    --provider=*)
      PROVIDER_OVERRIDE="${1#--provider=}"
      shift
      ;;
    --remote-url)
      need_value "$1" "${2-}"
      REMOTE_URL="$2"
      shift 2
      ;;
    --remote-url=*)
      REMOTE_URL="${1#--remote-url=}"
      shift
      ;;
    --fallback)
      need_value "$1" "${2-}"
      FALLBACK="$2"
      shift 2
      ;;
    --fallback=*)
      FALLBACK="${1#--fallback=}"
      shift
      ;;
    --check-url-host)
      CHECK_URL_HOST=true
      shift
      ;;
    --host)
      need_value "$1" "${2-}"
      CHECK_HOST="$2"
      shift 2
      ;;
    --host=*)
      CHECK_HOST="${1#--host=}"
      shift
      ;;
    *)
      die "Unknown argument '$1'."
      ;;
  esac
done

if [[ -n "$PROVIDER_OVERRIDE" ]]; then
  case "$PROVIDER_OVERRIDE" in
    github|gitlab|bitbucket) ;;
    *) die "Unknown provider '$PROVIDER_OVERRIDE'. Valid values: github, gitlab, bitbucket." ;;
  esac
fi

if [[ "$CHECK_URL_HOST" != true && -z "$REMOTE_URL" ]]; then
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
  if [[ -z "$REMOTE_URL" ]]; then
    if [[ "$FALLBACK" == "unknown" ]]; then
      emit() { printf '%s=%q\n' "$1" "$2"; }
      emit PROVIDER unknown
      emit HOST ""
      emit PR_TERM PR
      emit PR_TERM_LONG "pull request"
      emit CLI_TOOL ""
      emit REPO_SLUG ""
      exit 0
    fi
    die "Could not read git remote 'origin'. Pass --remote-url."
  fi
fi

# Normalize scp-like URLs (git@host:path) to a host + path pair.
extract_host_path() {
  local url="$1"
  local rest host path

  url="${url%/}"
  url="${url%.git}"
  url="${url%/}"

  case "$url" in
    git@*:* )
      rest="${url#git@}"
      host="${rest%%:*}"
      path="${rest#*:}"
      ;;
    ssh://*|http://*|https://*|git://* )
      rest="${url#*://}"
      rest="${rest#*@}"          # drop userinfo
      host="${rest%%/*}"
      host="${host%%:*}"         # drop :port
      path="${rest#*/}"
      ;;
    *)
      die "Unrecognized remote URL '$(sanitize_url "$url")'."
      ;;
  esac

  path="${path#/}"
  printf '%s\t%s\n' "$host" "$path"
}

slug_two_segment() {
  local path="$1"
  local owner repo
  owner=$(printf '%s' "$path" | awk -F/ '{print $(NF-1)}')
  repo=$(printf '%s' "$path" | awk -F/ '{print $NF}')
  printf '%s/%s\n' "$owner" "$repo"
}

glab_lists_host() {
  local host="$1"
  local status cfg
  if ! command -v glab >/dev/null 2>&1; then
    return 1
  fi
  if cfg=$(glab config get host 2>/dev/null); then
    cfg=$(gitlab_host_name "$cfg")
    if [[ -n "$cfg" && "$cfg" == "$host" ]]; then
      return 0
    fi
  fi
  # stdout only; non-zero means not authenticated — do not grep stderr.
  if ! status=$(glab auth status 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$status" | grep -qiE "(^|[[:space:]])$(printf '%s' "$host" | sed 's/[.[\*^$()+?{|]/\\&/g')([[:space:]/:_]|$)"
}

gh_lists_host() {
  local host="$1"
  local status
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  if ! status=$(gh auth status 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$status" | grep -qiE "(^|[[:space:]])$(printf '%s' "$host" | sed 's/[.[\*^$()+?{|]/\\&/g')([[:space:]/:_]|$)"
}

if [[ "$CHECK_URL_HOST" == true ]]; then
  [[ -n "$PROVIDER_OVERRIDE" ]] || die "--check-url-host requires --provider."
  [[ -n "$CHECK_HOST" ]] || die "--check-url-host requires --host."
  HOST_LC=$(printf '%s' "$CHECK_HOST" | tr '[:upper:]' '[:lower:]')
  origin_host=""
  if origin_url=$(git remote get-url origin 2>/dev/null); then
    case "$origin_url" in
      git@*:*)
        rest="${origin_url#git@}"
        origin_host="${rest%%:*}"
        ;;
      *://*)
        rest="${origin_url#*://}"
        rest="${rest#*@}"
        origin_host="${rest%%/*}"
        origin_host="${origin_host%%:*}"
        ;;
    esac
    origin_host=$(printf '%s' "$origin_host" | tr '[:upper:]' '[:lower:]')
  fi
  case "$PROVIDER_OVERRIDE" in
    github)
      case "$HOST_LC" in
        github.com|*.github.com|*.ghe.com)
          exit 0
          ;;
      esac
      if gh_lists_host "$HOST_LC"; then
        exit 0
      fi
      die "Refusing gh for host '$CHECK_HOST' (not github.com / *.github.com / *.ghe.com and not on gh auth status). Run: gh auth login --hostname $CHECK_HOST"
      ;;
    gitlab)
      _gl_cfg=$(gitlab_host_name "${GITLAB_HOST:-${GL_HOST:-}}")
      if [[ -n "$_gl_cfg" && "$_gl_cfg" == "$HOST_LC" ]]; then
        exit 0
      fi
      if glab_lists_host "$HOST_LC"; then
        exit 0
      fi
      die "Refusing glab for host '$CHECK_HOST' (not GITLAB_HOST/GL_HOST and not on glab auth status). Run: glab auth login --hostname $CHECK_HOST"
      ;;
    bitbucket)
      case "$HOST_LC" in
        bitbucket.org|*.bitbucket.org)
          exit 0
          ;;
        *)
          die "Bitbucket Cloud only (bitbucket.org)."
          ;;
      esac
      ;;
  esac
fi

[[ -n "$REMOTE_URL" ]] || die "Could not read git remote 'origin'. Pass --remote-url."

HOST_PATH=$(extract_host_path "$REMOTE_URL")
HOST="${HOST_PATH%%$'\t'*}"
REPO_PATH="${HOST_PATH#*$'\t'}"
HOST_LC=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')

if [[ -z "$HOST" || -z "$REPO_PATH" ]]; then
  die "Could not extract host/path from remote URL '$(sanitize_url "$REMOTE_URL")'."
fi

PROVIDER=""
if [[ -n "$PROVIDER_OVERRIDE" ]]; then
  PROVIDER="$PROVIDER_OVERRIDE"
else
  case "$HOST_LC" in
    github.com|*.github.com)
      PROVIDER=github
      ;;
    gitlab.com|*.gitlab.com|*gitlab*)
      PROVIDER=gitlab
      ;;
    bitbucket.org|*.bitbucket.org)
      PROVIDER=bitbucket
      ;;
    *)
      _gl_env=$(gitlab_host_name "${GITLAB_HOST:-${GL_HOST:-}}")
      if [[ -n "$_gl_env" && "$_gl_env" == "$HOST_LC" ]]; then
        PROVIDER=gitlab
      elif glab_lists_host "$HOST_LC"; then
        PROVIDER=gitlab
      elif gh_lists_host "$HOST_LC"; then
        PROVIDER=github
      elif [[ "$FALLBACK" == "unknown" ]]; then
        PROVIDER=unknown
      else
        die "Could not detect git provider from remote URL '$(sanitize_url "$REMOTE_URL")' (host '$HOST'). Authenticate glab for this host (glab auth login --hostname $HOST) or set GITLAB_HOST."
      fi
      ;;
  esac
fi

case "$PROVIDER" in
  github)
    PR_TERM=PR
    PR_TERM_LONG="pull request"
    CLI_TOOL=gh
    REPO_SLUG=$(slug_two_segment "$REPO_PATH")
    ;;
  gitlab)
    PR_TERM=MR
    PR_TERM_LONG="merge request"
    CLI_TOOL=glab
    # GitLab projects may be nested (group/sub/project).
    REPO_SLUG="$REPO_PATH"
    ;;
  bitbucket)
    PR_TERM=PR
    PR_TERM_LONG="pull request"
    CLI_TOOL=curl
    REPO_SLUG=$(slug_two_segment "$REPO_PATH")
    ;;
  unknown)
    PR_TERM=PR
    PR_TERM_LONG="pull request"
    CLI_TOOL=""
    REPO_SLUG=$(slug_two_segment "$REPO_PATH")
    ;;
esac

if [[ "$PROVIDER" != "unknown" && ! "$REPO_SLUG" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]; then
  die "Could not extract a valid repository slug from remote URL '$(sanitize_url "$REMOTE_URL")'."
fi

emit() {
  printf '%s=%q\n' "$1" "$2"
}

emit PROVIDER "$PROVIDER"
emit HOST "$HOST"
emit PR_TERM "$PR_TERM"
emit PR_TERM_LONG "$PR_TERM_LONG"
emit CLI_TOOL "$CLI_TOOL"
emit REPO_SLUG "$REPO_SLUG"

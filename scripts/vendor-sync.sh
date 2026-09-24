#!/usr/bin/env bash
# vendor-sync.sh — refresh vendored pr-review-toolkit agents, or list
# tag1consulting/claude-comprehensive-review commits since the last pin.
#
# Usage:
#   bash scripts/vendor-sync.sh toolkit [--sha <sha>] [--from-dir <dir>] [--dry-run]
#   bash scripts/vendor-sync.sh digest [--since <sha>]
#   bash scripts/vendor-sync.sh transform <infile >outfile
#
# toolkit writes agents/<name>.md after applying the local patches in
# agents/THIRD_PARTY.md (drop model:/color:, CLAUDE.md → AGENTS.md, generic
# logging / error-ID wording, banner).
# It never adds agents that are not in .github/vendor-pins.json.
# digest prints markdown for commits on tag1 main after the pin (no file writes).
#
# Exit: 0 on success (toolkit: files may or may not change; digest: may be empty).
#       2 on usage / fetch / pin errors.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PINS_FILE="${REPO_ROOT}/.github/vendor-pins.json"
BANNER='<!-- Vendored from pr-review-toolkit (Apache-2.0). See agents/THIRD_PARTY.md. Modified: removed host-specific model/color bindings; AGENTS.md replaces CLAUDE.md. -->'

die() { echo "Error: $*" >&2; exit 2; }

need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required"; }

api_get() {
  local url=$1
  local args=(-fsSL -H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  elif [[ -n "${GH_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi
  curl "${args[@]}" "$url" || die "fetch failed: $url"
}

# Strip model:/color: from YAML frontmatter; CLAUDE.md → AGENTS.md; genericize
# Anthropic-internal logging / error-ID references; upsert banner.
transform_agent() {
  awk -v banner="$BANNER" '
    BEGIN { fm = 0; banner_done = 0 }
    /^---[[:space:]]*$/ {
      if (fm == 0) { fm = 1; print; next }
      if (fm == 1) { fm = 2; print; next }
    }
    fm == 1 && /^(model|color):[[:space:]]/ { next }
    fm == 2 && !banner_done {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /Vendored from pr-review-toolkit/) {
        print ""
        print banner
        banner_done = 1
        next
      }
      print ""
      print banner
      print ""
      banner_done = 1
    }
    fm == 2 && /^[-*] .*(constants\/errorIds\.ts|Sentry tracking)/ { next }
    fm == 2 && /^[-*] .*logForDebugging/ {
      print "- Use the logging functions and error-ID conventions the reviewed project defines, if any"
      next
    }
    fm == 2 { sub(/ \(logError for production issues\)/, "") }
    {
      if ($0 !~ /Vendored from pr-review-toolkit/) {
        gsub(/CLAUDE\.md/, "AGENTS.md")
      }
      print
    }
    END {
      if (fm == 2 && !banner_done) {
        print ""
        print banner
      }
    }
  '
}

cmd_transform() {
  transform_agent
}

latest_sha() {
  local repo=$1 ref=$2
  api_get "https://api.github.com/repos/${repo}/commits/${ref}" | jq -er '.sha' || die "could not resolve ${repo}@${ref}"
}

fetch_raw() {
  local repo=$1 sha=$2 path=$3
  curl -fsSL "https://raw.githubusercontent.com/${repo}/${sha}/${path}" || die "fetch failed: ${repo}@${sha}:${path}"
}

cmd_toolkit() {
  need_jq
  [[ -f "$PINS_FILE" ]] || die "missing $PINS_FILE"

  local sha="" from_dir="" dry=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha) sha=${2:-}; shift 2 || die "missing value for $1" ;;
      --from-dir) from_dir=${2:-}; shift 2 || die "missing value for $1" ;;
      --dry-run) dry=true; shift ;;
      *) die "unknown toolkit flag: $1" ;;
    esac
  done

  local repo prefix agents=()
  repo=$(jq -er '.["pr-review-toolkit"].repo' "$PINS_FILE")
  prefix=$(jq -er '.["pr-review-toolkit"].prefix' "$PINS_FILE")
  while IFS= read -r _agent; do
    [[ -n "$_agent" ]] && agents+=("$_agent")
  done < <(jq -er '.["pr-review-toolkit"].agents[]' "$PINS_FILE")
  [[ ${#agents[@]} -gt 0 ]] || die "no agents listed in vendor-pins.json"

  if [[ -z "$from_dir" && -z "$sha" ]]; then
    sha=$(latest_sha "$repo" "$(jq -er '.["pr-review-toolkit"].ref' "$PINS_FILE")")
  fi
  [[ -n "$from_dir" || -n "$sha" ]] || die "need --sha or a resolvable upstream ref"
  [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{40}$ ]] || die "not a full commit SHA: $sha"

  local tmp changed=0
  tmp=$(mktemp -d)
  trap 'rm -rf "'"$tmp"'"' EXIT

  local agent src dest
  for agent in "${agents[@]}"; do
    [[ "$agent" == *.md && "$agent" != */* ]] || die "refusing agent path: $agent"
    if [[ -n "$from_dir" ]]; then
      src="${from_dir}/${agent}"
      [[ -f "$src" ]] || die "missing $src"
      transform_agent < "$src" > "${tmp}/${agent}"
    else
      fetch_raw "$repo" "$sha" "${prefix}/${agent}" | transform_agent > "${tmp}/${agent}"
    fi
    [[ -s "${tmp}/${agent}" ]] || die "empty transform for $agent"
  done

  for agent in "${agents[@]}"; do
    dest="${REPO_ROOT}/agents/${agent}"
    if ! cmp -s "${tmp}/${agent}" "$dest" 2>/dev/null; then
      changed=1
      if [[ "$dry" == true ]]; then
        echo "would update agents/${agent}"
      else
        cp "${tmp}/${agent}" "$dest"
        echo "updated agents/${agent}"
      fi
    fi
  done

  if [[ -n "$sha" && "$changed" -eq 1 ]]; then
    local old
    old=$(jq -er '.["pr-review-toolkit"].sha' "$PINS_FILE")
    if [[ "$old" != "$sha" ]]; then
      if [[ "$dry" == true ]]; then
        echo "would pin pr-review-toolkit $old -> $sha"
      else
        local pins_tmp
        pins_tmp=$(mktemp)
        jq --arg sha "$sha" '.["pr-review-toolkit"].sha = $sha' "$PINS_FILE" > "$pins_tmp"
        mv "$pins_tmp" "$PINS_FILE"
        echo "pinned pr-review-toolkit $sha"
      fi
    fi
  fi

  if [[ "$changed" -eq 0 ]]; then
    echo "pr-review-toolkit: already current${sha:+ ($sha)}"
  fi
}

cmd_digest() {
  need_jq
  [[ -f "$PINS_FILE" ]] || die "missing $PINS_FILE"

  local since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since=${2:-}; shift 2 || die "missing value for $1" ;;
      *) die "unknown digest flag: $1" ;;
    esac
  done

  local repo ref pin
  repo=$(jq -er '.["tag1-comprehensive-review"].repo' "$PINS_FILE")
  ref=$(jq -er '.["tag1-comprehensive-review"].ref' "$PINS_FILE")
  pin=$(jq -er '.["tag1-comprehensive-review"].sha' "$PINS_FILE")
  [[ -n "$since" ]] || since=$pin

  local head
  head=$(latest_sha "$repo" "$ref")
  echo "TAG1_HEAD=$head"
  echo "TAG1_SINCE=$since"
  if [[ "$head" == "$since" ]]; then
    echo "tag1consulting/claude-comprehensive-review: no new commits"
    return 0
  fi

  # Compare API: commits on head that are not on since.
  local body
  body=$(api_get "https://api.github.com/repos/${repo}/compare/${since}...${head}")
  local n
  n=$(jq -er '.ahead_by // 0' <<<"$body")
  echo "TAG1_AHEAD=$n"
  if [[ "$n" -eq 0 ]]; then
    echo "tag1consulting/claude-comprehensive-review: no new commits"
    return 0
  fi

  echo
  echo "## tag1consulting/claude-comprehensive-review (${since:0:8}...${head:0:8})"
  echo
  echo "${n} commit(s) on \`${ref}\` since the fork pin. These are **not** auto-merged"
  echo "(2.0 dropped posting, plugin install, and \`--pr\` / \`--provider\`)."
  echo "Port individual script or analyzer fixes by hand."
  echo
  jq -r '.commits[] | "- `\(.sha[0:8])` \(.commit.message | split("\n")[0])"' <<<"$body"
}

usage() {
  die "usage: $0 toolkit [--sha SHA] [--from-dir DIR] [--dry-run]
       $0 digest [--since SHA]
       $0 transform <infile >outfile"
}

main() {
  local cmd=${1:-}
  [[ -n "$cmd" ]] || usage
  shift || true
  case "$cmd" in
    toolkit) cmd_toolkit "$@" ;;
    digest) cmd_digest "$@" ;;
    transform) cmd_transform "$@" ;;
    *) usage ;;
  esac
}

main "$@"

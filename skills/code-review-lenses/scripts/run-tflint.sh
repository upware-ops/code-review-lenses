#!/usr/bin/env bash
#
# run-tflint.sh — Run tflint on changed Terraform files and emit findings.
#
# Catches issues checkov misses: invalid instance types, deprecated resources,
# Terraform-specific anti-patterns. Runs without terraform init (static parser).
# Missing tflint → [] exit 0. Plugin/init/crash → [] exit 1 (ANALYZER_FAILED).
#
# Usage (two forms):
#   echo "$CHANGED_FILES" | ./run-tflint.sh          # stdin (used by SKILL.md)
#   ./run-tflint.sh <changed_files_list>              # positional arg
#
# Output:
#   JSON array of findings in the json-findings schema.
#   Outputs "[]" if tflint is unavailable, no Terraform files changed, or no issues found.
#
# Environment:
#   TFLINT_MOCK_FILE   When set to a readable file path, read tflint JSON output
#                      from that file instead of running the binary.
#                      For offline testing only; unset in production.

set -euo pipefail

# Accept changed files list from stdin or $1
if [[ -n "${1:-}" ]]; then
  CHANGED_FILES="$1"
else
  CHANGED_FILES=$(cat)
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq not installed; tflint check skipped." >&2
  echo "[]"
  exit 0
fi

if [[ -z "${TFLINT_MOCK_FILE:-}" ]] && ! command -v tflint >/dev/null 2>&1; then
  echo "WARNING: tflint not installed; tflint check skipped." >&2
  echo "[]"
  exit 0
fi

# Filter to Terraform files only
TF_FILES=()
TF_DIRS=()
TF_DIR_FIRST=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    *.tf|*.tfvars)
      [[ -f "$file" ]] || continue
      TF_FILES+=("$file")
      # Collect unique directories for --chdir
      dir=$(dirname "$file")
      # Only add if not already in TF_DIRS
      already=false
      for d in "${TF_DIRS[@]+"${TF_DIRS[@]}"}"; do
        [[ "$d" == "$dir" ]] && { already=true; break; }
      done
      [[ "$already" == "false" ]] && { TF_DIRS+=("$dir"); TF_DIR_FIRST+=("${file##*/}"); }
      ;;
  esac
done <<< "$CHANGED_FILES"

if [[ ${#TF_FILES[@]} -eq 0 ]]; then
  echo "[]"
  exit 0
fi

if [[ -n "${TFLINT_MOCK_FILE:-}" ]]; then
  if [[ ! -r "$TFLINT_MOCK_FILE" ]]; then
    echo "WARNING: TFLINT_MOCK_FILE '${TFLINT_MOCK_FILE}' is not readable." >&2
    echo "[]"
    exit 0
  fi
  TFLINT_OUTPUT=$(cat "$TFLINT_MOCK_FILE")
else
  # tflint must be run per-directory (it reads the full module in each dir).
  # tflint --chdir emits bare filenames (e.g. "main.tf"), so prepend the dir
  # so json-findings `file` is repo-relative.
  # --chdir makes tflint load .tflint.hcl, ./.tflint.d/plugins and relative TFLINT_CONFIG_FILE / TFLINT_PLUGIN_DIR paths from the reviewed directory (no ~ expansion for either).
  TFLINT_ARGS=(--format=json)
  case "${TFLINT_CONFIG_FILE:-}" in ""|/*) ;; *) export TFLINT_CONFIG_FILE="$PWD/$TFLINT_CONFIG_FILE" ;; esac
  case "${TFLINT_PLUGIN_DIR:-}" in ""|/*) ;; *) export TFLINT_PLUGIN_DIR="$PWD/$TFLINT_PLUGIN_DIR" ;; esac
  if [[ -z "${TFLINT_CONFIG_FILE:-}" ]]; then
    TFLINT_CONFIGS=("${GITHUB_WORKSPACE:-$PWD}"/.tflint.{hcl,json})
    [[ -n "${HOME:-}" ]] && TFLINT_CONFIGS+=("$HOME"/.tflint.{hcl,json})
    TFLINT_CONFIG=/dev/null
    for cfg in "${TFLINT_CONFIGS[@]}"; do
      [[ -f "$cfg" ]] && { TFLINT_CONFIG="$cfg"; break; }
    done
    TFLINT_ARGS+=(--config="$TFLINT_CONFIG")
  fi
  TRUSTED_PLUGIN_DIR="${GITHUB_WORKSPACE:-$PWD}/.tflint.d/plugins"
  [[ -d "$TRUSTED_PLUGIN_DIR" || -z "${HOME:-}" ]] || TRUSTED_PLUGIN_DIR="$HOME/.tflint.d/plugins"
  export TFLINT_PLUGIN_DIR="${TFLINT_PLUGIN_DIR:-$TRUSTED_PLUGIN_DIR}"

  ALL_ISSUES="[]"
  for i in "${!TF_DIRS[@]}"; do
    dir="${TF_DIRS[$i]}"
    DIR_STDERR=$(mktemp)
    DIR_EC=0
    DIR_OUTPUT=$(tflint --chdir="$dir" "${TFLINT_ARGS[@]}" 2>"$DIR_STDERR") || DIR_EC=$?
    # tflint: 0 = clean, 2 = issues found. Anything else (or empty stdout
    # after a non-success code) is a crash — fail-closed.
    if [[ "$DIR_EC" -ne 0 && "$DIR_EC" -ne 2 ]] || { [[ "$DIR_EC" -ne 0 ]] && [[ -z "$DIR_OUTPUT" ]]; }; then
      echo "WARNING: tflint failed in '${dir}' (exit ${DIR_EC}): $(cat "$DIR_STDERR")" >&2
      rm -f "$DIR_STDERR"
      echo "[]"
      exit 1
    fi
    rm -f "$DIR_STDERR"
    if [[ -n "$DIR_OUTPUT" ]]; then
      # Prepend dir/ to each issue's filename, stripping a leading "./" if present
      # Module-level issues (e.g. terraform_required_version) carry filename "" and line 0 (terraform-linters/tflint#1986)
      DIR_ISSUES=$(echo "$DIR_OUTPUT" | jq --arg dir "$dir" --arg first "${TF_DIR_FIRST[$i]}" '
        [.issues[]? | .range.filename = (
          (if .range.filename == "" then $first else .range.filename end) as $f
          | if $dir == "." then $f
            else (($dir | ltrimstr("./")) + "/" + $f)
            end
        )]
      ' 2>/dev/null) || {
        echo "WARNING: tflint JSON from '${dir}' could not be parsed." >&2
        echo "[]"
        exit 1
      }
      ALL_ISSUES=$(printf '%s\n%s' "$ALL_ISSUES" "$DIR_ISSUES" | jq -s 'add // []' 2>/dev/null) || {
        echo "WARNING: tflint issue merge failed." >&2
        echo "[]"
        exit 1
      }
    fi
  done
  TFLINT_OUTPUT=$(printf '{"issues":%s}' "$ALL_ISSUES")
fi

if [[ -z "$TFLINT_OUTPUT" ]]; then
  echo "[]"
  exit 0
fi

# tflint JSON structure:
# {
#   "issues": [
#     {
#       "rule": {"name": "aws_instance_invalid_type", "severity": "error", "link": "https://..."},
#       "message": "...",
#       "range": {"filename": "main.tf", "start": {"line": 12, "column": 1}, "end": {...}}
#     }
#   ],
#   "errors": []
# }
# Severity mapping:
#   error   -> High
#   warning -> Medium
#   notice  -> Low
FINDINGS=$(echo "$TFLINT_OUTPUT" | jq -r --arg first "${TF_FILES[0]}" '
  [
    .issues[]? |
    {
      severity: (
        if .rule.severity == "error"   then "High"
        elif .rule.severity == "warning" then "Medium"
        else "Low"
        end
      ),
      confidence: 90,
      source: "tflint",
      file: (if .range.filename == "" then $first else .range.filename end),
      line: (.range.start.line // 1),
      finding: ("\(.rule.name): \(.message)"),
      remediation: (
        if .rule.link and (.rule.link | length > 0) then "See \(.rule.link)"
        else "See https://github.com/terraform-linters/tflint-ruleset-aws"
        end
      )
    }
  ]
' 2>/dev/null) || {
  echo "WARNING: tflint output could not be parsed; tflint findings skipped." >&2
  echo "[]"
  exit 1
}

echo "${FINDINGS:-[]}"

#!/usr/bin/env bash
#
# run-golangci-lint.sh — Run golangci-lint on changed Go files and emit findings.
#
# Usage (two forms):
#   echo "$CHANGED_FILES" | ./run-golangci-lint.sh        # stdin (used by SKILL.md)
#   ./run-golangci-lint.sh <changed_files_list>            # positional arg
#
# Output:
#   JSON array of findings in the json-findings schema.
#   Outputs "[]" if golangci-lint is unavailable, no Go files changed, or no issues found.
#
# Environment:
#   GOLANGCI_MOCK_FILE   When set to a readable file path, read golangci-lint
#                        JSON output from that file instead of running the binary.
#                        For offline testing only; unset in production.

set -euo pipefail

# Accept changed files list from stdin or $1
if [[ -n "${1:-}" ]]; then
  CHANGED_FILES="$1"
else
  CHANGED_FILES=$(cat)
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq not installed; golangci-lint check skipped." >&2
  echo "[]"
  exit 0
fi

if [[ -z "${GOLANGCI_MOCK_FILE:-}" ]] && ! command -v golangci-lint >/dev/null 2>&1; then
  echo "WARNING: golangci-lint not installed; golangci-lint check skipped." >&2
  echo "[]"
  exit 0
fi

# Filter to Go source files
GO_FILES=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    *.go) [[ -f "$file" ]] && GO_FILES+=("$file") ;;
  esac
done <<< "$CHANGED_FILES"

if [[ ${#GO_FILES[@]} -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# Run golangci-lint (or read mock).
# golangci-lint v2 also prints stats and config-defined formats on stdout, and reports paths relative to its config file.
if [[ -n "${GOLANGCI_MOCK_FILE:-}" ]]; then
  if [[ ! -r "$GOLANGCI_MOCK_FILE" ]]; then
    echo "WARNING: GOLANGCI_MOCK_FILE '${GOLANGCI_MOCK_FILE}' is not readable." >&2
    echo "[]"
    exit 0
  fi
  GL_OUTPUT=$(cat "$GOLANGCI_MOCK_FILE")
else
  # golangci-lint must run from the root of each Go module (where go.mod lives).
  # Walk up from every changed file's directory to its nearest go.mod.
  FILE_ROOTS=()
  for f in "${GO_FILES[@]}"; do
    _dir=$(dirname "$f")
    until [[ -f "$_dir/go.mod" || "$_dir" == "/" || "$_dir" == "." ]]; do
      _dir=$(dirname "$_dir")
    done
    if [[ -f "$_dir/go.mod" ]]; then
      FILE_ROOTS+=("$_dir")
    else
      echo "WARNING: could not find go.mod for ${f} — skipped." >&2
      FILE_ROOTS+=("")
    fi
  done

  # Without an explicit config, golangci-lint loads the first one found from the module root upward, which a reviewed PR controls.
  GL_CONFIG_ARG="--no-config"
  for cfg in "${GITHUB_WORKSPACE:-$PWD}"/.golangci.{yml,yaml,toml,json} "$HOME"/.golangci.{yml,yaml,toml,json}; do
    [[ -f "$cfg" ]] && { GL_CONFIG_ARG="--config=$cfg"; break; }
  done

  GOLANGCI_STDERR=$(mktemp)
  GOLANGCI_JSON=$(mktemp)
  trap 'rm -f "$GOLANGCI_STDERR" "$GOLANGCI_JSON"' EXIT

  GL_OUTPUT=""
  SEEN_ROOTS=$'\n'
  for i in "${!GO_FILES[@]}"; do
    MODULE_ROOT="${FILE_ROOTS[$i]}"
    [[ -z "$MODULE_ROOT" || "$SEEN_ROOTS" == *$'\n'"$MODULE_ROOT"$'\n'* ]] && continue
    SEEN_ROOTS+="$MODULE_ROOT"$'\n'

    # Derive unique package directories relative to the module root
    PKG_PATTERNS=()
    for j in "${!GO_FILES[@]}"; do
      [[ "${FILE_ROOTS[$j]}" == "$MODULE_ROOT" ]] || continue
      d=$(dirname "${GO_FILES[$j]}")
      if [[ "$MODULE_ROOT" == "." ]]; then
        rel_d="$d"
      else
        rel_d="${d#"${MODULE_ROOT}/"}"
        [[ "$rel_d" == "$d" ]] && rel_d="."
      fi
      already=false
      for p in "${PKG_PATTERNS[@]+"${PKG_PATTERNS[@]}"}"; do
        [[ "$p" == "./${rel_d}/..." ]] && { already=true; break; }
      done
      [[ "$already" == "false" ]] && PKG_PATTERNS+=("./${rel_d}/...")
    done

    : >"$GOLANGCI_JSON"
    GL_EC=0
    (cd "$MODULE_ROOT" && golangci-lint run --output.json.path="$GOLANGCI_JSON" --path-mode=abs --issues-exit-code=0 "$GL_CONFIG_ARG" "${PKG_PATTERNS[@]}" >/dev/null 2>"$GOLANGCI_STDERR") || GL_EC=$?
    MODULE_OUTPUT=$(cat "$GOLANGCI_JSON")
    if [[ "$GL_EC" -ne 0 || -z "$MODULE_OUTPUT" ]]; then
      echo "WARNING: golangci-lint failed in '${MODULE_ROOT}' (exit ${GL_EC}). stderr: $(cat "$GOLANGCI_STDERR")" >&2
      echo "[]"
      exit 1
    fi
    GL_OUTPUT+="$MODULE_OUTPUT"$'\n'
  done
fi

if [[ -z "$GL_OUTPUT" ]]; then
  echo "[]"
  exit 0
fi

# Convert golangci-lint JSON to the findings schema.
# Severity mapping by linter name:
#   errcheck, govet, staticcheck → High
#   everything else               → Medium
FINDINGS=$(echo "$GL_OUTPUT" | jq -rs --arg cwd "$PWD/" '
  [
    .[].Issues[]? |
    {
      severity: (
        if (.FromLinter == "errcheck" or .FromLinter == "govet" or .FromLinter == "staticcheck")
        then "High"
        else "Medium"
        end
      ),
      confidence: 90,
      source: "golangci-lint",
      file: (.Pos.Filename | ltrimstr($cwd)),
      line: .Pos.Line,
      finding: ("\(.FromLinter): \(.Text)"),
      remediation: "Review the \(.FromLinter) linter documentation for this issue."
    }
  ]
' 2>/dev/null) || {
  echo "WARNING: golangci-lint output could not be parsed; golangci-lint findings skipped." >&2
  echo "[]"
  exit 1
}

echo "${FINDINGS:-[]}"

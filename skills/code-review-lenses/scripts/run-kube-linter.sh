#!/usr/bin/env bash
#
# run-kube-linter.sh — Run kube-linter on changed Kubernetes manifest files.
#
# Triggers on YAML/JSON files that contain Kubernetes apiVersion + kind fields.
# Catches reliability issues (missing liveness probes, resource limits, :latest
# image tags) that checkov's CIS-benchmark focus misses.
#
# Usage (two forms):
#   echo "$CHANGED_FILES" | ./run-kube-linter.sh    # stdin (used by SKILL.md)
#   ./run-kube-linter.sh <changed_files_list>        # positional arg
#
# Output:
#   JSON array of findings in the json-findings schema.
#   Outputs "[]" if kube-linter is unavailable, no K8s files changed, or no issues found.
#
# Environment:
#   KUBELINTER_MOCK_FILE   When set to a readable file path, read kube-linter
#                          JSON output from that file instead of running the binary.
#                          For offline testing only; unset in production.

set -euo pipefail

# Accept changed files list from stdin or $1
if [[ -n "${1:-}" ]]; then
  CHANGED_FILES="$1"
else
  CHANGED_FILES=$(cat)
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq not installed; kube-linter check skipped." >&2
  echo "[]"
  exit 0
fi

if [[ -z "${KUBELINTER_MOCK_FILE:-}" ]] && ! command -v kube-linter >/dev/null 2>&1; then
  echo "WARNING: kube-linter not installed; kube-linter check skipped." >&2
  echo "[]"
  exit 0
fi

# Filter to YAML/JSON files that look like Kubernetes manifests (apiVersion + kind), skipping Helm templates ({{) that cannot decode
K8S_FILES=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ -f "$file" ]] || continue
  grep -qF '{{' "$file" 2>/dev/null && continue
  case "$file" in
    *.yaml|*.yml)
      # YAML K8s heuristic: apiVersion: and kind: as top-level keys
      if grep -qE '^apiVersion:' "$file" 2>/dev/null && grep -qE '^kind:' "$file" 2>/dev/null; then
        K8S_FILES+=("$file")
      fi
      ;;
    *.json)
      # JSON K8s heuristic: "apiVersion": and "kind": as object keys
      if grep -qE '"apiVersion"\s*:' "$file" 2>/dev/null && grep -qE '"kind"\s*:' "$file" 2>/dev/null; then
        K8S_FILES+=("$file")
      fi
      ;;
  esac
done <<< "$CHANGED_FILES"

if [[ ${#K8S_FILES[@]} -eq 0 ]]; then
  echo "[]"
  exit 0
fi

if [[ -n "${KUBELINTER_MOCK_FILE:-}" ]]; then
  if [[ ! -r "$KUBELINTER_MOCK_FILE" ]]; then
    echo "WARNING: KUBELINTER_MOCK_FILE '${KUBELINTER_MOCK_FILE}' is not readable." >&2
    echo "[]"
    exit 0
  fi
  KUBELINTER_OUTPUT=$(cat "$KUBELINTER_MOCK_FILE")
else
  # kube-linter exits 1 when violations found (expected); capture stderr to
  # distinguish genuine errors from a no-violations run.
  KUBELINTER_STDERR=$(mktemp)
  KUBELINTER_EC=0
  # Deprecated upstream but still honored: without it undecodable manifests only warn on stderr instead of becoming failed-to-load-object reports.
  KUBELINTER_OUTPUT=$(kube-linter lint --format json --fail-on-invalid-resource "${K8S_FILES[@]}" 2>"$KUBELINTER_STDERR") || KUBELINTER_EC=$?
  if [[ -z "$KUBELINTER_OUTPUT" && "$KUBELINTER_EC" -ne 0 ]]; then
    echo "WARNING: kube-linter failed (exit ${KUBELINTER_EC}): $(cat "$KUBELINTER_STDERR")" >&2
    rm -f "$KUBELINTER_STDERR"
    echo "[]"
    exit 1
  fi
  rm -f "$KUBELINTER_STDERR"
fi

if [[ -z "$KUBELINTER_OUTPUT" ]]; then
  echo "[]"
  exit 0
fi

# kube-linter JSON structure:
# {
#   "Reports": [
#     {
#       "Diagnostic": {"Message": "..."},
#       "Check": "no-read-only-root-fs",
#       "Remediation": "...",
#       "Object": {
#         "Metadata": {"FilePath": "/abs/path/deploy.yaml"},
#         "K8sObject": {"Namespace": "", "Name": "my-app", "GroupVersionKind": {"Group":"apps","Version":"v1","Kind":"Deployment"}}
#       }
#     }
#   ],
#   "Summary": {"ChecksStatus": "Failed"}
# }
# kube-linter has no severity or line number; map all findings to Medium (reliability,
# not security — security issues are better caught by checkov) and line 0 (unknown).
FINDINGS=$(echo "$KUBELINTER_OUTPUT" | jq -r --arg root "$PWD" '
  [
    .Reports[]? |
    {
      severity: "Medium",
      confidence: 85,
      source: "kube-linter",
      file: ((.Object.Metadata.FilePath // "unknown") | ltrimstr($root + "/")),
      line: 0,
      finding: ("\(.Check): \(.Diagnostic.Message // "policy violation") [\((.Object.K8sObject.GroupVersionKind.Kind | select(length > 0)) // "resource") \(.Object.K8sObject.Name // "")]"),
      remediation: (.Remediation // "See https://docs.kubelinter.io/#/generated/checks")
    }
  ]
' 2>/dev/null) || {
  echo "WARNING: kube-linter output could not be parsed; kube-linter findings skipped." >&2
  echo "[]"
  exit 1
}

echo "${FINDINGS:-[]}"

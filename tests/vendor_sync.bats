#!/usr/bin/env bats
# vendor-sync.sh: local patches applied to pr-review-toolkit agents.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  REPO_ROOT="$(cd "${SCRIPTS_DIR}/../../.." && pwd)"
  VENDOR="${REPO_ROOT}/scripts/vendor-sync.sh"
  UPSTREAM="${FIXTURES_DIR}/vendor/upstream-agent.md"
}

@test "transform: drops model and color, rewrites CLAUDE.md, inserts banner" {
  run --separate-stderr bash "$VENDOR" transform < "$UPSTREAM"
  [ "$status" -eq 0 ]
  ! grep -qE '^(model|color):' <<<"$output"
  grep -q 'Follow AGENTS.md' <<<"$output"
  grep -q 'Review against AGENTS.md' <<<"$output"
  grep -q 'Vendored from pr-review-toolkit' <<<"$output"
  # Banner may mention CLAUDE.md as the thing that was replaced.
  banner=$(printf '%s\n' "$output" | grep 'Vendored from pr-review-toolkit')
  grep -q 'AGENTS.md replaces CLAUDE.md' <<<"$banner"
}

@test "transform: is idempotent on a already-vendored agent" {
  first=$(bash "$VENDOR" transform < "$UPSTREAM")
  second=$(printf '%s\n' "$first" | bash "$VENDOR" transform)
  [ "$first" = "$second" ]
}

@test "toolkit --from-dir --dry-run does not write agents" {
  work=$(mktemp -d)
  cp "$UPSTREAM" "$work/code-reviewer.md"
  for a in comment-analyzer pr-test-analyzer silent-failure-hunter type-design-analyzer; do
    cp "$UPSTREAM" "$work/${a}.md"
  done
  before=$(cksum "${REPO_ROOT}/agents/code-reviewer.md")
  run --separate-stderr bash "$VENDOR" toolkit --from-dir "$work" --dry-run
  [ "$status" -eq 0 ]
  after=$(cksum "${REPO_ROOT}/agents/code-reviewer.md")
  [ "$before" = "$after" ]
  rm -rf "$work"
}

@test "vendor-pins.json lists exactly the five vendored toolkit agents" {
  jq -e '.["pr-review-toolkit"].agents | length == 5' "${REPO_ROOT}/.github/vendor-pins.json"
  ! jq -e '.["pr-review-toolkit"].agents[] | select(. == "code-simplifier.md")' \
    "${REPO_ROOT}/.github/vendor-pins.json" >/dev/null
}

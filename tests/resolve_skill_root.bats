#!/usr/bin/env bats
# Tests for skill-root and model-config resolvers.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

@test "host skill links resolve to the shipped SKILL.md" {
  REPO_ROOT="${SCRIPTS_DIR}/../../.."
  for link in "${REPO_ROOT}/.grok/skills/code-review-lenses" \
              "${REPO_ROOT}/.claude/skills/code-review-lenses"; do
    [[ -L "$link" ]]
    [[ "$(readlink "$link")" == "../../skills/code-review-lenses" ]]
    [[ -f "$link/SKILL.md" ]]
    root=$(bash "$link/scripts/resolve-skill-root.sh")
    [[ -f "$root/SKILL.md" ]]
  done
}

@test "resolve-skill-root: prints the directory that contains SKILL.md" {
  root=$(bash "${SCRIPTS_DIR}/resolve-skill-root.sh")
  [[ -f "$root/SKILL.md" ]]
  [[ "$root" == *"/skills/code-review-lenses" ]]
  [[ -d "$root/scripts" ]]
}

@test "resolve-models: shipped models.conf is inherit for every agent" {
  eval "$(bash "${SCRIPTS_DIR}/resolve-models.sh")"
  [[ "$ROLE_SUMMARIZER" == "inherit" ]]
  [[ "$ROLE_SPECIALIST" == "inherit" ]]
  [[ "$MODEL_SECURITY_REVIEWER" == "inherit" ]]
  [[ "$MODEL_PR_SUMMARIZER" == "inherit" ]]
}

@test "resolve-models: missing file defaults every agent to inherit" {
  eval "$(bash "${SCRIPTS_DIR}/resolve-models.sh" "$WORK/does-not-exist.conf")"
  [[ "$MODEL_CODE_REVIEWER" == "inherit" ]]
  [[ "$MODEL_BLIND_HUNTER" == "inherit" ]]
}

@test "resolve-models: role and per-agent overrides from a real conf file" {
  cat > "$WORK/models.conf" << 'EOF'
# comment
specialist = my-strong
reviewer=my-review
security-reviewer=my-sec
EOF
  eval "$(bash "${SCRIPTS_DIR}/resolve-models.sh" "$WORK/models.conf")"
  [[ "$ROLE_SPECIALIST" == "my-strong" ]]
  [[ "$MODEL_ARCHITECTURE_REVIEWER" == "my-strong" ]]
  [[ "$MODEL_SECURITY_REVIEWER" == "my-sec" ]]
  [[ "$MODEL_ADVERSARIAL_GENERAL" == "my-strong" ]]
  [[ "$MODEL_CODE_REVIEWER" == "my-review" ]]
  [[ "$MODEL_PR_SUMMARIZER" == "inherit" ]]
}

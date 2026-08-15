#!/usr/bin/env bats
# Tests for the shipped provider detector, including GitLab via glab on
# any authenticated host.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  DETECT="${SCRIPTS_DIR}/detect-provider.sh"
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

@test "detect-provider: github.com HTTPS remote" {
  eval "$(bash "$DETECT" --remote-url https://github.com/acme/app.git)"
  [[ "$PROVIDER" == "github" ]]
  [[ "$HOST" == "github.com" ]]
  [[ "$CLI_TOOL" == "gh" ]]
  [[ "$PR_TERM" == "PR" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
}

@test "detect-provider: gitlab.com nested group via SSH" {
  eval "$(bash "$DETECT" --remote-url git@gitlab.com:group/sub/proj.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$CLI_TOOL" == "glab" ]]
  [[ "$PR_TERM" == "MR" ]]
  [[ "$PR_TERM_LONG" == "merge request" ]]
  [[ "$REPO_SLUG" == "group/sub/proj" ]]
}

@test "detect-provider: hostname containing gitlab is GitLab" {
  eval "$(bash "$DETECT" --remote-url https://gitlab.mycompany.io/team/svc.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$HOST" == "gitlab.mycompany.io" ]]
  [[ "$REPO_SLUG" == "team/svc" ]]
}

@test "detect-provider: GITLAB_HOST matches a custom host" {
  eval "$(GITLAB_HOST=git.corp.example bash "$DETECT" \
    --remote-url git@git.corp.example:team/app.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$HOST" == "git.corp.example" ]]
  [[ "$CLI_TOOL" == "glab" ]]
  [[ "$REPO_SLUG" == "team/app" ]]
}

@test "detect-provider: glab auth status lists a custom host" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "config" ]]; then
  echo ""
  exit 0
fi
if [[ "${1-}" == "auth" ]]; then
  echo "git.internal.corp"
  echo "  ✓ Logged in to git.internal.corp as ci-user (~/.config/glab-cli/config.yml)"
  exit 0
fi
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  eval "$(PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --remote-url https://git.internal.corp/group/sub/app.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$HOST" == "git.internal.corp" ]]
  [[ "$REPO_SLUG" == "group/sub/app" ]]
}

@test "detect-provider: glab config get host matches remote" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "config" && "${2-}" == "get" && "${3-}" == "host" ]]; then
  echo "git.dedicated.example"
  exit 0
fi
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  eval "$(PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --remote-url ssh://git@git.dedicated.example:2222/a/b.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$HOST" == "git.dedicated.example" ]]
}

@test "detect-provider: --provider gitlab forces GitLab on any host" {
  eval "$(bash "$DETECT" --provider gitlab \
    --remote-url git@git.unknown:team/svc.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$CLI_TOOL" == "glab" ]]
  [[ "$REPO_SLUG" == "team/svc" ]]
}

@test "detect-provider: unknown host with no glab auth fails" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= bash "$DETECT" \
    --remote-url git@unknown.example:a/b.git
  [[ "$output" == *"Could not detect git provider"* ]]
  [[ "$output" == *"glab auth login --hostname unknown.example"* ]]
}

@test "detect-provider: --fallback unknown continues without a CLI" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  eval "$(PATH="$WORK/bin:$PATH" GITLAB_HOST= bash "$DETECT" \
    --fallback unknown --remote-url git@unknown.example:a/b.git)"
  [[ "$PROVIDER" == "unknown" ]]
  [[ "$CLI_TOOL" == "" ]]
  [[ "$REPO_SLUG" == "a/b" ]]
}

@test "detect-provider: bitbucket.org" {
  eval "$(bash "$DETECT" --remote-url https://bitbucket.org/acme/app.git)"
  [[ "$PROVIDER" == "bitbucket" ]]
  [[ "$CLI_TOOL" == "curl" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
}

@test "detect-provider: CLI crash stderr does not classify the host" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
echo "fatal: cannot connect to git.broken.example" >&2
exit 99
EOF
  chmod +x "$WORK/bin/glab"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
echo "error: could not authenticate to git.broken.example" >&2
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= bash "$DETECT" \
    --remote-url git@git.broken.example:a/b.git
  [[ "$output" == *"Could not detect git provider"* ]]
  if echo "$output" | grep -q '^PROVIDER=gitlab$'; then
    echo "REGRESSION: classified gitlab from glab stderr" >&2
    return 1
  fi
  if echo "$output" | grep -q '^PROVIDER=github$'; then
    echo "REGRESSION: classified github from gh stderr" >&2
    return 1
  fi
}

@test "detect-provider: does not emit or print HTTPS userinfo" {
  run bash "$DETECT" --remote-url 'https://oauth2:REDACT@gitlab.com/g/p.git'
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'oauth2:'; then
    echo "REGRESSION: userinfo leaked on stdout/stderr" >&2
    return 1
  fi
  if echo "$output" | grep -q 'REDACT'; then
    echo "REGRESSION: password leaked on stdout/stderr" >&2
    return 1
  fi
  if echo "$output" | grep -q '^REMOTE_URL='; then
    echo "REGRESSION: REMOTE_URL is still emitted" >&2
    return 1
  fi
  echo "$output" | grep -q '^PROVIDER=gitlab$'
  echo "$output" | grep -q '^REPO_SLUG=g/p$'
}

@test "detect-provider: --fallback unknown with no origin emits unknown" {
  git -C "$WORK" init -q
  run bash -c "cd \"$WORK\" && bash \"$DETECT\" --fallback unknown"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^PROVIDER=unknown$'
  echo "$output" | grep -q '^CLI_TOOL='\'\''$' || echo "$output" | grep -q '^CLI_TOOL=$'
}

@test "detect-provider: GITLAB_HOST URL form matches hostname" {
  eval "$(GITLAB_HOST=https://git.corp.example bash "$DETECT" \
    --remote-url git@git.corp.example:team/app.git)"
  [[ "$PROVIDER" == "gitlab" ]]
  [[ "$HOST" == "git.corp.example" ]]
}

@test "detect-provider: trailing slash after .git is stripped from slug" {
  eval "$(bash "$DETECT" --remote-url https://github.com/acme/app.git/)"
  [[ "$REPO_SLUG" == "acme/app" ]]
}

@test "detect-provider: --check-url-host allows github.com" {
  run bash "$DETECT" --check-url-host --provider github --host github.com
  [ "$status" -eq 0 ]
}

@test "detect-provider: --check-url-host refuses an unknown GitHub host" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  run -2 env PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --check-url-host --provider github --host evil.example
  [[ "$output" == *"Refusing gh for host 'evil.example'"* ]]
}

@test "detect-provider: --check-url-host unknown provider is exit 2" {
  run -2 bash "$DETECT" --check-url-host --provider unknown --host git.example.com
  [[ "$output" == *"Unknown provider 'unknown'"* ]]
}

@test "detect-provider: --check-url-host empty --host is exit 2" {
  run -2 bash "$DETECT" --check-url-host --provider github --host
  [[ "$status" -eq 2 ]]
}

@test "detect-provider: github --check-url-host does not allow a host only because it matches origin" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  git -C "$WORK" init -q
  git -C "$WORK" remote add origin git@evil.example:org/repo.git
  run -2 env PATH="$WORK/bin:$PATH" bash -c "cd '$WORK' && bash '$DETECT' --check-url-host --provider github --host evil.example"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Refusing gh for host 'evil.example'"* ]]
}

@test "detect-provider: gitlab --check-url-host does not allow a host only because it matches origin" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  git -C "$WORK" init -q
  git -C "$WORK" remote add origin git@evil.gitlab.example:org/repo.git
  run -2 env PATH="$WORK/bin:$PATH" bash -c "cd '$WORK' && bash '$DETECT' --check-url-host --provider gitlab --host evil.gitlab.example"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Refusing glab for host 'evil.gitlab.example'"* ]]
}

@test "detect-provider: gitlab --check-url-host allows a host listed by glab auth" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "auth" ]]; then
  echo "git.internal.corp"
  echo "  ✓ Logged in to git.internal.corp as ci-user"
  exit 0
fi
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --check-url-host --provider gitlab --host git.internal.corp
  [ "$status" -eq 0 ]
}

@test "detect-provider: gitlab --check-url-host refuses when GITLAB_HOST does not equal HOST" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST=git.corp.example bash "$DETECT" \
    --check-url-host --provider gitlab --host evil.gitlab.example
  [ "$status" -eq 2 ]
  [[ "$output" == *"Refusing glab"* ]]
}

@test "detect-provider: gitlab --check-url-host refuses when glab lists a different host" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "auth" ]]; then
  echo "git.internal.corp"
  exit 0
fi
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run -2 env PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --check-url-host --provider gitlab --host evil.gitlab.example
  [ "$status" -eq 2 ]
  [[ "$output" == *"Refusing glab"* ]]
}

@test "detect-provider: gitlab --check-url-host allows GITLAB_HOST" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST=git.corp.example bash "$DETECT" \
    --check-url-host --provider gitlab --host git.corp.example
  [ "$status" -eq 0 ]
}

@test "detect-provider: bitbucket --check-url-host allows bitbucket.org" {
  run bash "$DETECT" --check-url-host --provider bitbucket --host bitbucket.org
  [ "$status" -eq 0 ]
}

@test "detect-provider: bitbucket --check-url-host refuses a non-Cloud host" {
  run -2 bash "$DETECT" --check-url-host --provider bitbucket --host bitbucket.example.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"Bitbucket Cloud only"* ]]
}

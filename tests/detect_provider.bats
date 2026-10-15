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

@test "detect-provider: scp-like remote with a non-git SSH user" {
  eval "$(bash "$DETECT" --remote-url org-123@github.com:acme/app.git)"
  [[ "$PROVIDER" == "github" ]]
  [[ "$HOST" == "github.com" ]]
  [[ "$REPO_SLUG" == "acme/app" ]]
}

@test "detect-provider: *.ghe.com remote is GitHub without gh auth" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  cp "$WORK/bin/gh" "$WORK/bin/glab"
  eval "$(PATH="$WORK/bin:$PATH" bash "$DETECT" --remote-url https://acme.ghe.com/org/app.git)"
  [[ "$PROVIDER" == "github" ]]
  [[ "$REPO_SLUG" == "org/app" ]]
}

@test "detect-provider: GitHub remote path that is not owner/repo is exit 2" {
  run -2 bash "$DETECT" --remote-url https://github.com/app.git
  run -2 bash "$DETECT" --remote-url https://github.com/acme/app/extra.git
  [[ "$output" == *"Could not extract a valid repository slug"* ]]
}

@test "detect-provider: --check-url-host does not accept other *.github.com hosts by name" {
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
  chmod +x "$WORK/bin/gh"
  run -2 env PATH="$WORK/bin:$PATH" GH_HOST= bash "$DETECT" --check-url-host --provider github --host www.github.com
  [[ "$output" == *"Refusing gh for host 'www.github.com'"* ]]
  run -2 env PATH="$WORK/bin:$PATH" GH_HOST= bash "$DETECT" --check-url-host --provider github --host gist.github.com
  run env PATH="$WORK/bin:$PATH" GH_HOST= bash "$DETECT" --check-url-host --provider github --host acme.ghe.com
  [ "$status" -eq 0 ]
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
if [[ "$*" == "auth status --hostname git.internal.corp" ]]; then
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

@test "detect-provider: glab host check ignores other hosts' auth failures (glab 1.117)" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
# glab 1.117: report on stderr only; bare `auth status` exits 1 if any host fails.
case "$*" in
  "auth status --hostname git.internal.corp")
    echo "  ✓ Logged in to git.internal.corp as ci-user" >&2
    exit 0
    ;;
  "auth status")
    echo "gitlab.com" >&2
    echo "  x gitlab.com: API call failed: 401 {message: 401 Unauthorized}" >&2
    echo "git.internal.corp" >&2
    echo "  ✓ Logged in to git.internal.corp as ci-user" >&2
    exit 1
    ;;
esac
echo "  X not authenticated with glab" >&2
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST= GL_HOST= bash "$DETECT" \
    --check-url-host --provider gitlab --host git.internal.corp
  [ "$status" -eq 0 ]
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= GL_HOST= bash "$DETECT" \
    --check-url-host --provider gitlab --host git.broken.example
  [[ "$output" == *"Refusing glab for host 'git.broken.example'"* ]]
  eval "$(PATH="$WORK/bin:$PATH" GITLAB_HOST= GL_HOST= bash "$DETECT" \
    --remote-url git@git.internal.corp:group/app.git)"
  [[ "$PROVIDER" == "gitlab" ]]
}

@test "detect-provider: gh host check ignores other hosts' auth failures" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
# gh: a failing account on any host makes bare `auth status` exit 1, report on stderr.
case "$*" in
  "auth status --hostname ghe.corp.example --active")
    echo "  ✓ Logged in to ghe.corp.example account ci-user"
    exit 0
    ;;
  "auth status")
    echo "ghe.corp.example" >&2
    echo "  ✓ Logged in to ghe.corp.example account ci-user" >&2
    echo "broken.corp.example" >&2
    echo "  X Failed to log in to broken.corp.example account nobody" >&2
    exit 1
    ;;
esac
echo "You are not logged into any accounts on that host" >&2
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  run env PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --check-url-host --provider github --host ghe.corp.example
  [ "$status" -eq 0 ]
  run -2 env PATH="$WORK/bin:$PATH" bash "$DETECT" \
    --check-url-host --provider github --host broken.corp.example
  [[ "$output" == *"Refusing gh for host 'broken.corp.example'"* ]]
}

@test "detect-provider: gitlab --check-url-host does not trust glab's configured default host" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
if [[ "$*" == "config get host" ]]; then
  echo "git.dedicated.example"
  exit 0
fi
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= GL_HOST= bash "$DETECT" \
    --check-url-host --provider gitlab --host git.dedicated.example
  [[ "$output" == *"Refusing glab for host 'git.dedicated.example'"* ]]
}

@test "detect-provider: gitlab --check-url-host follows glab's env host precedence" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI=https://git.corp.example GL_HOST=git.other.example \
    bash "$DETECT" --check-url-host --provider gitlab --host git.corp.example
  [ "$status" -eq 0 ]
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI=https://git.corp.example GL_HOST=git.other.example \
    bash "$DETECT" --check-url-host --provider gitlab --host git.other.example
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST=git.first.example GITLAB_URI=https://git.corp.example GL_HOST= \
    bash "$DETECT" --check-url-host --provider gitlab --host git.first.example
  [ "$status" -eq 0 ]
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST=git.first.example GITLAB_URI=https://git.corp.example GL_HOST= \
    bash "$DETECT" --check-url-host --provider gitlab --host git.corp.example
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

@test "detect-provider: gitlab --check-url-host allows gitlab.com without probing glab" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
touch "$PROBED_FILE"
exit 1
EOF
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GITLAB_HOST= GITLAB_URI= GL_HOST= \
    bash "$DETECT" --check-url-host --provider gitlab --host gitlab.com
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/probed" ]
}

@test "detect-provider: gitlab --check-url-host probes glab with every glab env token unset" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
printf '%s=%s\n' \
  GITLAB_TOKEN "${GITLAB_TOKEN-unset}" \
  GITLAB_ACCESS_TOKEN "${GITLAB_ACCESS_TOKEN-unset}" \
  OAUTH_TOKEN "${OAUTH_TOKEN-unset}" \
  CI_JOB_TOKEN "${CI_JOB_TOKEN-unset}" > "$SEEN_FILE"
exit 0
EOF
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" SEEN_FILE="$WORK/seen" GITLAB_HOST= GITLAB_URI= GL_HOST= CI_JOB_TOKEN=t4 \
    bash "$DETECT" --check-url-host --provider gitlab --host git.internal.corp
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/seen")" = $'GITLAB_TOKEN=unset\nGITLAB_ACCESS_TOKEN=unset\nOAUTH_TOKEN=unset\nCI_JOB_TOKEN=unset' ]
}

@test "detect-provider: gitlab --check-url-host refuses a host with stored credentials while an env token for glab's host is set" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
touch "$PROBED_FILE"
exit 0
EOF
  chmod +x "$WORK/bin/glab"
  for tok in GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN; do
    run -2 env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GITLAB_HOST=gitlab.corp.example GITLAB_URI= GL_HOST= "$tok=t1" \
      bash "$DETECT" --check-url-host --provider gitlab --host gitlab.com
    [[ "$output" == *"would be sent to it, and they belong to gitlab.corp.example"* ]]
    run -2 env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GITLAB_HOST= GITLAB_URI= GL_HOST= "$tok=t1" \
      bash "$DETECT" --check-url-host --provider gitlab --host git.other.example
    [[ "$output" == *"they belong to gitlab.com"* ]]
  done
  [ ! -e "$WORK/probed" ]
  run env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GITLAB_HOST=gitlab.corp.example GITLAB_URI= GL_HOST= GITLAB_TOKEN=t1 \
    bash "$DETECT" --check-url-host --provider gitlab --host GitLab.Corp.Example
  [ "$status" -eq 0 ]
}

@test "detect-provider: gitlab --check-url-host refuses an unknown host that only an env token authenticates" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
[[ -n "${GITLAB_TOKEN-}" ]]
EOF
  chmod +x "$WORK/bin/glab"
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GITLAB_TOKEN=t1 \
    bash "$DETECT" --check-url-host --provider gitlab --host evil.example
  [[ "$output" == *"Refusing glab for host 'evil.example'"* ]]
}

@test "detect-provider: github --check-url-host allows GH_HOST without probing gh" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
touch "$PROBED_FILE"
exit 1
EOF
  chmod +x "$WORK/bin/gh"
  run env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GH_HOST=GHE.Corp.Example \
    bash "$DETECT" --check-url-host --provider github --host ghe.corp.example
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/probed" ]
  run -2 env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GH_HOST=ghe.other.example \
    bash "$DETECT" --check-url-host --provider github --host ghe.corp.example
  [[ "$output" == *"Refusing gh for host 'ghe.corp.example'"* ]]
}

@test "detect-provider: github --check-url-host probes gh with every gh env token unset" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
printf '%s=%s\n' \
  GH_TOKEN "${GH_TOKEN-unset}" \
  GITHUB_TOKEN "${GITHUB_TOKEN-unset}" \
  GH_ENTERPRISE_TOKEN "${GH_ENTERPRISE_TOKEN-unset}" \
  GITHUB_ENTERPRISE_TOKEN "${GITHUB_ENTERPRISE_TOKEN-unset}" > "$SEEN_FILE"
exit 0
EOF
  chmod +x "$WORK/bin/gh"
  run env PATH="$WORK/bin:$PATH" SEEN_FILE="$WORK/seen" GH_HOST= GH_TOKEN=t1 GITHUB_TOKEN=t2 \
    bash "$DETECT" --check-url-host --provider github --host ghe.corp.example
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/seen")" = $'GH_TOKEN=unset\nGITHUB_TOKEN=unset\nGH_ENTERPRISE_TOKEN=unset\nGITHUB_ENTERPRISE_TOKEN=unset' ]
}

@test "detect-provider: gitlab --check-url-host refuses any host but CI_SERVER_FQDN while CI auto-login has a job token" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK/bin/glab"
  for host in git.other.example gitlab.com; do
    for on in true 1 t TRUE True yes; do
      run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GLAB_ENABLE_CI_AUTOLOGIN="$on" CI_JOB_TOKEN=j CI_SERVER_FQDN=GitLab.CI.Example \
        bash "$DETECT" --check-url-host --provider gitlab --host "$host"
      [[ "$output" == *"CI_JOB_TOKEN, which belongs to GitLab.CI.Example"* ]]
    done
  done
  for off in 0 f false FALSE False; do
    run env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GLAB_ENABLE_CI_AUTOLOGIN="$off" CI_JOB_TOKEN=j CI_SERVER_FQDN=gitlab.ci.example \
      bash "$DETECT" --check-url-host --provider gitlab --host git.other.example
    [ "$status" -eq 0 ]
  done
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GLAB_ENABLE_CI_AUTOLOGIN=true CI_JOB_TOKEN=j CI_SERVER_FQDN=GitLab.CI.Example \
    bash "$DETECT" --check-url-host --provider gitlab --host gitlab.ci.example
  [ "$status" -eq 0 ]
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GLAB_ENABLE_CI_AUTOLOGIN= CI_JOB_TOKEN=j CI_SERVER_FQDN=gitlab.ci.example \
    bash "$DETECT" --check-url-host --provider gitlab --host git.other.example
  [ "$status" -eq 0 ]
}

@test "detect-provider: github --check-url-host refuses a GHES host with stored credentials while an enterprise token for GH_HOST is set" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
touch "$PROBED_FILE"
exit 0
EOF
  chmod +x "$WORK/bin/gh"
  for tok in GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    run -2 env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GH_HOST=ghe.corp.example "$tok=t3" \
      bash "$DETECT" --check-url-host --provider github --host ghe.other.example
    [[ "$output" == *"would be sent to it, and GH_HOST is not that host"* ]]
  done
  [ ! -e "$WORK/probed" ]
  run env PATH="$WORK/bin:$PATH" PROBED_FILE="$WORK/probed" GH_HOST=ghe.corp.example GH_ENTERPRISE_TOKEN=t3 \
    bash "$DETECT" --check-url-host --provider github --host ghe.corp.example
  [ "$status" -eq 0 ]
}

@test "detect-provider: github --check-url-host refuses an unknown host that only an env token authenticates" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
[[ -n "${GH_ENTERPRISE_TOKEN-}" ]]
EOF
  chmod +x "$WORK/bin/gh"
  run -2 env PATH="$WORK/bin:$PATH" GH_HOST= GH_ENTERPRISE_TOKEN=t3 \
    bash "$DETECT" --check-url-host --provider github --host evil.example
  [[ "$output" == *"Refusing gh for host 'evil.example'"* ]]
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

@test "detect-provider: a www.github.com remote is reported as github.com, as parse-pr-url.sh normalizes it" {
  run bash "$DETECT" --provider github --remote-url https://www.github.com/acme/app.git
  [ "$status" -eq 0 ]
  grep -qx 'HOST=github.com' <<<"$output"
  grep -qx 'REPO_SLUG=acme/app' <<<"$output"
}

@test "detect-provider: a filesystem origin is PROVIDER=unknown with --fallback unknown, an error without it" {
  for url in /tmp/repo.git ./repo ../repo file:///tmp/repo.git repo.git sub/repo.git sub/dir:repo.git; do
    run bash "$DETECT" --remote-url "$url" --fallback unknown
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROVIDER=unknown"* ]] || { echo "not unknown: $url" >&2; return 1; }
  done
  run -2 bash "$DETECT" --remote-url /tmp/repo.git
  [[ "$output" == *"Unrecognized remote URL"* ]] || return 1
  run -2 bash "$DETECT" --remote-url repo.git
  [[ "$output" == *"Unrecognized remote URL"* ]]
}

@test "detect-provider: local detection matches GH_HOST directly and probes only with CLI env tokens unset" {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" << 'EOF'
#!/usr/bin/env bash
printf 'gh %s %s %s %s\n' "${GH_TOKEN-u}" "${GITHUB_TOKEN-u}" "${GH_ENTERPRISE_TOKEN-u}" "${GITHUB_ENTERPRISE_TOKEN-u}" >> "$SEEN_FILE"
exit 1
EOF
  cat > "$WORK/bin/glab" << 'EOF'
#!/usr/bin/env bash
printf 'glab %s %s %s %s\n' "${GITLAB_TOKEN-u}" "${GITLAB_ACCESS_TOKEN-u}" "${OAUTH_TOKEN-u}" "${CI_JOB_TOKEN-u}" >> "$SEEN_FILE"
exit 1
EOF
  chmod +x "$WORK/bin/gh" "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" SEEN_FILE="$WORK/seen" GH_HOST=GHE.Corp.Example GITLAB_HOST= GITLAB_URI= GL_HOST= \
    bash "$DETECT" --remote-url https://ghe.corp.example/acme/app.git
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVIDER=github"* ]]
  [ ! -e "$WORK/seen" ]
  run env PATH="$WORK/bin:$PATH" SEEN_FILE="$WORK/seen" GH_HOST= GITLAB_HOST= GITLAB_URI= GL_HOST= \
    GH_TOKEN=a GITHUB_TOKEN=b GH_ENTERPRISE_TOKEN=c GITHUB_ENTERPRISE_TOKEN=d GITLAB_TOKEN=e GITLAB_ACCESS_TOKEN=f OAUTH_TOKEN=g CI_JOB_TOKEN=h \
    bash "$DETECT" --remote-url https://git.attacker.example/acme/app.git --fallback unknown
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROVIDER=unknown"* ]]
  [ "$(sort -u "$WORK/seen")" = $'gh u u u u\nglab u u u u' ]
}

@test "detect-provider: gitlab --check-url-host accepts CI_SERVER_FQDN under glab's CI auto-login" {
  mkdir -p "$WORK/bin"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/glab"
  chmod +x "$WORK/bin/glab"
  run env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GLAB_ENABLE_CI_AUTOLOGIN=true GITLAB_CI=true CI_JOB_TOKEN=j CI_SERVER_FQDN=gitlab.ci.example \
    bash "$DETECT" --check-url-host --provider gitlab --host gitlab.ci.example
  [ "$status" -eq 0 ]
  run -2 env PATH="$WORK/bin:$PATH" GITLAB_HOST= GITLAB_URI= GL_HOST= GLAB_ENABLE_CI_AUTOLOGIN=true GITLAB_CI= CI_JOB_TOKEN=j CI_SERVER_FQDN=gitlab.ci.example \
    bash "$DETECT" --check-url-host --provider gitlab --host gitlab.ci.example
}

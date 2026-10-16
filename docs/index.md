---
layout: home
title: Home
nav_exclude: true
permalink: /
render_with_liquid: false
hero_title: Code Review Lenses
hero_tagline: "Host-agnostic PR/MR review using parallel specialized agents. Local summary + severity-ranked findings — no PR posting."
---

<div class="features">
  <div class="feature">
    <h3><span class="feature-icon">&#9670;</span> 12 Specialized Agents</h3>
    <p>Parallel fleet: OWASP security, architecture, blind "fresh eyes" review, edge-case path tracing, and more — coordinated by one skill.</p>
  </div>
  <div class="feature">
    <h3><span class="feature-icon">&#9670;</span> Deterministic Checks</h3>
    <p>CVE lookup via OSV.dev plus opportunistic static analyzers (shellcheck, semgrep, trufflehog, ruff, golangci-lint, checkov, eslint, and more).</p>
  </div>
  <div class="feature">
    <h3><span class="feature-icon">&#9670;</span> GitHub, GitLab, Bitbucket</h3>
    <p>Auto-detects the host. GitLab uses <code>glab</code> on any authenticated instance. A PR/MR URL checks out that change for local analysis only.</p>
  </div>
  <div class="feature">
    <h3><span class="feature-icon">&#9670;</span> Profiles, not mode soup</h3>
    <p><code>--profile quick|security|full|deep</code> selects the roster. Default is <code>full</code>. Nothing is posted.</p>
  </div>
</div>

## What it does

`/code-review-lenses` launches specialized agents, normalizes their findings, and prints Block A (summary) and Block B (findings). Output stays in the terminal (or `--output-file`). The pipeline never creates or comments on a PR/MR.

## Quick start

Point your Agent Skills host at this repository (or symlink `skills/code-review-lenses` into the host's skill directory and keep the full checkout so the skill can resolve its sibling `agents/` directory). Then:

```
/code-review-lenses
/code-review-lenses --profile quick
/code-review-lenses --profile security
/code-review-lenses --profile deep
/code-review-lenses https://github.com/acme/app/pull/42
```

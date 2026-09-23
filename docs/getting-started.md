---
layout: default
title: Getting Started
nav_order: 1
render_with_liquid: false
---

# Getting Started

## Installation

This is an [Agent Skills](https://agentskills.io/specification) package, not a
host-specific plugin. A clone of this repo is enough for Codex, Claude, and Grok:
`.agents/skills/code-review-lenses`, `.claude/skills/code-review-lenses`, and
`.grok/skills/code-review-lenses` are relative links to the shipped skill.

Codex invokes `$code-review-lenses` and loads the Markdown agent prompts into
native subagents. No custom-agent registration is needed.

For use from other repositories, symlink `skills/code-review-lenses/` into
the host's user skill directory (`~/.agents/skills/` for Codex). Keep the full
checkout available so the skill can resolve its sibling `agents/` directory.

The orchestrator finds its own files via `scripts/resolve-skill-root.sh`.

## Requirements

| Requirement | Notes |
|-------------|-------|
| Agent Skills host with subagent tools | Claude, Codex, Grok, Cursor, Copilot, … |
| `git` | Diff analysis |
| `jq` | Findings pipeline |
| [gh CLI](https://cli.github.com/) | GitHub PR URL only |
| [glab CLI](https://gitlab.com/gitlab-org/cli) | GitLab MR URL only; any authenticated host |
| `BITBUCKET_EMAIL` + `BITBUCKET_TOKEN` | Bitbucket PR URL only |

## First review

Run it inside a clone of the repository you want to review; without `--base`,
a local review compares the checked-out branch against its upstream
(`HEAD@{upstream}`) and stops if there is none.

In Codex:

```text
$code-review-lenses --profile quick
```

In Claude or Grok:

```
/code-review-lenses
```

Use `--profile quick` for a cheaper pass, `--profile security` for the security
axis only, `--profile deep` for extended specialist reasoning plus CVE
reachability, or pass a PR/MR URL to analyze that change locally.

## GitLab

```bash
glab auth login --hostname git.example.com
/code-review-lenses https://git.example.com/g/p/-/merge_requests/7
```

Self-hosted and dedicated hosts work as long as `glab auth status` lists them
(or `GITLAB_HOST` matches the remote hostname).

## Workflow wrappers

On Claude or Grok you can run the review as a host workflow instead of
walking the skill turn-by-turn. The skill remains the source of truth; the
wrappers launch the shipped parsers and `agents/*.md` (Phase 0–1b, 2, 3, 5).
Phase 0c and Phase 1c run only on the skill path.

```
/code-review-lenses-workflow
/code-review-lenses-workflow --profile quick
/code-review-lenses-workflow review <pr-or-mr-url> focus on auth
```

Same argv as the skill (flags plus optional free-form). JSON
`{ "arguments": "--profile deep https://github.com/acme/app/pull/42" }` is that same string.

| Host | Wrapper |
|------|---------|
| Claude | `.claude/workflows/code-review-lenses-workflow.js` |
| Grok | `.grok/workflows/code-review-lenses-workflow.rhai` |

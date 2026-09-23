# AGENTS.md

This repository is a host-agnostic Agent Skills package: a review orchestrator
(`skills/code-review-lenses/SKILL.md`) plus specialized agents (`agents/*.md`).

It follows the [Agent Skills](https://agentskills.io/specification) layout
(`SKILL.md` + `scripts/` + references) so any compatible host (Claude, Codex,
Grok, Cursor, Copilot, …) can load it.

## What this package is

A **local** code-review pipeline. It reads a git diff (current branch or
PR/MR URL checkout) and prints Block A (summary) and Block B (findings).
It does not create, comment on, or update PRs/MRs.

## Layout

```
skills/code-review-lenses/SKILL.md     orchestrator
skills/code-review-lenses/scripts/     shipped parsers + analyzers
skills/code-review-lenses/models.conf  optional model routing (default: inherit)
agents/*.md                              12 review agents
.claude/workflows/*.js                   Claude workflow wrapper (optional)
.grok/workflows/*.rhai                   Grok workflow wrapper (optional)
tests/*.bats                             bats + jq; run: bats tests/*.bats
```

## Editing rules

- `SKILL.md` is the workflow source of truth. Roster and flags are implemented
  in `scripts/resolve-profile.sh` and `scripts/apply-roster-overlays.sh` —
  do not re-implement them in prose only. Host wrappers under `.claude/workflows/`
  and `.grok/workflows/` invoke those parsers; they must not fork the roster.
- Provider detection (including GitLab via `glab` on any authenticated host)
  lives in `scripts/detect-provider.sh`. External review host+number comes
  from `scripts/parse-pr-url.sh` (a PR/MR URL, never `--pr` / `--provider`).
- Models are never hardcoded. Change `models.conf` or leave `inherit`.
- Do not add posting, PR-creation, or host-plugin install paths.
- Vendored toolkit agents are Apache-2.0; see `agents/THIRD_PARTY.md`.
  Nightly refresh: `scripts/vendor-sync.sh` + `.github/workflows/vendor-sync.yml`.
  Do not hand-edit those five files except through that transform.
- `blind-hunter` must receive only the diff (plus GOVERNANCE). No project context.
- Language guidance belongs in `language-profiles/`, not in agent prompts.
- `json-findings` contract: `severity`, `confidence`, `file`, `line`, `finding`,
  `remediation`, `source`. See `SEVERITY.md`.
- Comments only for hidden constraints. No changelog comments in source.

## Tests

```
bats tests/*.bats
```

Requires `bats` and `jq`. New orchestration behavior needs a test of the
shipped script, not only a grep of SKILL.md.

## Profiles

Pass `--profile quick|security|full|deep` (default `full`).

| Profile | Roster |
|---------|--------|
| `quick` | summarizer + code-reviewer + triggered error/test agents + CVE + static analyzers |
| `security` | security-reviewer + CVE + static analyzers |
| `full` | all agents (default) |
| `deep` | full + extended thinking + CVE reachability |
| `--summary-only` | pr-summarizer only |

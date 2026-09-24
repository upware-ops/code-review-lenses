---
layout: default
title: Usage & Flags
nav_order: 2
render_with_liquid: false
---

# Usage & Flags

```
/code-review-lenses [flags] [free-form]
```

Everything is local. There is no posting flag.

## Profiles

`--profile <name>` (default `full`). `--summary-only` is mutually exclusive with `--profile`.

| Profile | Roster |
|---------|--------|
| **quick** | pr-summarizer, code-reviewer, triggered silent-failure-hunter / pr-test-analyzer, CVE + static analyzers |
| **security** | security-reviewer, CVE + static analyzers |
| **full** | All agents + triggered conditionals + deterministic checks (default) |
| **deep** | Same as full + `EXTENDED_THINKING` for architecture/security + CVE reachability. No auto-cheap. |

Removed: `--quick`, `--security-only`, `--depth`. The parser rejects them.

## Flags

| Flag | Effect |
|------|--------|
| `--profile <name>` | `quick` \| `security` \| `full` \| `deep` |
| `--summary-only` | pr-summarizer only |
| `--base <branch>` | Override compare base. PR/MR URL: fetched target branch. Local: `HEAD@{upstream}` only. Never `main`/`master`/`dev`. |
| `--no-enrich-context` | Disable symbol-context enrichment |
| `--no-suppress` | Disable suppression rules |
| `--min-confidence N` | Drop findings below N (default 75) |
| `--output-file <path>` | Write Block A + Block B to a file |
| PR/MR URL | External review. Host and number come from the URL. |
| free-form text | Remaining leftover is review focus |

Removed: `--pr`, `--provider`, `--post-findings`, `--post-summary`, `--create-pr`, `--publish`, `--draft`, `--read-back`, `--no-post`, `--local`, `--no-mem`, `--no-findings`.

## Workflow wrappers

Same review, host holds the loop. Roster still comes from the shipped parsers.

```
/code-review-lenses-workflow
/code-review-lenses-workflow --profile quick
/code-review-lenses-workflow review <url> focus on auth
```

Same `$ARGUMENTS` as the skill. Files:
`.claude/workflows/code-review-lenses-workflow.js` (Claude),
`.grok/workflows/code-review-lenses-workflow.rhai` (Grok).

## Auto-cheap (full profile only)

- **DOCS_ONLY** — no code/infra in the diff
- **LOW_RISK_CONFIG** — config-only, no security patterns

`--profile deep` does not auto-cheap.

**TIER=tiny** (<50 lines and ≤3 files) applies to every profile, deep included: hunters skipped; architecture/security only if promoted (`--profile security` still runs security-reviewer).

## Examples

```
/code-review-lenses
/code-review-lenses --profile quick
/code-review-lenses --profile security
/code-review-lenses --profile deep
/code-review-lenses --summary-only
/code-review-lenses https://github.com/acme/app/pull/42
/code-review-lenses review https://gitlab.example/g/p/-/merge_requests/7 focus on auth
/code-review-lenses --output-file review.md
```

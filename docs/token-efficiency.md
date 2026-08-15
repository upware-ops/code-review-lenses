---
layout: default
title: Token Efficiency
nav_order: 6
render_with_liquid: false
---

# Token Efficiency

The skill uses a tiered context-passing strategy to keep the agent fleet cheap.

## Tiered context passing

| Diff size | Strategy |
|-----------|---------|
| **TIER=tiny** (<50 lines AND ≤3 files) | Full diff inline; hunters and comment/type agents skipped; architecture/security only if promoted |
| **Small** (<300 lines) | Full diff inline to scheduled agents |
| **Medium/large** (300+ lines) | Custom agents get a file manifest and read `git diff <base>...HEAD -- <file>`. Conditional agents get specialty slices. Lockfiles and vendor dirs are excluded from the manifest |

## Profiles as the cost control

| Profile | Relative cost |
|---------|----------------|
| `--summary-only` | Lowest — one agent |
| `--profile quick` | Cheap — summarizer + code-reviewer + triggered error/test + CVE |
| `--profile security` | Security-reviewer + CVE only |
| `--profile full` | Default roster; auto-cheap still applies |
| `--profile deep` | Full roster + extended thinking + CVE reachability; no auto-cheap |

Models default to `inherit`. Pin them in `models.conf` if the host supports it.

**`--output-file <path>`** writes the report during the session so you do not have to re-run just to save it.

## Other savings

- Orchestrator reads `AGENTS.md` and the commit log once and shares condensed copies
- FILE_DIGEST (stat + first hunk) goes to architecture/security so they spend fewer discovery calls
- Tool budget 25 for architecture-reviewer and security-reviewer
- blind-hunter receives only the diff
- Scope boundaries stop agents from re-doing each other's work

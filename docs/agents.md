---
layout: default
title: Agents
nav_order: 3
render_with_liquid: false
---

# Agents

All 12 agents ship in `agents/`. Five were adapted from pr-review-toolkit
(Apache-2.0; see `agents/THIRD_PARTY.md`). Models default to **inherit**.

## Roster

| Agent | Axis | Profiles |
|-------|------|----------|
| **pr-summarizer** | Block A summary | quick, full, deep, `--summary-only` |
| **code-reviewer** | Tactical bugs and style | quick, full, deep |
| **architecture-reviewer** | Coupling, API surface, structural debt | full, deep |
| **security-reviewer** | OWASP-class and dependency security | security, full, deep |
| **blind-hunter** | Zero-context orthogonal review | full, deep |
| **edge-case-hunter** | Whether a handling path exists | full, deep (control-flow gate) |
| **adversarial-general** | Completeness, ops, docs debt | full, deep |
| **issue-linker** | Related GitHub issues/PRs | full, deep (GitHub only) |
| **silent-failure-hunter** | Error-handling adequacy | quick, full, deep (error-pattern gate) |
| **pr-test-analyzer** | Test coverage gaps | quick, full, deep (test-file gate) |
| **comment-analyzer** | Comment accuracy / rot | full, deep |
| **type-design-analyzer** | Type / struct / interface design | full, deep |

`deep` adds `EXTENDED_THINKING` for architecture-reviewer and security-reviewer,
plus CVE reachability. TIER=tiny still skips hunters and comment/type agents.

## Scope boundaries

- **security-reviewer** owns dependency security; **architecture-reviewer** owns architectural implications
- **security-reviewer** does not report error-handling quality — that is **silent-failure-hunter**
- **architecture-reviewer** does not report code-level style — that is **code-reviewer**
- **blind-hunter** receives zero project context. Overlap is expected and later deduplicated
- **edge-case-hunter** asks whether a handling path exists; **silent-failure-hunter** asks whether existing handling is adequate
- **adversarial-general** covers completeness and operational gaps that specialists are scoped not to cover

## Symbol context

On full/deep runs except TIER=tiny, symbol definitions are injected into
architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter,
and code-reviewer. Never into blind-hunter or pr-summarizer. Disable with
`--no-enrich-context`.

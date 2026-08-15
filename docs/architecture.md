---
layout: default
title: Architecture
nav_order: 11
render_with_liquid: false
---

# Architecture

## File layout

```
AGENTS.md                                                    ← host-agnostic project instructions
skills/code-review-lenses/SKILL.md                         ← orchestrator: phases 0–3 and 5 (local only)
skills/code-review-lenses/models.conf                      ← optional model routing (default: inherit)
skills/code-review-lenses/scripts/resolve-profile.sh       ← --profile / flag parser
skills/code-review-lenses/scripts/parse-pr-url.sh          ← PR/MR URL → host + number
skills/code-review-lenses/scripts/review-diff.sh           ← committed vs dirty vs empty range
skills/code-review-lenses/scripts/apply-roster-overlays.sh ← TIER / docs-only / gate overlays
skills/code-review-lenses/scripts/detect-provider.sh       ← GitHub / GitLab (any glab host) / Bitbucket
skills/code-review-lenses/HELP.md                          ← usage reference
skills/code-review-lenses/SEVERITY.md                      ← severity normalization + confidence scale
skills/code-review-lenses/GOVERNANCE.md                    ← shared governance directives (inlined into every custom agent)
skills/code-review-lenses/suppressions.json                ← global suppression rules
skills/code-review-lenses/language-profiles/               ← per-language context profiles (19 languages)
skills/code-review-lenses/scripts/run-cve-check.sh         ← deterministic CVE check via OSV.dev (Phase 1b)
skills/code-review-lenses/scripts/run-shellcheck.sh        ← ShellCheck (Phase 1b)
skills/code-review-lenses/scripts/run-semgrep.sh           ← Semgrep SAST (Phase 1b)
skills/code-review-lenses/scripts/run-trufflehog.sh        ← TruffleHog secret scanning (Phase 1b)
skills/code-review-lenses/scripts/run-ruff.sh              ← Ruff Python linting (Phase 1b)
skills/code-review-lenses/scripts/run-golangci-lint.sh     ← golangci-lint Go analysis (Phase 1b)
skills/code-review-lenses/scripts/run-checkov.sh           ← checkov IaC security scanning (Phase 1b)
skills/code-review-lenses/scripts/run-eslint.sh            ← ESLint (Phase 1b)
skills/code-review-lenses/scripts/run-hadolint.sh          ← Hadolint (Phase 1b)
skills/code-review-lenses/scripts/run-kube-linter.sh       ← kube-linter (Phase 1b)
skills/code-review-lenses/scripts/run-phpcs.sh             ← PHP CodeSniffer (Phase 1b)
skills/code-review-lenses/scripts/run-phpstan.sh           ← PHPStan (Phase 1b)
skills/code-review-lenses/scripts/run-tflint.sh            ← tflint (Phase 1b)
agents/*.md                                                  ← 12 review agents (self-contained)
.claude/workflows/code-review-lenses-workflow.js             ← Claude dynamic-workflow wrapper (optional)
.claude/skills/code-review-lenses                            ← symlink → skills/code-review-lenses
.grok/workflows/code-review-lenses-workflow.rhai             ← Grok workflow wrapper (optional)
.grok/skills/code-review-lenses                              ← symlink → skills/code-review-lenses
tests/                                                       ← bats suite (shipped-script + analyzer tests)
```

## Phase overview

There is no Phase 4. Output is local.

**Phase 0 — Setup**
- `resolve-profile.sh` parses `--profile` / flags
- `parse-pr-url.sh` extracts host + number from a PR/MR URL
- `detect-provider.sh` for local remotes only (GitLab via `glab` on any authenticated host)
- Diff, TIER, language profiles, commit log, `AGENTS.md`
- Symbol context (Phase 0c) unless the profile/tier disables it
- GOVERNANCE + optional security-guidance.md
- `apply-roster-overlays.sh` applies TIER / docs-only / gates

**Phase 1 — Agents**
- Spawn by bare agent name; model only if `models.conf` is not `inherit`
- Phase 1b deterministic CVE + static analyzers
- Phase 1c CVE reachability when `--profile deep`

**Phase 2 — Normalize**
- json-findings extract, confidence filter, suppressions, proximity dedup, secret redaction

**Phase 3 — Blocks**
- Block A + Block B

**Phase 5 — Output**
- Terminal (and optional `--output-file`)
- Worktree cleanup for a PR/MR URL checkout

## Two-block output design

| Block | Content | Audience |
|-------|---------|----------|
| **Block A** | Summary, walkthrough table, effort estimate, related issues/PRs | PR authors, reviewers — informational |
| **Block B** | Severity-ranked findings from all agents and analyzers | PR authors, reviewers — actionable |

Both blocks are always shown locally in the terminal (and optionally `--output-file`). Nothing is posted to a hosting provider.

## Severity normalization

Each agent uses its own severity scale. The skill normalizes all findings to a unified Critical/High/Medium/Low scale via the normalization table in `SEVERITY.md`, and deduplicates findings when two agents flag the same `file:line`.

CVE findings whose CVSS vector cannot be parsed (CVSS v4.0/v2 vectors, or no severity entry) are emitted as `"High"` as a conservative fallback.

## Per-agent conditional gates

Before launching agents, Phase 1 evaluates grep-based bash gates against the diff:

| Gate | Actual effect |
|------|----------------|
| `GATE_ERROR_PATTERNS=false` | Skip `silent-failure-hunter` (whole-`DIFF_FILE` grep, any profile) |
| `GATE_CONTROL_FLOW=false` | Skip `edge-case-hunter` (added `+` lines only) |
| `GATE_SECURITY_PATTERNS=false` | May set `LOW_RISK_CONFIG` on `PROFILE=full` (config extensions). Does **not** skip `security-reviewer`. Tiny-tier security uses `SECURITY_PROMOTED`. |
| `GATE_CODE_OR_INFRA=false` | Sets `DOCS_ONLY`. On `PROFILE=full` only, skip `architecture-reviewer` unless `ARCH_PROMOTED`. `--profile deep` keeps architecture. |

## Contributing

The deterministic bash helpers in `skills/code-review-lenses/scripts/` and `tests/` have a [bats](https://github.com/bats-core/bats-core) test suite:

```bash
# Install bats (macOS)
brew install bats-core

# Run all tests
bats tests/*.bats
```

The `tests/*.bats` suite covers parser contracts (`parse-pr-url`, `detect-provider`, `resolve-profile`, `review-diff`), analyzer fail-closed paths, gate evaluation, and wrapper text contracts. All tests are offline (no network, no host invocation).

## Acknowledgments

The `blind-hunter` and `edge-case-hunter` agents are adapted from concepts in the [BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) project by Brian "BMad" Madison (BMad Code LLC), released under the [MIT License](https://github.com/bmad-code-org/BMAD-METHOD/blob/main/LICENSE). Our implementations differ: we use structured severity output, omit the minimum-findings mandate, and integrate tightly with our manifest and context-passing strategy.

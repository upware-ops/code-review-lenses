# code-review-lenses

A host-agnostic [Agent Skills](https://agentskills.io/specification) package
that runs a local PR/MR review with a parallel fleet of specialized agents.

It works in any skill-compatible agent (Claude, Codex, Grok, Cursor, Copilot,
and others). It produces a structured summary (Block A) and a severity-ranked
findings report (Block B). It never creates, comments on, or updates a PR/MR.

## What it does

1. Detects the git host (GitHub, GitLab via `glab` on any authenticated host, Bitbucket)
2. Launches specialized review agents in parallel, with token-efficient context
3. Runs deterministic CVE + opportunistic static analyzers
4. Normalizes, deduplicates, and redacts findings
5. Prints Block A and Block B locally (optional `--output-file`)

## Profiles

Pass `--profile <name>`. Default is `full`. `--summary-only` is a separate
flag (mutually exclusive with `--profile`) that runs only the summarizer.

| Profile | What runs | When to use |
|---------|-----------|-------------|
| **quick** | `pr-summarizer`, `code-reviewer`, triggered `silent-failure-hunter` / `pr-test-analyzer`, CVE + static analyzers. Skips architecture, security, hunters, comment, type, issue-linker. | Fast pass on a well-scoped change. |
| **security** | `security-reviewer` + CVE + static analyzers. | Dependency or auth-sensitive diffs when you only want the security axis. |
| **full** | All always-run and specialist agents, plus triggered conditionals and deterministic checks. Auto-cheap still applies to docs-only / low-risk-config diffs. | Default review. |
| **deep** | Same roster as **full**, plus `EXTENDED_THINKING` for architecture-reviewer and security-reviewer, and a CVE reachability pass (`reachable` / `dev-only` / `transitive-only` / `unknown`). Does **not** auto-cheap. | High-risk or large changes. |

`--quick`, `--security-only`, and `--depth` were removed; the parser rejects them
and points at `--profile`.

Auto-selected **TIER=tiny** (<50 lines and ≤3 files) still skips hunters and
comment/type agents, and only promotes architecture/security when infra or
auth/dep-manifest paths appear. `--profile security` still runs security-reviewer
at tiny tier.

## Requirements

| Requirement | Notes |
|-------------|-------|
| An Agent Skills–compatible host with subagent tools | Loads `skills/code-review-lenses/SKILL.md` and `agents/*.md` |
| `git` | Diff analysis |
| `jq` | Findings pipeline |
| [gh CLI](https://cli.github.com/) | Only for a GitHub PR URL |
| [glab CLI](https://gitlab.com/gitlab-org/cli) | Only for a GitLab MR URL; any authenticated host |
| `BITBUCKET_EMAIL` + `BITBUCKET_TOKEN` | Only for a Bitbucket PR URL |

No plugin marketplace, no host-specific installer, no extra review-toolkit plugin.

### GitLab (any host)

`glab` must already be authenticated to the remote hostname:

```bash
glab auth login --hostname git.example.com
```

Detection uses, in order: hostname `gitlab.com` / contains `gitlab`,
`GITLAB_HOST`, `glab config get host`, then `glab auth status`. Nested groups
(`group/sub/project`) are kept in the project slug.

## Install

Clone this repository. A checkout is enough for Codex, Claude, and Grok:
relative links at `.agents/skills/code-review-lenses`,
`.claude/skills/code-review-lenses`, and `.grok/skills/code-review-lenses`
point at the shipped `skills/code-review-lenses/`.

In Codex, invoke `$code-review-lenses --profile quick`. The orchestrator loads
the existing Markdown prompts into native subagents; no custom-agent
registration is needed. Claude and Grok use `/code-review-lenses` or the
optional `/code-review-lenses-workflow` wrapper.

To use the skill from other repositories, symlink `skills/code-review-lenses`
into the host's user skill directory (`~/.agents/skills/` for Codex). Keep the
full checkout available: the skill resolves the sibling `agents/` directory
from its physical location.

The skill resolves its own directory via `scripts/resolve-skill-root.sh`.
It does not search `~/.claude` plugin caches.

## Usage

```
/code-review-lenses
/code-review-lenses --profile quick
/code-review-lenses --profile security
/code-review-lenses --profile full
/code-review-lenses --profile deep
/code-review-lenses --summary-only
/code-review-lenses --output-file review.md
/code-review-lenses https://github.com/acme/app/pull/42
/code-review-lenses review https://gitlab.example/g/p/-/merge_requests/7 focus on auth
```

### Flags

| Flag | Effect |
|------|--------|
| `--profile <name>` | `quick` \| `security` \| `full` \| `deep` (default `full`) |
| `--summary-only` | Only `pr-summarizer` |
| `--base <branch>` | Override compare base. PR/MR URL: fetched target branch. Local: `HEAD@{upstream}` only. Never `main`/`master`/`dev`. |
| `--no-enrich-context` | Disable symbol-context enrichment |
| `--no-suppress` | Disable suppression rules |
| `--min-confidence N` | Drop findings below N (0–100, default 75) |
| `--output-file <path>` | Write Block A + Block B to a file |
| PR/MR URL | External review. Host and number come from the URL. A bare number is not enough. |
| free-form text | Remaining leftover (`GUIDANCE`) is review focus |

There is no posting flag. `--post-findings`, `--post-summary`, `--create-pr`,
`--publish`, `--draft`, `--read-back`, `--no-post`, and `--local` are rejected.
`--pr` and `--provider` are rejected — pass a PR/MR URL instead.

## Workflow wrappers (Claude / Grok)

`/code-review-lenses` is still the skill path: the host follows `SKILL.md`
turn-by-turn. Optional wrappers run the same parsers and agents as a native
workflow so the host holds the loop. They cover Phase 0–1b, 2, 3, and 5.
Phase 0c (symbol context), Phase 1c (CVE reachability), and prebuilt
`FILE_DIGEST` / `LANGUAGE_PROFILES` / `PR_NARRATIVE` / `SYMBOL_CONTEXT` blobs
stay on the skill path. `--profile deep` still sets `EXTENDED_THINKING` on
architecture-reviewer and security-reviewer.

They do not fork roster or flag logic. A prelude agent runs the shipped
parsers (`resolve-skill-root.sh`, `resolve-profile.sh`, `parse-pr-url.sh`,
`detect-provider.sh`, `evaluate-gates.sh`, `apply-roster-overlays.sh`) and fans out the existing
`agents/*.md` stems.

| Host | File | Invoke |
|------|------|--------|
| Claude | `.claude/workflows/code-review-lenses-workflow.js` | `/code-review-lenses-workflow` |
| Grok | `.grok/workflows/code-review-lenses-workflow.rhai` | `/code-review-lenses-workflow` or `/workflow code-review-lenses-workflow` |

Pass the same argv the skill accepts — flags and optional free-form. The
wrapper hands that text to `resolve-profile.sh` unchanged (`$ARGUMENTS`).

```
/code-review-lenses-workflow --profile quick
/code-review-lenses-workflow review https://gitlab.example/g/p/-/merge_requests/7 focus on auth
```

JSON `{ "arguments": "--profile deep https://github.com/acme/app/pull/42" }` is the same string. `{ "profile": "quick" }` is only a convenience alias. Output is still local Block A and Block B. On any other host, use the skill.

## Provider support

| Feature | GitHub | GitLab | Bitbucket |
|---------|:---:|:---:|:---:|
| Auto-detection | Yes | Yes (any `glab` host) | Yes |
| PR/MR URL checkout | Yes (`gh`) | Yes (`glab`) | Yes (`curl`) |
| Issue cross-reference | Yes | No | No |
| Post / create PR | No | No | No |

## Agent roster

All 12 agents ship in `agents/`. Five were adapted from `pr-review-toolkit`
(Apache-2.0; see `agents/THIRD_PARTY.md`). Models default to **inherit**
(the host / orchestrator model). Pin names in
`skills/code-review-lenses/models.conf` if your host supports per-agent models.

| Agent | Axis | Profiles |
|-------|------|----------|
| **pr-summarizer** | Block A summary — not a findings agent | quick, full, deep, `--summary-only` |
| **code-reviewer** | Tactical bugs and style | quick, full, deep |
| **architecture-reviewer** | Coupling, API surface, structural debt | full, deep |
| **security-reviewer** | OWASP-class and dependency security | security, full, deep |
| **blind-hunter** | Zero-context orthogonal review | full, deep |
| **edge-case-hunter** | Whether a handling path exists | full, deep (if control-flow in the diff) |
| **adversarial-general** | Completeness, ops readiness, docs debt | full, deep |
| **issue-linker** | Related GitHub issues/PRs | full, deep (GitHub only) |
| **silent-failure-hunter** | Error-handling adequacy | quick, full, deep (if error patterns) |
| **pr-test-analyzer** | Test coverage gaps | quick, full, deep (if test files) |
| **comment-analyzer** | Comment accuracy / rot | full, deep (if comment changes) |
| **type-design-analyzer** | Type / struct / interface design | full, deep (if type definitions) |

Plus non-agent **dependency-check** (`scripts/run-cve-check.sh` → OSV.dev) and
opportunistic static analyzers (shellcheck, semgrep, trufflehog, ruff,
golangci-lint, checkov, eslint, hadolint, kube-linter, phpcs, phpstan, tflint).
A missing binary is a silent skip.

## Models

`skills/code-review-lenses/models.conf`:

```
summarizer=inherit
reviewer=inherit
specialist=inherit
hunter=inherit
linker=inherit
# security-reviewer=my-host-native-id
```

`inherit` means the orchestrator does not pass a model when spawning.

## Org security policy

Optional. Concatenated, 8 KB cap, injected into `security-reviewer`:

| Path | Scope |
|------|-------|
| `~/.config/code-review-lenses/security-guidance.md` | User-wide |
| `<repo>/.code-review-lenses/security-guidance.md` | Project |
| `<repo>/.code-review-lenses/security-guidance.local.md` | Local override |

Template: [`examples/security-guidance.example.md`](examples/security-guidance.example.md).

## Suppressions

Default: `skills/code-review-lenses/suppressions.json`.
Repo override: `.code-review-lenses/suppressions.json` (merged with `jq -s 'add'`).

Verify-gated ecosystems: `github-release`, `npm`, `pypi`, `go-module`, `cargo`,
`docker-hub`, `ruby-org`. Fail-open on 404 or network errors.

## Language profiles

Nineteen profiles in `skills/code-review-lenses/language-profiles/`.
Injected into findings agents except `blind-hunter` and `pr-summarizer`.

## Output

**Block A** — summary, walkthrough table, related issues (if issue-linker ran).

**Block B** — Critical / High / Medium / Low findings, architectural and
security write-ups, recommended actions.

Both always print in the terminal. `--output-file` writes them to disk.
Nothing is posted.

## Tests

```bash
bats tests/*.bats
```

Requires `bats` and `jq`. Orchestration decisions (profiles, GitLab host
detection, model inherit) are tested against the shipped scripts, not only
against documentation greps.

## License

MIT. Vendored toolkit agents: Apache-2.0 (`agents/LICENSE-pr-review-toolkit.txt`).
`blind-hunter`, `edge-case-hunter`, and `adversarial-general` were adapted from
[BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) (MIT, BMad Code LLC).

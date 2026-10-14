---
layout: default
title: Static Analyzers
nav_order: 4
render_with_liquid: false
---

# Static Analyzers

In addition to LLM agents, the skill runs deterministic checks when relevant files appear in the diff. All checks are **opportunistic** — if the binary is not installed, the check is silently skipped with no error.

## Analyzer table

| Check | Trigger | Profiles | Binary required |
|-------|---------|-------------------|----------------|
| **dependency-check** — queries [OSV.dev](https://osv.dev/) for known CVEs in declared dependency versions | `go.mod`, `package.json` / `package-lock.json`, `requirements*.txt`, or `composer.json` / `composer.lock` changed | quick, security, full, deep | `curl` + `jq` (built-in) |
| **shellcheck** — shell script linting | `.sh` or `.bash` files changed | quick, security, full, deep | `shellcheck` |
| **semgrep** — polyglot SAST | Any source file changed | quick, security, full, deep | `semgrep` |
| **trufflehog** — secret scanning | Any file changed | quick, security, full, deep | `trufflehog` |
| **ruff** — Python linting | `.py` or `.pyw` files changed | quick, security, full, deep | `ruff` |
| **golangci-lint** — Go static analysis | `.go` files changed; runs once per Go module | quick, security, full, deep | `golangci-lint` v2.1+ |
| **checkov** — IaC security scanning | `*.tf`, `*.tfvars`, `Dockerfile`, k8s YAML, CloudFormation, Azure ARM changed | quick, security, full, deep | `checkov` |
| **eslint** — JavaScript/TypeScript linting | `.js`, `.jsx`, `.ts`, `.tsx`, `.mjs`, `.cjs` files changed; only runs when an ESLint config is present; parse errors are findings | quick, security, full, deep | `eslint` (via `npx` or `node_modules/.bin`) |
| **hadolint** — Dockerfile linting | `Dockerfile`, `Dockerfile.*`, or `*.dockerfile` changed | quick, security, full, deep | `hadolint` |
| **kube-linter** — Kubernetes manifest linting | `.yaml`, `.yml`, or `.json` files containing `apiVersion` and `kind` fields (Helm `{{` templates skipped; undecodable manifests are findings) | quick, security, full, deep | `kube-linter` |
| **phpcs** — PHP CodeSniffer | `.php` files changed; uses Drupal/DrupalPractice standard when available, falls back to PSR-12 | quick, security, full, deep | `phpcs` |
| **phpstan** — PHP static analysis | `.php`, `.module`, `.inc`, `.install`, `.theme` files changed | quick, security, full, deep | `phpstan` |
| **tflint** — Terraform linting | `.tf` or `.tfvars` files changed; runs per-directory | quick, security, full, deep | `tflint` |

Findings appear in Block B with the tool name as source (e.g., `[shellcheck]`, `[eslint]`).

ESLint, tflint, and golangci-lint load configuration and plugins only from the reviewer checkout (`$GITHUB_WORKSPACE`, else the current directory) or your home directory (or from `TFLINT_CONFIG_FILE` / `TFLINT_PLUGIN_DIR` when you set them; relative values resolve against the reviewer checkout), so a PR/MR-URL review never runs configs or plugins from the reviewed PR/MR. A local review runs the checkout's own configs: do not run one on an untrusted checkout in an environment that holds secrets.

## Installing analyzers

All analyzers are optional and opportunistic. Install only those relevant to your codebase:

```bash
# macOS via Homebrew
brew install shellcheck hadolint kube-linter tflint

# Python-based (pip)
pip install semgrep ruff checkov

# Go-based
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest

# TruffleHog — see https://github.com/trufflesecurity/trufflehog/releases
# or: brew install trufflehog

# JavaScript
npm install -g eslint

# PHP
composer global require squizlabs/php_codesniffer phpstan/phpstan
```

## CVE check details

The `dependency-check` script queries [OSV.dev](https://osv.dev/)'s batch API for known vulnerabilities in dependency versions declared in changed manifests, then fetches each reported advisory's full record from `/v1/vulns/{id}` (the batch response carries only ids). No API key required. Network failures are non-blocking.

Only exact versions are queried. Ranged npm and Composer dependencies are checked at the version the adjacent `package-lock.json` / `composer.lock` resolves, and a changed lockfile checks its manifest. Ranges no lockfile resolves are skipped with one stderr note.

Supported manifest files:
- `go.mod` — Go modules (handles `replace` directives)
- `package.json` — npm/Node.js (ranges resolved from `package-lock.json`)
- `requirements*.txt` — Python pip (`==` / `===` pins only)
- `composer.json` — PHP Composer (ranges resolved from `composer.lock`)

CVE findings include severity (CVSS-mapped to Critical/High/Medium/Low), CVE ID, affected package and version, and a remediation note with the smallest fixed version above the installed one. Findings below CVSS threshold are emitted as `"High"` as a conservative fallback.

The `dependency-check` runs in `quick`, `security`, `full`, and `deep` when manifest files changed. It is skipped only for `--summary-only`.

## Static analyzer scripts

Each analyzer has a dedicated script in `skills/code-review-lenses/scripts/`:

| Script | Analyzer |
|--------|---------|
| `run-cve-check.sh` | OSV.dev CVE batch lookup |
| `run-shellcheck.sh` | ShellCheck |
| `run-semgrep.sh` | Semgrep SAST |
| `run-trufflehog.sh` | TruffleHog secret scanning |
| `run-ruff.sh` | Ruff Python linting |
| `run-golangci-lint.sh` | golangci-lint |
| `run-checkov.sh` | Checkov IaC scanning |
| `run-eslint.sh` | ESLint |
| `run-hadolint.sh` | Hadolint |
| `run-kube-linter.sh` | kube-linter |
| `run-phpcs.sh` | PHP CodeSniffer |
| `run-phpstan.sh` | PHPStan |
| `run-tflint.sh` | tflint |

Each script reads changed file paths from stdin and emits a `json-findings` JSON array with a stamped `source` field, flowing into the same dedup/suppress/normalize pipeline as agent findings.

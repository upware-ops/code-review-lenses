---
name: code-review-lenses
description: "Run a local PR/MR review using specialized agents. Supports GitHub, GitLab (any glab-authenticated host), and Bitbucket. Profiles: quick, security, full, deep. Use --summary-only for Block A only. External review: pass a PR/MR URL (not --pr / --provider). Remaining free-form is focus. Never posts to or creates PRs/MRs."
argument-hint: "[--profile quick|security|full|deep] [--summary-only] [--base <branch>] [--output-file <path>] [--min-confidence N] [--no-enrich-context] [--no-suppress] [PR/MR URL] [focus]"
license: MIT
compatibility: "Requires git, jq, and native subagent tools. gh CLI for a GitHub PR URL. glab CLI for a GitLab MR URL (any authenticated host)."
metadata:
  author: upware
  version: "2.0.0"
  spec: agent-skills
allowed-tools: Bash Read Write Grep Glob Agent
---

# Code Review Lenses

Run a full local review of all changes on the current branch (or a specified PR/MR). Produce Block A (summary) and Block B (findings) in the terminal. **Do not create, comment on, or update any PR/MR.**

**Arguments:** The flags, PR/MR URL, and focus after the skill name in the user's invocation (`$code-review-lenses` in Codex). Hosts that expand `$ARGUMENTS` may supply that text directly.

`Bash`, `Read`, `Write`, `Grep`, and `Glob` below mean the host's native shell, file, and search tools.

## Orchestrator Governance

- **Local only.** This skill never posts reviews, comments, or PR/MR descriptions, and never creates a PR/MR. There is no `--post-*`, `--create-pr`, `--publish`, `--draft`, `--read-back`, `--no-post`, or `--local` flag. If the user asks to post, refuse and print the local report.
- **Profiles, not mode flags.** Roster and depth come from `--profile quick|security|full|deep` (default `full`) or `--summary-only`. Do not invent `--quick`, `--security-only`, or `--depth`.
- **URL-only external review.** There is no `--pr` or `--provider`. Host and number come from a PR/MR URL in `GUIDANCE` via `parse-pr-url.sh`. A bare number is not a PR/MR identity. Omitted `--base` on a PR/MR is the target branch (`baseRefName`) as fetched from `origin` by `resolve-pr-base.sh`, never the parent clone's local branch of that name; never assume `main`, `master`, or `dev`.
- **Agent prompts.** Use this package's `agents/<name>.md` files through the Phase 1 spawn protocol. Do not pass a `model:` argument unless `resolve-models.sh` emitted a value other than `inherit`.
- **Cite observed results.** When reporting that a script ran, cite its exit code and output — not the fact that you invoked it.
- **Secret redaction.** Phase 2 redacts known-pattern secrets from finding text and Block A before display.
- **Subagent rules** live in `GOVERNANCE.md` (same directory as this file). Load once and inline into every custom-agent task.

## Review Workflow

### Phase 0: Resolve skill root, flags, and provider

1. **Skill root.** This file lives in the skill directory. Resolve it via the shipped script (do not search host-specific plugin caches):

   ```bash
   # Invoke resolve-skill-root.sh by the path of this skill's scripts/ directory.
   SKILL_ROOT=$(bash "<skill-dir>/scripts/resolve-skill-root.sh")
   SCRIPTS_DIR="$SKILL_ROOT/scripts"
   AGENTS_DIR="$SKILL_ROOT/../../agents"
   ```

   The resolver follows directory symlinks to the package checkout. All subsequent scripts are `$SCRIPTS_DIR/<name>.sh`; agent prompts are `$AGENTS_DIR/<name>.md`, independent of the repository being reviewed.

2. **Parse arguments** with the shipped parser — do not re-implement flag handling:

   Write the actual argument text as **data** into a temp file using a native file-writing tool. In Codex, take it from the user's invocation; do not assume `$ARGUMENTS` substitution or write that literal placeholder. No arguments means an empty file. Preserve quoting and pass the file to the parser; never interpolate invocation text into shell code.

   ```bash
   # _args_file is the temp path you just wrote (the invoke line is data).
   _profile_out=$(bash "$SCRIPTS_DIR/resolve-profile.sh" --from-file "$_args_file") || exit $?
   eval "$_profile_out"
   unset _profile_out
   ```

   Capture stdout, honor `$?`, then `eval`. Never `eval "$(parser)"` — that swallows exit 2. Never `bash resolve-profile.sh $ARGUMENTS` — unquoted expansion is command injection. On exit 2, print stderr and stop. The parser rejects removed flags (`--quick`, `--security-only`, `--depth`, `--pr`, `--provider`, `--post-findings`, `--post-summary`, `--create-pr`, `--no-post`, `--local`, `--publish`, `--draft`, `--read-back`, `--no-mem`, `--no-findings`) and unknown `--profile` values.

   Emitted variables include `PROFILE`, `GUIDANCE`, `BASE`, `OUTPUT_FILE`, `MIN_CONFIDENCE`, `NO_ENRICH_CONTEXT`, `NO_SUPPRESS`, and the pre-overlay `RUN_*` roster. There is no `PR_NUMBER` or `PROVIDER_OVERRIDE` from this parser.

   Non-flag tokens (and everything after `--`) become `GUIDANCE`. Unknown `--*` flags still fail.

3. **PR/MR URL** — external review is URL-only. A bare number is not a PR/MR identity.

   ```bash
   PR_NUMBER=""
   _url_rc=1
   _url_out=$(bash "$SCRIPTS_DIR/parse-pr-url.sh" "$GUIDANCE") && _url_rc=0 || _url_rc=$?
   if [[ "$_url_rc" -eq 0 ]]; then
     eval "$_url_out"
     GUIDANCE="${GUIDANCE_REST-}"
   elif [[ "$_url_rc" -ne 1 ]]; then
     echo "Error: parse-pr-url.sh failed." >&2
     exit "$_url_rc"
   fi
   unset _url_out
   ```

   Capture stdout, honor `$?`, then `eval` on 0. Exit 1 means no URL (local branch review). Do not invent `--pr` or `--provider`. Remaining prose in `GUIDANCE` is review focus (`GUIDANCE:` on eligible agents — same set as `PR_NARRATIVE`, never blind-hunter). If you cannot act on leftover focus text, continue and note unused guidance in Phase 5.

4. **Models** (optional, host-agnostic):

   ```bash
   _models_out=$(bash "$SCRIPTS_DIR/resolve-models.sh") || exit $?
   eval "$_models_out"
   unset _models_out
   ```

   Every `MODEL_*` value is `inherit` unless the user edited `models.conf`. When spawning: if the agent's `MODEL_*` is `inherit`, omit the model argument; otherwise pass that string as the host-native model identifier.

5. **Provider.** If step 3 set `PROVIDER`/`HOST`/`REPO_SLUG` from the URL, use those — do not re-detect from `origin` and do not accept a user `--provider`. Only when there is no URL, detect the local remote:

   ```bash
   if [[ -z "${PR_NUMBER:-}" ]]; then
     _detect_out=$(bash "$SCRIPTS_DIR/detect-provider.sh" --fallback unknown) || exit $?
     eval "$_detect_out"
     unset _detect_out
   fi
   ```

   GitLab is `glab` on **any** authenticated host. Nested GitLab groups stay in `REPO_SLUG` (`group/sub/proj`).

6. **CLI availability** (only when the CLI will actually be used):
   - URL review: run the shipped host-auth check (do not re-implement):

     ```bash
     bash "$SCRIPTS_DIR/detect-provider.sh" --check-url-host --provider "$PROVIDER" --host "$HOST" || exit $?
     ```

     GitHub: allow `github.com` / `*.github.com` / `*.ghe.com`, or `gh auth status` (origin match is not enough). GitLab: glab's env host (first set of `GITLAB_HOST`, `GITLAB_URI`, `GL_HOST`) or `glab auth status --hostname "$HOST"` (origin match is not enough, nor is `glab config get host`). Bitbucket: Cloud hosts only. Stop rather than send env tokens to an unknown host.
   - URL review + `PROVIDER=github`: `gh --version` must succeed.
   - URL review + `PROVIDER=gitlab`: `glab --version` must succeed. `glab` must already be authenticated to `HOST` (`glab auth login --hostname <HOST>` for self-hosted / dedicated).
   - URL review + `PROVIDER=bitbucket`: `curl` plus `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN` (map `BITBUCKET_APP_PASSWORD` → `BITBUCKET_TOKEN` if only the former is set).
   - Always: `jq --version` must succeed (findings pipeline).
   - `PROVIDER=unknown` is valid for a local branch review. It is an error when a PR/MR URL was parsed.

   Read-only provider operations (fetch metadata, checkout) live in [PROVIDERS.md](PROVIDERS.md). There are no create/comment/review-post operations and no “detect existing PR/MR” step.

### Phase 0b: Pre-flight and manifest

1. **PR/MR URL (external review):** when `PR_NUMBER` is set from `parse-pr-url.sh`, fetch metadata via **OP: Fetch PR/MR metadata**. Map to `number, title, baseRefName, baseRefOid, headRefName, state, body`. Stop if fetch fails or state is CLOSED/MERGED. If `--base` was not passed (`BASE` empty) and `baseRefName` is empty, **stop with an error** — never invent `main`, `master`, or `dev`. Set `PR_BODY` to `body` (or `""`). Create a temporary worktree and **OP: Checkout PR/MR branch into `$WORKTREE_PATH`** (checkout runs inside that worktree — never in the parent clone). All later git commands use `git -C "$WORKTREE_PATH"`. Track `WORKTREE_PATH` for Phase 5 cleanup. If `BASE` is empty, pin it to the target branch fetched from `origin` — a bare `baseRefName` resolves to the parent clone's local branch, which can be stale:

   ```bash
   if [[ -z "$BASE" ]]; then
     _base_out=$(cd "$WORKTREE_PATH" && bash "$SCRIPTS_DIR/resolve-pr-base.sh" --ref "$baseRefName" --provider-base "$baseRefOid") || exit $?
     eval "$_base_out"
     unset _base_out
   fi
   ```

   Exit 2 (fetch failed, invalid ref, or merge-base disagrees with the provider's `baseRefOid`) is a hard stop; `--base <ref>` overrides. Diff is `<BASE>...HEAD` of the checked-out PR/MR. Phase 1b analyzers stay in the reviewer checkout (never `cd` to `$WORKTREE_PATH`) and read `$WORKTREE_PATH/`-prefixed paths (`CHECK_PATHS`). Do not execute `./node_modules/.bin/*` or load ESLint/PHPStan/trufflehog config from the worktree.

2. **Local review (no URL):** if `BASE` is empty, use only `git rev-parse --abbrev-ref HEAD@{upstream}`. If upstream is missing, **stop with an error**. Do not assume `main`, `master`, or `dev`.

3. **Review range.** PR/MR-URL worktrees always use `<base>...HEAD` (do not mix in the parent dirty tree). Local review:

   ```bash
   REVIEW_MODE=committed
   _rd_rc=0
   _rd_out=$(bash "$SCRIPTS_DIR/review-diff.sh" --base "$BASE") && _rd_rc=0 || _rd_rc=$?
   if [[ "$_rd_rc" -eq 0 ]]; then
     eval "$_rd_out"
   elif [[ "$_rd_rc" -eq 1 ]]; then
     echo "No changes vs $BASE (committed or dirty). Nothing to review."
     exit 0
   else
     echo "Error: review-diff.sh failed." >&2
     exit "$_rd_rc"
   fi
   unset _rd_out
   ```

   `REVIEW_MODE=committed` → `git diff --name-only <base>...HEAD`. `REVIEW_MODE=dirty` → working tree vs `$BASE` (`git diff --name-only "$BASE"` plus untracked). Lock/vendor exclusions apply at `--stat` / language-manifest time (step 4); `MANIFEST_FILES` still come from the unfiltered name-only list. Note dirty mode in Phase 5. If both the committed range and the working tree are empty, report and stop.

4. **File manifest** from `git diff --stat` over the same range as step 3 (`<base>...HEAD` when committed; `"$BASE"` plus untracked when dirty) `-- ':!*lock.json' ':!*lock.yaml' ':!*.lock' ':!*.sum' ':!vendor/*' ':!node_modules/*'`. Detect languages (canonical names must match `language-profiles/<lang>.md`):

   | Extensions | Language |
   |---|---|
   | `.go` | Go |
   | `.py`, `.pyw` | Python |
   | `.ts`, `.tsx` | TypeScript |
   | `.js`, `.jsx`, `.mjs`, `.cjs` | JavaScript |
   | `.rs` | Rust |
   | `.rb`, `.rake`, `.gemspec` | Ruby |
   | `.php`, `.module`, `.inc`, `.theme` | PHP |
   | `.java` | Java |
   | `.cpp`, `.cc`, `.cxx`, `.hpp` | C++ |
   | `.sh`, `.bash` | Shell |
   | `.cs` | Csharp |
   | `.kt`, `.kts` | Kotlin |
   | `.swift` | Swift |
   | `.scala`, `.sc` | Scala |
   | `.lua` | Lua |
   | `.pl`, `.pm` | Perl |
   | `.sql` | SQL |
   | `.tf`, `.tfvars` | Terraform |
   | `.yaml`, `.yml` | YAML |

   Collect `MANIFEST_FILES` (`go.mod`, `package.json`, `requirements*.txt`, `composer.json`) from the unfiltered name-only list.

   ```bash
   _git=(git)
   [[ -n "${WORKTREE_PATH:-}" ]] && _git=(git -C "$WORKTREE_PATH")
   if [[ "${REVIEW_MODE:-committed}" == "dirty" ]]; then
     if ! DIFF_PATHS=$("${_git[@]}" diff --name-only "$BASE"); then
       echo "Error: git diff --name-only $BASE failed." >&2
       exit 2
     fi
     if ! _untracked=$("${_git[@]}" ls-files --others --exclude-standard); then
       echo "Error: git ls-files --others --exclude-standard failed." >&2
       exit 2
     fi
     [[ -n "$DIFF_PATHS" && -n "$_untracked" ]] && DIFF_PATHS+=$'\n'
     DIFF_PATHS+="$_untracked"
   else
     if ! DIFF_PATHS=$("${_git[@]}" diff --name-only "${BASE}...HEAD"); then
       echo "Error: git diff --name-only ${BASE}...HEAD failed." >&2
       exit 2
     fi
   fi
   ```

   **LANGUAGE_PROFILES** — lowercase each detected table name (`Go` → `go`, `Csharp` → `csharp`, `C++` → `c++`) before concatenating `$SKILL_ROOT/language-profiles/<lang>.md`. Cap at 32KB. Pass to architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter, silent-failure-hunter, code-reviewer, pr-test-analyzer. Never to blind-hunter or pr-summarizer.

   Format the manifest as:

   ```
   BASE: <base>  |  LANGUAGES: Go, TypeScript  |  FILES: <N>  |  LINES: +<added>/-<removed>

   Source:  path/to/file.go (+45/-12)
   Tests:   path/to/file_test.go (+20/-0)
   ```

   (LANGUAGE_PROFILES loader is specified immediately after the DIFF_PATHS block above.)

   **FILE_DIGEST** — per-file `--stat` plus the first `@@` hunk (≤20 lines). Cap at 200 lines. Build this after step 10 (`classify-diff.sh` has set `TIER`). Skip when `TIER=tiny`. Pass to architecture-reviewer and security-reviewer.

   **RELATED_FILES** — adjacent files outside the diff that may drift when version pins, Dockerfiles, or CI configs change. Cap at 15. Pass to architecture-reviewer and security-reviewer when non-empty. Build at every tier.

   Pointer globs (only when the matching path is in `DIFF_PATHS`):
   - `.nvmrc` / `package.json` / `.node-version` → Dockerfiles, compose, GitHub/GitLab/Bitbucket CI, `.ddev/config.yaml`
   - `composer.json` / `pyproject.toml` / `go.mod` / `.ruby-version` / `Gemfile` → Dockerfiles + CI
   - `Dockerfile` / `lagoon/` / `docker-compose` → language pins + CI
   - `.github/workflows/` / `.gitlab-ci.yml` / `bitbucket-pipelines.yml` → Dockerfiles + language pins

   Exclude files already in the diff.

5. **Suppressions** (skip if `NO_SUPPRESS=true`):

   ```bash
   SUPPRESSION_RULES="[]"
   GLOBAL_SUPP="$SKILL_ROOT/suppressions.json"
   LOCAL_SUPP=".code-review-lenses/suppressions.json"
   if [[ -f "$GLOBAL_SUPP" && -f "$LOCAL_SUPP" ]]; then
     SUPPRESSION_RULES=$(jq -s 'add' "$GLOBAL_SUPP" "$LOCAL_SUPP" 2>/dev/null \
       || { echo "WARNING: Failed to merge local suppressions; using global rules." >&2; cat "$GLOBAL_SUPP"; })
   elif [[ -f "$GLOBAL_SUPP" ]]; then
     SUPPRESSION_RULES=$(cat "$GLOBAL_SUPP")
   elif [[ -f "$LOCAL_SUPP" ]]; then
     SUPPRESSION_RULES=$(cat "$LOCAL_SUPP")
   fi
   ```

6. **Project context.** If `AGENTS.md` exists at the repo root (then ancestor directories of changed files, stop at repo root; also accept a project instruction file named `CLAUDE.md` or `.cursorrules` only when `AGENTS.md` is absent), extract ≤500 tokens. Else: "No project-specific context available."

7. **Commit log and narrative:**

   ```bash
   COMMIT_LOG_SHORT=$("${_git[@]}" log --no-merges --oneline "${BASE}..HEAD")
   PR_NARRATIVE=""
   COMMIT_BODIES=$("${_git[@]}" log --no-merges --format='--- Commit: %h%n%s%n%n%b%n' "${BASE}..HEAD" 2>/dev/null | head -200)
   [[ -n "$COMMIT_BODIES" ]] && PR_NARRATIVE+=$'\nCommit messages:\n'"$COMMIT_BODIES"
   if [[ -n "${PR_NUMBER:-}" && -n "${PR_BODY:-}" ]]; then
     PR_NARRATIVE+=$'\nPR/MR description:\n'"$(echo "$PR_BODY" | head -100)"
   fi
   ```

   Pass `PR_NARRATIVE` to pr-summarizer, code-reviewer, architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter. Never to blind-hunter.

8. **Diff file:**

   ```bash
   DIFF_FILE=$(mktemp)
   if [[ "${REVIEW_MODE:-committed}" == "dirty" ]]; then
     "${_git[@]}" diff "$BASE" > "$DIFF_FILE" || { echo "Error: git diff $BASE failed." >&2; exit 2; }
     while IFS= read -r _uf; do
       [[ -z "$_uf" || ! -f "$_uf" ]] && continue
       "${_git[@]}" diff --no-index -- /dev/null "$_uf" >> "$DIFF_FILE" || {
         [[ $? -eq 1 ]] || { echo "Error: git diff --no-index failed for $_uf." >&2; exit 2; }
       }
     done < <("${_git[@]}" ls-files --others --exclude-standard)
   else
     "${_git[@]}" diff "${BASE}...HEAD" > "$DIFF_FILE" || { echo "Error: git diff ${BASE}...HEAD failed." >&2; exit 2; }
   fi
   ```

9. **Gates** — source the shipped script. Capture then eval; honor `$?` (same as the other parsers). Non-zero from `evaluate-gates.sh` is a hard stop (grep I/O / unreadable existing `DIFF_FILE` → script exit 1). Missing `DIFF_FILE` or empty `DIFF_PATHS` stays the script’s all-true exit 0. Do not keep all-true defaults after a non-zero exit, and do not discard stderr.

   ```bash
   GATE_ERROR_PATTERNS=true
   GATE_CONTROL_FLOW=true
   GATE_SECURITY_PATTERNS=true
   GATE_CODE_OR_INFRA=true
   if [[ -x "$SCRIPTS_DIR/evaluate-gates.sh" ]]; then
     _gates_tmp=$(mktemp)
     _gates_rc=0
     DIFF_FILE="$DIFF_FILE" DIFF_PATHS="$DIFF_PATHS" bash "$SCRIPTS_DIR/evaluate-gates.sh" > "$_gates_tmp" || _gates_rc=$?
     if [[ "$_gates_rc" -ne 0 ]]; then
       echo "Error: evaluate-gates.sh failed." >&2
       rm -f "$_gates_tmp"
       exit "$_gates_rc"
     fi
     if grep -qE '^GATE_ERROR_PATTERNS=' "$_gates_tmp" && \
        grep -qE '^GATE_CONTROL_FLOW=' "$_gates_tmp" && \
        grep -qE '^GATE_SECURITY_PATTERNS=' "$_gates_tmp" && \
        grep -qE '^GATE_CODE_OR_INFRA=' "$_gates_tmp"; then
       source "$_gates_tmp"
     fi
     rm -f "$_gates_tmp"
   fi
   ```

10. **Classify tier / promotions / auto-cheap** — do not re-implement. After gates:

    ```bash
    _cls_out=$(DIFF_FILE="$DIFF_FILE" DIFF_PATHS="$DIFF_PATHS" \
      GATE_CODE_OR_INFRA="$GATE_CODE_OR_INFRA" GATE_SECURITY_PATTERNS="$GATE_SECURITY_PATTERNS" \
      bash "$SCRIPTS_DIR/classify-diff.sh") || exit $?
    eval "$_cls_out"
    unset _cls_out
    ```

    Emits `TIER`, `ARCH_PROMOTED`, `SECURITY_PROMOTED`, `DOCS_ONLY`, `LOW_RISK_CONFIG`, `LINES_CHANGED`, `FILES_CHANGED`. Overlay honors `DOCS_ONLY` / `LOW_RISK_CONFIG` only for `PROFILE=full`.

11. **Final roster** — apply overlays with the shipped script (do not re-implement):

    ```bash
    OVERLAY_ARGS=()
    if [[ -n "${_args_file:-}" && -f "$_args_file" ]]; then
      OVERLAY_ARGS=(--from-file "$_args_file")
    else
      OVERLAY_ARGS=(--profile "${PROFILE:-full}")
    fi
    _overlay_out=$(TIER="$TIER" DOCS_ONLY="$DOCS_ONLY" LOW_RISK_CONFIG="$LOW_RISK_CONFIG" \
      ARCH_PROMOTED="$ARCH_PROMOTED" SECURITY_PROMOTED="$SECURITY_PROMOTED" \
      GATE_CONTROL_FLOW="$GATE_CONTROL_FLOW" GATE_ERROR_PATTERNS="$GATE_ERROR_PATTERNS" \
      PROVIDER="$PROVIDER" \
      bash "$SCRIPTS_DIR/apply-roster-overlays.sh" "${OVERLAY_ARGS[@]}") || exit $?
    eval "$_overlay_out"
    unset _overlay_out
    ```

    Launch an agent only when its `RUN_*` is `true`, or `conditional` and its trigger matches.

12. **Governance block:**

    ```bash
    GOVERNANCE_FILE="$SKILL_ROOT/GOVERNANCE.md"
    GOVERNANCE_BLOCK=""
    GOVERNANCE_DEGRADED=false
    if [[ -r "$GOVERNANCE_FILE" ]]; then
      GOVERNANCE_BLOCK=$(cat "$GOVERNANCE_FILE")
    fi
    if [[ -z "$GOVERNANCE_BLOCK" ]]; then
      echo "WARNING: GOVERNANCE.md not found or empty." >&2
      GOVERNANCE_DEGRADED=true
    fi
    ```

13. **Org security policy** (optional; silent if absent). Concatenate, 8 KB cap:

    - `$HOME/.config/code-review-lenses/security-guidance.md`
    - `<repo>/.code-review-lenses/security-guidance.md`
    - `<repo>/.code-review-lenses/security-guidance.local.md`

    Load from the reviewer's checkout, never from `$WORKTREE_PATH` in PR/MR-URL mode. Inject into security-reviewer as `SECURITY_POLICY:` when non-empty.

### Phase 0c: Symbol context

Skip when `RUN_ENRICH_CONTEXT` is false (tiny tier, `--no-enrich-context`, or profiles `quick` / `security` / `summary`). Never inject into blind-hunter or pr-summarizer.

1. Extract added-line identifiers from `$DIFF_FILE`, drop stop-words and symbols defined in the diff, cap at 50 by frequency.
2. Grep the repo for definitions (`def|func|function|class|struct|interface|type|enum|const|var`). Cap 50 Grep calls.
3. Read ±5 lines around each match (cap 3 reads per symbol).
4. Build `<symbol-context>` (8,192-token budget). Store in `SYMBOL_CONTEXT`.

Eligible: architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter, code-reviewer.

### Phase 1: Launch agents

**Do not display raw diffs.** Use `$DIFF_FILE`. For `TIER=small`/`tiny`, pass the full diff inline. For `TIER=medium`, custom agents get the manifest and read `git diff` over the same range as Phase 0b (`${BASE}...HEAD` when committed, `"$BASE"` when dirty) `-- <file>`; **untracked files: Read the file — `git diff -- <file>` is empty for them**.

**Spawn protocol:**

- **Codex:** Read `$AGENTS_DIR/<name>.md` and embed its body (without YAML frontmatter), the required directives below, and only the permitted review inputs in the native `spawn_agent` message. Use the name as a task label (`task_name` uses underscores), not as a registered agent type. Start with no inherited conversation history (`fork_turns="none"` when exposed by the tool), especially for blind-hunter. No custom-agent registration is required.
- **Hosts with registered Markdown agents:** `subagent_type` is the bare agent name matching `agents/<name>.md`.

Pass `model:` only when the corresponding `MODEL_*` is not `inherit`. If a scheduled prompt or native subagent tool is unavailable, report the review incomplete. Keep each agent's handle associated with its name for collection.

**Directives** (own line at the top of the task, `KEY=value` or a heading block). Ignore unknown directives.

| Directive | Consumed by |
|-----------|-------------|
| `GOVERNANCE` | all custom agents in this repo (not the five vendored toolkit agents) |
| `EXTENDED_THINKING=true` | architecture-reviewer, security-reviewer — only when `EXTENDED_THINKING` is true (`--profile deep`) |
| `RELATED_FILES` | architecture-reviewer, security-reviewer |
| `LANGUAGE_PROFILES` | architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter, silent-failure-hunter, code-reviewer, pr-test-analyzer |
| `PR_NARRATIVE` | pr-summarizer, code-reviewer, architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter |
| `GUIDANCE` | same agents as `PR_NARRATIVE` when non-empty |
| `SYMBOL_CONTEXT` | architecture-reviewer, security-reviewer, adversarial-general, edge-case-hunter, code-reviewer |
| `SECURITY_POLICY` | security-reviewer |

**GOVERNANCE injection:** when `GOVERNANCE_BLOCK` is non-empty, prepend it under `GOVERNANCE:` to every custom agent. **blind-hunter:** after that block append: `BLIND_HUNTER_NOTE: The "Verification before naming" directive means verify within the diff or file list you were given — do NOT Grep or Read outside it. The "Refuse incoherent input" directive applies only to incoherence visible within the diff itself. The zero-context constraint takes precedence.` If `GOVERNANCE_DEGRADED=true`, omit both.

**Always-run when `RUN_*=true`:**

- **pr-summarizer** — manifest, commit log, project context; small diffs: full diff. `TIER=tiny`: diff + PR title only (still include GOVERNANCE).
- **code-reviewer** — full diff, stated as its review scope (its prompt otherwise defaults to unstaged `git diff`). Prefix `PR_NARRATIVE` when set.

**Specialists when scheduled:**

- **architecture-reviewer** — manifest, FILE_DIGEST, commit log, project context; small diffs: full diff. Tool budget 25. `TIER=tiny` + promoted: diff + RELATED_FILES + GOVERNANCE only.
- **security-reviewer** — same as architecture, plus `SECURITY_POLICY` when set. Tool budget 25.
- **adversarial-general** — manifest, commit log, project context.
- **blind-hunter** — **ONLY** the diff and GOVERNANCE. Medium/local: base + `git diff --name-only` file list. Medium/PR-URL: write a copy of the worktree diff to a temp file and pass that path (agent has no worktree knowledge).
- **edge-case-hunter** — manifest, commit log, project context.

**Conditional when `RUN_*=conditional` and the trigger matches:**

- **silent-failure-hunter** — `GATE_ERROR_PATTERNS=true`. Full diff.
- **pr-test-analyzer** — test paths (`*_test.go`, `test_*.py`, `*.test.ts`, `*.spec.ts`, `spec/`, `__tests__/`). Full diff.
- **comment-analyzer** — comment-line changes (`//`, `#`, `/*`, `"""`, `'''`). Full diff.
- **type-design-analyzer** — type definitions (`type ... struct`, `interface `, `class `, `enum `). Full diff.

**issue-linker** when `RUN_ISSUE_LINKER=true` (GitHub only after overlay). Pass commit log, branch, manifest, repo slug, PROVIDER.

Launch scheduled agents in parallel within the host's concurrency limit, collecting completed results before launching the remaining agents. Track skips for Phase 5.

### Phase 1b: Deterministic checks

Skip the whole phase when `RUN_CVE` and `RUN_STATIC_ANALYZERS` are both false (summary profile). Scripts run in the reviewer checkout, so a PR/MR-URL review hands them worktree paths:

```bash
CHECK_PATHS="$DIFF_PATHS"
if [[ -n "${WORKTREE_PATH:-}" ]]; then
  CHECK_PATHS=$(while IFS= read -r _p; do [[ -z "$_p" ]] || printf '%s\n' "$WORKTREE_PATH/$_p"; done <<<"$DIFF_PATHS")
fi
```

**CVE check** when `RUN_CVE=true` and `MANIFEST_FILES` is non-empty (the script picks the manifests out of `CHECK_PATHS`):

```bash
CVE_SCRIPT="$SCRIPTS_DIR/run-cve-check.sh"
CVE_JSON="[]"
CVE_CHECK_FAILED=false
if [[ -x "$CVE_SCRIPT" ]]; then
  CVE_JSON=$(bash "$CVE_SCRIPT" <<<"$CHECK_PATHS") || {
    echo "WARNING: run-cve-check.sh failed; CVE findings skipped." >&2
    CVE_JSON="[]"
    CVE_CHECK_FAILED=true
  }
else
  echo "WARNING: run-cve-check.sh not found at $CVE_SCRIPT." >&2
  CVE_CHECK_FAILED=true
fi
```

**Static analyzers** when `RUN_STATIC_ANALYZERS=true`. Each script reads `CHECK_PATHS` on stdin and emits json-findings. Missing binary → silent skip. Run matching tools in background, `wait`, then read the temp JSON files. Tools: shellcheck, semgrep, trufflehog, ruff, golangci-lint, checkov, eslint, hadolint, kube-linter, phpcs, phpstan, tflint. Same path/binary gates as the `run-*.sh` scripts in `$SCRIPTS_DIR`. If a script is present and exits non-zero, set `ANALYZER_FAILED=true` (do not treat `[]` after a crash as a clean scan) and still merge the findings it printed (semgrep and checkov emit partial results with exit 1).

### Phase 1c: CVE reachability (`PROFILE=deep` only)

Run only when `CVE_REACHABILITY=true` **and** `CVE_JSON` is a non-empty array. Spawn `security-reviewer` using the Phase 1 protocol (model from `MODEL_SECURITY_REVIEWER`) to add `reachability` (`reachable|dev-only|transitive-only|unknown`) without changing other fields. Validate length and untouched fields with `jq`; on any failure, keep the original `CVE_JSON`. In Block B, prefix `reachable` with `[REACHABLE]`; suffix `dev-only` / `transitive-only`.

### Phase 2: Collect and normalize

Wait for agents.

- Trimmed `NONE` → clean, omit from Block B.
- Empty / missing headers (and not NONE) → `WARNING: <agent> returned no results.`
- Tool error/timeout → `ERROR: <agent> failed. Reason: <error>.`

**2a — extract json-findings** from architecture-reviewer, security-reviewer, blind-hunter, edge-case-hunter, adversarial-general. Salvage truncated arrays. Validate `severity` ∈ Critical|High|Medium|Low. Normalize `category` to `authz|injection|dependency-cve|secret|architecture-coupling|test-gap|edge-case|observability|docs|lint|other`. Merge with `CVE_JSON` and analyzer JSON; in PR/MR-URL mode first make their `file` repo-relative with `jq --arg p "$WORKTREE_PATH/" '(.[].file | strings) |= ltrimstr($p)'`. Toolkit agents without json-findings: map via [SEVERITY.md](SEVERITY.md).

**2b — severity** per SEVERITY.md. Unparseable CVSS → High.

**2c — confidence.** Drop findings with `confidence < MIN_CONFIDENCE` (default 75; 0 disables). Before suppressions.

**2d — suppressions** unless `NO_SUPPRESS=true`. Match `file` and/or `pattern`. Verify-gated rules (max 20 calls): `github-release`, `npm`, `pypi`, `go-module`, `cargo`, `docker-hub`, `ruby-org`. 2xx → suppress; 404 or error → keep (fail-open).

**2e — proximity dedup.** Per file, cluster within 3 lines of cluster start. Keep highest severity; prefer `dependency-check` in a mixed cluster. Annotate extra sources.

**2f — secret redaction.** Execute via Bash (not illustrative). `rm -f` a redaction-degraded sentinel, define `redact_secrets`, rebuild `ALL_FINDINGS` and `BLOCK_A`. Halt the run if the pipeline fails or drops rows. If `perl` is missing, pass through, write the sentinel, set `REDACTION_DEGRADED=true`.

```bash
redact_secrets() {
  if ! command -v perl >/dev/null 2>&1; then
    echo "WARNING: perl not found; secret redaction skipped." >&2
    : > /tmp/cr-redaction-degraded
    cat
    return
  fi
  perl -0pe '
    s/\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9_]{36,}/<secret-redacted>/g;
    s/\bgithub_pat_[A-Za-z0-9_]{22,}_[A-Za-z0-9]{59,}/<secret-redacted>/g;
    s/\bglpat-[A-Za-z0-9_-]{20,}/<secret-redacted>/g;
    s/\bxox[baprs]-[A-Za-z0-9-]{10,}/<secret-redacted>/g;
    s/\bsk-[A-Za-z0-9_-]{20,}/<secret-redacted>/g;
    s/\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]{20,}/<secret-redacted>/g;
    s/\bnpm_[A-Za-z0-9]{30,}/<secret-redacted>/g;
    s/\bAKIA[0-9A-Z]{16}\b/<secret-redacted>/g;
    s/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*/<secret-redacted>/g;
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/<secret-redacted>/gs;
    s/("?)(password|passwd|pwd|token|api[_-]?key|secret|access[_-]?key|aws[_-]?secret[_-]?access[_-]?key)\1?(\s*[:=]\s*)("[^"]{8,}"|'\''[^'\'']{8,}'\''|[^\s,;]{8,})/\1\2\1\3<secret-redacted>/gi;
    s/(^|[\s:])(Bearer|Basic)\s+([A-Za-z0-9._~+\/=-]{20,})/\1\2 <secret-redacted>/g;
  '
}
```

Rebuild `ALL_FINDINGS` with `jq -c` + `redact_secrets` on `finding` and `remediation`; compare row counts; halt on mismatch. Then redact `BLOCK_A` the same way.

### Phase 3: Assemble reports

If `GOVERNANCE_DEGRADED=true`, prepend a banner that `GOVERNANCE.md` was missing. If `REDACTION_DEGRADED=true`, prepend a banner that `perl` was missing.

#### Block A

```markdown
## Summary

<from pr-summarizer>

**Type:** <type>
**Effort:** <N>/5 — <justification>

## Walkthrough

| File | Change | Summary |
|------|--------|---------|
<rows>

## Related Issues & PRs

<from issue-linker; omit the section if skipped or NONE>
```

#### Block B

```markdown
---

## Review Findings

**Overall Risk:** <Critical|High|Medium|Low>
**Profile:** <quick|security|full|deep|summary>

### Critical (<N>)
- **[agent]** <finding> — `file:line`

### High / Medium / Low
(same shape)

### Architectural Insights
<architecture-reviewer; omit if skipped/NONE>

### Security Analysis
<security-reviewer; omit if skipped/NONE>

### Adversarial Analysis
<adversarial-general Most Critical Gap; omit if skipped/NONE>

### Positive Observations

### Recommended Actions
```

### Phase 5: Final output

There is no Phase 4. Nothing is written to a hosting provider.

**Cleanup:** remove temp diff files and the redaction sentinel. If a PR/MR URL worktree was created, `git worktree remove "$WORKTREE_PATH" --force` and verify the path is gone (`WORKTREE_REMOVED`).

**`--output-file`:** write Block A, `---`, Block B via the Write tool.

**Terminal:**

1. Always print Block A then Block B (Block A only when `PROFILE=summary`).
2. PR/MR-URL worktree: cite `WORKTREE_REMOVED` or the cleanup error.
3. Skipped agents from `SKIP_REASONS` and from conditional triggers that did not fire. If `DOCS_ONLY=true` and `PROFILE=full`: `Auto-cheap: DOCS_ONLY`. If `LOW_RISK_CONFIG=true` and `PROFILE=full`: `Auto-cheap: LOW_RISK_CONFIG`.
4. `Diff tier: <tiny|small|medium>  (<N> lines, <M> files)` plus tiny-tier promotions. If `REVIEW_MODE=dirty`, say so (working tree vs `$BASE`, committed range was empty).
5. Agent tool-call counts for architecture-reviewer and security-reviewer (budget 25).
6. Token table: Agent, Model (or `inherit`), Tokens, Tools. Use `unavailable` for counts the host does not expose. No host-specific price column.
7. Critical/High → "Address Critical/High findings before requesting review."
8. Agent failures → "Review incomplete — <N> agent(s) failed."
9. `CVE_CHECK_FAILED=true` → CVE check did not run. `ANALYZER_FAILED=true` → a static analyzer crashed or exited non-zero (not a silent clean scan).
10. `NO_SUPPRESS=true` / `MIN_CONFIDENCE` drops as notes. Unused or uninterpreted `GUIDANCE` as a note.
11. No findings and no failures → "No significant issues found."

## Notes

- Host-agnostic. Skill layout follows the [Agent Skills](https://agentskills.io/specification) spec (`SKILL.md` + `scripts/` + `agents/`).
- Models default to `inherit`. Edit `models.conf` to pin host-native identifiers.
- GitLab uses `glab` against whichever host that CLI is authenticated to.
- A PR/MR URL checks out that branch for analysis only. Output stays local. Never invent `main`/`master`/`dev` as the compare base.

# code-review-lenses

Local PR/MR review using specialized agents. GitHub, GitLab (any `glab`-authenticated
host), and Bitbucket. Never creates or comments on a PR/MR.

Usage
  /code-review-lenses [flags] [free-form]

argument-hint
  [--profile quick|security|full|deep] [--summary-only] [--base <branch>] [--output-file <path>] [--min-confidence N] [--no-enrich-context] [--no-suppress] [PR/MR URL] [focus]

Profiles (`--profile`, default `full`)
  quick       pr-summarizer + code-reviewer + triggered silent-failure-hunter
              and pr-test-analyzer + CVE/static analyzers. No architecture,
              security, hunters, comment, type, or issue-linker.
  security    security-reviewer + CVE check + static analyzers.
  full        All always-run and specialist agents, plus triggered conditionals
              and deterministic checks. Default.
  deep        Same roster as full, plus EXTENDED_THINKING for architecture-
              and security-reviewer, and a CVE reachability pass.

Flags
  --profile <name>     quick | security | full | deep (default: full)
  --summary-only       Run only pr-summarizer (mutually exclusive with --profile)
  --base <branch>      Override compare base. On a PR/MR URL: default is the
                       fetched target branch. Local: HEAD@{upstream} only.
                       Never assume main/master/dev.
  --no-enrich-context  Disable symbol-context enrichment
  --no-suppress        Disable suppression rules
  --min-confidence N   Drop findings below N (0–100; default 75; 0 disables)
  --output-file <p>    Write Block A + Block B to <p>

Removed flags (the parser rejects these)
  --quick, --security-only, --depth          → use --profile
  --pr, --provider                           → pass a PR/MR URL
  --post-findings, --post-summary, --create-pr, --publish, --draft,
  --read-back, --no-post, --local, --no-findings, --no-mem
  This pipeline does not post.

Agents — full / deep
  Always:            pr-summarizer, code-reviewer
  Specialists:       architecture-reviewer, security-reviewer, blind-hunter,
                     edge-case-hunter, adversarial-general,
                     issue-linker (GitHub only)
  Conditional:       silent-failure-hunter, pr-test-analyzer,
                     comment-analyzer, type-design-analyzer

Agents — quick
  Always:            pr-summarizer, code-reviewer
  Conditional:       silent-failure-hunter, pr-test-analyzer
  Deterministic:     CVE + static analyzers

Agents — security
  Always:            security-reviewer
  Deterministic:     CVE + static analyzers

TIER=tiny (auto, <50 lines AND ≤3 files)
  Hunters, comment-analyzer, type-design-analyzer, adversarial-general skipped.
  architecture-reviewer / security-reviewer only if promoted by infra or
  auth/dep-manifest paths. --profile security still runs security-reviewer.

Auto-cheap (PROFILE=full only)
  DOCS_ONLY           no code/infra → summarizer + code-reviewer +
                      silent-failure-hunter / pr-test-analyzer (if triggered)
                      + CVE/static. comment-analyzer, type-design-analyzer,
                      and issue-linker are skipped.
  LOW_RISK_CONFIG     config-only, no security patterns → same specialists off;
                      issue-linker stays on. architecture/security only if
                      promoted.
  --profile deep does not auto-cheap.

Deterministic checks (all profiles except summary)
  dependency-check    OSV.dev via run-cve-check.sh (no API key)
  static analyzers    opportunistic; skip if the binary is missing

Models
  Default inherit (host / orchestrator model). Edit
  skills/code-review-lenses/models.conf to pin host-native identifiers.

GitLab
  Requires `glab` authenticated to the remote host:
    glab auth login --hostname git.example.com
  Nested groups are supported (group/sub/project).

Free-form (GUIDANCE)
  A PR/MR URL starts external review (host + number from the URL). Remaining
  prose is review focus. A bare number is not a PR/MR identity.
  Quote a value that contains spaces: --output-file "review report.md".

Examples
  /code-review-lenses
  /code-review-lenses --profile quick
  /code-review-lenses --profile security
  /code-review-lenses --profile deep
  /code-review-lenses --summary-only
  /code-review-lenses https://github.com/acme/app/pull/42
  /code-review-lenses review https://gitlab.example/g/p/-/merge_requests/7 focus on auth
  /code-review-lenses-workflow --profile quick focus on tokens

# Severity Normalization Table

Read by the orchestrator in Phase 2. Maps each agent's native scale to the
unified Critical/High/Medium/Low scale.

| Agent | Their Scale | Maps To |
|-------|-------------|---------|
| code-reviewer | confidence [91,100] / [80,90] / [60,79] / [0,59]; its prompt reports only ≥ 80 | Critical / High / Medium / Low |
| silent-failure-hunter | CRITICAL/HIGH/MEDIUM | pass through |
| comment-analyzer | section: Critical Issues / Improvement Opportunities / Recommended Removals | High / Medium / Low |
| pr-test-analyzer | gap [9,10] / [7,8] / [5,6] / [1,4] | Critical / High / Medium / Low |
| type-design-analyzer | lowest of its four ratings: [1,2] / [3,5] / [6,10] | High / Medium / Low |
| architecture-reviewer, security-reviewer, adversarial-general | Critical/High/Medium/Low via json-findings | pass through |
| blind-hunter, edge-case-hunter | Critical/High/Medium/Low via json-findings | pass through |
| dependency-check (parsed CVSS) | Critical/High/Medium/Low | pass through (identity mapping) |
| dependency-check (CVSS unparsed / v4 / v2) | High | maps to High (conservative) |
| shellcheck | error/warning (info and style are not emitted) | High / Medium (emitted; pass through) |
| semgrep | ERROR/WARNING/other (INFO) | High / Medium / Low (emitted; pass through) |
| trufflehog | verified/unverified/unverified-test | Critical / High / Low (emitted; pass through) |
| ruff | rule code starting with F or E / W or C / other | High / Medium / Low (emitted; pass through) |
| golangci-lint | errcheck, govet, staticcheck / other linters | High / Medium (emitted; pass through) |
| checkov | CKV2_*/CKV_SECRET_* vs others | High / Medium (emitted; pass through) |
| eslint | error (2)/warning (1) | High / Medium (emitted; pass through) |
| hadolint | error/warning/other (info, style) | High / Medium / Low (emitted; pass through) |
| kube-linter | no severity field | Medium (emitted; pass through) |
| phpcs | ERROR/WARNING | High / Medium (emitted; pass through) |
| phpstan | no severity field | High (emitted; pass through) |
| tflint | error/warning/other (notice) | High / Medium / Low (emitted; pass through) |

Phase 2 keeps an analyzer finding's emitted severity, and the scripts are the only place that mapping is applied.

pr-test-analyzer, type-design-analyzer, and comment-analyzer end their reply with a json-findings block whose `severity` and `confidence` follow the rows above and the confidence mapping below; `category` is one of the values listed below. Phase 2a uses that block when present and falls back to these rows otherwise.

## json-findings field contract

All custom agents (architecture-reviewer, security-reviewer, blind-hunter, edge-case-hunter,
adversarial-general) and deterministic scripts (dependency-check) emit a `json-findings`
block. Required fields:

| Field | Type | Values |
|-------|------|--------|
| `severity` | string | `Critical`, `High`, `Medium`, `Low` |
| `confidence` | integer | 0–100 (see scale below) |
| `category` | string | `authz`, `injection`, `dependency-cve`, `secret`, `architecture-coupling`, `test-gap`, `edge-case`, `observability`, `docs`, `lint`, `other` |
| `file` | string | repo-relative path |
| `line` | integer | 1-based; 0 when unknown |
| `finding` | string | description of the issue |
| `remediation` | string | concrete fix |
| `source` | string | agent/script name |

Phase 2 step 2a normalizes missing or unrecognized `category` values to `"other"`.

## Confidence Scale (0–100)

Custom agents (architecture-reviewer, security-reviewer, blind-hunter, edge-case-hunter,
adversarial-general) emit a `confidence` integer per finding in their `json-findings` block.

| Range | Label | Meaning |
|-------|-------|---------|
| 91–100 | Certain | Reproducible problem; no context needed |
| 76–90 | High | Strong evidence; minor ambiguity about runtime context |
| 51–75 | Moderate | Plausible but depends on context outside the diff |
| 26–50 | Low | Speculative; likely requires deeper context |
| 0–25 | Very low | Hunch or pattern-match; likely noise |

The `--min-confidence` flag (default: 75) filters out findings below the threshold
**before** suppression rules are applied. This ordering is load-bearing: confidence
filtering first ensures that verify-gated suppression rules don't burn registry HTTP
calls on sub-threshold noise.

### External agent confidence mapping

External pr-review-toolkit agents have no native confidence integer. For uniform
`--min-confidence` filtering (and as the `confidence` of their json-findings block),
their numeric scores are mapped as follows:
- `pr-test-analyzer` gap score [1,10]: `confidence = gap_score * 10`
  (gap=8 → confidence=80; gap=3 → confidence=30)
- `type-design-analyzer` lowest of its four ratings [1,10]: `confidence = (11 - rating) * 10`
  (low rating=2, meaning high concern → confidence=90; high rating=9, meaning low concern → confidence=20)
- `code-reviewer` already emits confidence [0,100]; no mapping needed. Its prompt reports only
  confidence ≥ 80, so its findings are Critical or High and a `--min-confidence` below 80 adds none.
- All other external agents (silent-failure-hunter, comment-analyzer): treat as confidence=80
  (above default threshold; filter does not apply unless `--min-confidence` > 80).

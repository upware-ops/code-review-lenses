# Third-party agents

The following agent files were adapted from
[pr-review-toolkit](https://github.com/anthropics/claude-plugins-official)
(Apache License 2.0):

- `code-reviewer.md`
- `silent-failure-hunter.md`
- `pr-test-analyzer.md`
- `comment-analyzer.md`
- `type-design-analyzer.md`

A copy of the Apache 2.0 license is at `agents/LICENSE-pr-review-toolkit.txt`.
`code-simplifier.md` exists upstream and is **not** vendored.

Pinned commit of `anthropics/claude-plugins-official` is in
`.github/vendor-pins.json` (`pr-review-toolkit.sha`).

Modifications in this repository (re-applied by `scripts/vendor-sync.sh`):

- Removed host-specific `model:` and `color:` frontmatter.
- Cut a frontmatter `description` at its inline `Examples:` (upstream
  `silent-failure-hunter.md` packs literal `\n` and `<example>` text into one
  YAML line, which hosts show raw).
- Replaced project-instruction references (`CLAUDE.md`) with `AGENTS.md`.
- `silent-failure-hunter.md`: dropped the Anthropic-internal error-ID bullets
  (`constants/errorIds.ts`, "Sentry tracking") and the `logError` hint, and
  replaced the bullet naming `logForDebugging` / `logError` / `logEvent` with
  the reviewed project's own logging and error-ID conventions. Only list
  items are rewritten; other upstream wording shows up in the sync diff.
- Inserted the vendor banner immediately after frontmatter.

## Updates

Nothing syncs on a schedule. To take a newer upstream version, run
`bash scripts/vendor-sync.sh toolkit [--sha <sha>]` from a checkout: it fetches
the five allowlisted files from `claude-plugins-official`, applies the patches
above, writes them here, and updates the pin. Review the diff before
committing. New upstream agents are ignored until they are added to the pin
allowlist.

`bash scripts/vendor-sync.sh digest` lists
`tag1consulting/claude-comprehensive-review` commits since its pin. 2.0 is a
product fork (no plugin, no posting, URL-only `--profile`), so nothing is
merged from it. Do not `git merge` the GitHub fork parent. Port individual script or
analyzer fixes by hand.

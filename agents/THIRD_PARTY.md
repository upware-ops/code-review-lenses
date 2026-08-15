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

Modifications in this repository (re-applied on every sync):

- Removed host-specific `model:` and `color:` frontmatter.
- Replaced project-instruction references (`CLAUDE.md`) with `AGENTS.md`.
- Inserted the vendor banner immediately after frontmatter.

## Nightly updates

`.github/workflows/vendor-sync.yml` runs daily (and on `workflow_dispatch`):

1. **Toolkit agents** — `scripts/vendor-sync.sh toolkit` fetches the five
   allowlisted files at `origin/main` of `claude-plugins-official`, applies
   the patches above, and opens or updates `chore/vendor-pr-review-toolkit`
   on **this** repo. Nothing is auto-merged. New upstream agents are ignored
   until they are added to the pin allowlist.
2. **tag1consulting/claude-comprehensive-review** — digest only. 2.0 is a
   product fork (no plugin, no posting, URL-only `--profile`). New commits
   become an issue, not a merge.

Do not `git merge` the GitHub fork parent. Port individual script or
analyzer fixes by hand.

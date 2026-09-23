---
layout: default
title: Provider Support
nav_order: 10
render_with_liquid: false
---

# Provider Support

Local remotes are classified by `scripts/detect-provider.sh`. External review
starts from a PR/MR URL: `scripts/parse-pr-url.sh` extracts host, provider,
slug, and number. There is no user `--provider` or `--pr`.

This pipeline is **read-only**. A PR/MR URL checks out that change for local
analysis. Nothing is posted.

## Feature matrix

| Feature | GitHub / GHE | GitLab | Bitbucket |
|---------|:---:|:---:|:---:|
| Auto-detection | Yes | Yes (any `glab` host) | Yes |
| PR/MR URL checkout | Yes (`gh`) | Yes (`glab`) | Yes (`curl`) |
| Issue cross-reference | Yes | No | No |
| Create / comment / review post | No | No | No |

## GitLab (any authenticated host)

Requires [glab](https://gitlab.com/gitlab-org/cli). Log in to the remote host:

```bash
glab auth login --hostname git.example.com
```

A remote is treated as GitLab when:

1. The hostname is `gitlab.com` or contains `gitlab`
2. `GITLAB_HOST` equals the hostname
3. `glab config get host` equals the hostname
4. `glab auth status --hostname <hostname>` succeeds (other hosts' auth state is ignored)

Nested groups stay in the project slug (`group/sub/project`).
`glab mr view` / `glab mr checkout` are used for an MR URL.

## GitHub

Requires [gh](https://cli.github.com/). A `…/pull/<N>` URL on any host is
GitHub (including Enterprise).

## Bitbucket

A Bitbucket PR URL needs `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN`
(`BITBUCKET_APP_PASSWORD` is mapped if set). Local branch review needs neither.

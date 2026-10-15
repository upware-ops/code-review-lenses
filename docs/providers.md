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
| PR/MR URL checkout | Yes (`gh`) | Yes (`glab`) | Yes (`git` + `curl` metadata) |
| Issue cross-reference | Yes | No | No |
| Create / comment / review post | No | No | No |

## GitLab (any authenticated host)

Requires [glab](https://gitlab.com/gitlab-org/cli). Log in to the remote host:

```bash
glab auth login --hostname git.example.com
```

A remote is treated as GitLab when:

1. The hostname is `gitlab.com` or contains `gitlab`
2. glab's env host (first set of `GITLAB_HOST`, `GITLAB_URI`, `GL_HOST`) equals the hostname
3. `glab config get host` equals the hostname
4. `glab auth status --hostname <hostname>` succeeds (other hosts' auth state is ignored)

An MR URL host is checked by `detect-provider.sh --check-url-host` before any
`glab` call. It accepts glab's host (`GITLAB_HOST`, `GITLAB_URI` or `GL_HOST`,
else `gitlab.com`) or a host where `glab auth status --hostname <hostname>`
succeeds with the env tokens unset. glab sends `GITLAB_TOKEN`,
`GITLAB_ACCESS_TOKEN` and `OAUTH_TOKEN` to any host, so while one is set, any
other host is refused: set `GITLAB_HOST` to the MR's host or unset the token.
A matching `origin` or `glab config get host` is not enough.

Nested groups stay in the project slug (`group/sub/project`).
`glab mr view` / `glab mr checkout` are used for an MR URL.

## GitHub

Requires [gh](https://cli.github.com/). A `…/pull/<N>` URL on any host is
GitHub (including Enterprise).

`detect-provider.sh --check-url-host` accepts github.com / `*.github.com` /
`*.ghe.com`, `GH_HOST` equal to the URL host, or a host where
`gh auth status --hostname <host> --active` succeeds with the env tokens unset.
gh sends `GH_ENTERPRISE_TOKEN` / `GITHUB_ENTERPRISE_TOKEN` to every GitHub
Enterprise Server host (never to github.com or `*.ghe.com`), so while one is
set, a GitHub Enterprise Server host other than `GH_HOST` is refused. A
matching `origin` is not enough.

## Bitbucket

A Bitbucket PR URL needs `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN`
(`BITBUCKET_APP_PASSWORD` is mapped if set). Local branch review needs neither.
PRs from a fork are refused: the source branch is fetched from the git remote for the PR's own repository.

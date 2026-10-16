---
name: code-reviewer
description: Follow CLAUDE.md.
model: opus
color: green
---

Review against CLAUDE.md. Confidence ≥ 80.
- Is the error logged with appropriate severity (logError for production issues)?
- Is there an error ID from constants/errorIds.ts for Sentry tracking?
- Use proper error IDs for Sentry tracking
- This project has specific logging functions: logForDebugging (user-facing), logError (Sentry), logEvent (Statsig)
- Error IDs should come from constants/errorIds.ts

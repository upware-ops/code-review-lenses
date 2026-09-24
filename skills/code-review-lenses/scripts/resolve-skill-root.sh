#!/usr/bin/env bash
# resolve-skill-root.sh — print the absolute path of this skill's root
# (the directory that contains SKILL.md, parent of scripts/).
#
# Usage:
#   bash "$SKILL_ROOT/scripts/resolve-skill-root.sh"
#   # or, from any cwd, invoke this file by path
#
# Output: one line, absolute path. No other stdout.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR/.." && pwd -P

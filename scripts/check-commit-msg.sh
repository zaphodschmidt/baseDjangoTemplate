#!/usr/bin/env bash
# commit-msg hook: reject AI attribution trailers.
#
# See CLAUDE.md § Git. The commit author is whoever ran the commit. A trailer
# naming a tool adds nothing a reader can act on, and it dilutes
# `git log --author`, which is the thing you reach for when you need to ask a
# human about a change.
set -euo pipefail

MSG_FILE="$1"

PATTERN='^[[:space:]]*(Co-[Aa]uthored-[Bb]y:.*(Claude|Copilot|Cursor|Codex|GPT|Gemini|AI)|(🤖 )?Generated (with|by) )'

if grep -qiE "$PATTERN" "$MSG_FILE"; then
  echo "commit-msg: AI attribution trailer found." >&2
  echo >&2
  grep -inE "$PATTERN" "$MSG_FILE" | sed 's/^/  /' >&2
  echo >&2
  echo "Remove it. See CLAUDE.md § Git." >&2
  exit 1
fi

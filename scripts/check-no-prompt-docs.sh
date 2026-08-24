#!/bin/bash
# Pre-commit guard: blocks agent work-order / prompting markdown from being committed,
# by name (HANDOFF*, CLAUDE.md, ...) or by content (a doc whose opening lines assign
# the reader a role, "You are ..."). Files it flags stay local; see .gitignore.
set -euo pipefail
fail=0
for f in "$@"; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
        HANDOFF*.md | CLAUDE.md | AGENTS.md | PROMPT*.md | AUDIT-DEEP-ISSUES.md | DAILY-DRIVER-PLAN.md)
            echo "error: $f is an agent prompting doc; keep it out of the repo" >&2
            fail=1
            continue
            ;;
    esac
    if head -20 "$f" | grep -qE '^You are '; then
        echo "error: $f opens like an agent work order (\"You are ...\"); keep it out of the repo" >&2
        fail=1
    fi
done
exit $fail

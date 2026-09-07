#!/bin/bash
set -euo pipefail

trash_command=$(command -v trash-put || true)
if [[ -z "$trash_command" ]] && command -v brew >/dev/null; then
    trash_command="$(brew --prefix trash-cli)/bin/trash-put"
fi
if [[ ! -x "$trash_command" ]]; then
    echo "error: trash-put is required. Debian: sudo apt-get install -y trash-cli. macOS: brew install trash-cli." >&2
    exit 1
fi

for path in "$@"; do
    [[ "$path" == /* ]] || { echo "error: Trash requires an absolute path: $path" >&2; exit 2; }
    [[ -e "$path" || -L "$path" ]] || continue
    "$trash_command" "$path"
done

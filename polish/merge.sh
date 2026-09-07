#!/bin/bash
# Merge each fix branch into the current branch in order; stop at the first conflict.
# Usage: bash /tmp/aura-merge.sh <branch> [<branch> ...]
set -u
cd /Users/aniko/Documents/Subjected/Aura || exit 1
for b in "$@"; do
  if ! git rev-parse --verify -q "$b" >/dev/null; then echo "SKIP $b: no such branch"; continue; fi
  ahead=$(git rev-list --count HEAD.."$b")
  if [ "$ahead" = "0" ]; then echo "SKIP $b: nothing to merge"; continue; fi
  echo "== merging $b ($ahead commits)"
  if git merge --no-ff --no-edit "$b" >/tmp/aura-merge-last.log 2>&1; then
    echo "OK   $b -> $(git rev-parse --short HEAD)"
  else
    echo "CONFLICT in $b:"
    git diff --name-only --diff-filter=U
    exit 2
  fi
done
echo "all merged; HEAD=$(git rev-parse --short HEAD)"

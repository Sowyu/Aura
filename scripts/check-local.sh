#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

for script in scripts/*.sh; do bash -n "$script"; done
for script in aura/Resources/WebScripts/*.js; do node --check "$script"; done
node --test scripts/*-bridge.test.cjs
git diff --check

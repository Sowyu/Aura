#!/bin/bash
# Pre-push gate: the same build-for-testing plus unit test pair CI runs.
set -o pipefail
DD="${DERIVED_DATA:-/tmp/dd-aura-prepush}"
# xcbeautify is optional; without it the raw log goes through.
PRETTY=$(command -v xcbeautify || echo cat)
xcodebuild build-for-testing -project Aura.xcodeproj -scheme aura \
  -destination "platform=macOS" -configuration Debug -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= | "$PRETTY" || exit 1
xcodebuild test-without-building -project Aura.xcodeproj -scheme aura \
  -destination "platform=macOS" -derivedDataPath "$DD" -only-testing:auraTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= | "$PRETTY"

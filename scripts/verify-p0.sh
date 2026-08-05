#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate
xcodebuild test \
  -project QuickNote.xcodeproj \
  -scheme QuickNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/QuickNoteDerived \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build \
  -project QuickNote.xcodeproj \
  -scheme QuickNote \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/QuickNoteDerived \
  CODE_SIGNING_ALLOWED=NO

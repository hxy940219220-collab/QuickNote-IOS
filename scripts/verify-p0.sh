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

release_app=/tmp/QuickNoteDerived/Build/Products/Release/QuickNote.app
codesign --force --deep --sign - "$release_app"
codesign --verify --deep --strict --verbose=2 "$release_app"

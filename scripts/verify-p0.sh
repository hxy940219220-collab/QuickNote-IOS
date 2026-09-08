#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
: "${QUICKNOTE_SIGNING_IDENTITY:?请设置本人的 Apple 开发或分发签名身份}"
: "${QUICKNOTE_DEVELOPMENT_TEAM:?请设置本人的 Apple Developer Team ID}"
bash scripts/prepare-offline-speech.sh
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
  CODE_SIGN_IDENTITY="$QUICKNOTE_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$QUICKNOTE_DEVELOPMENT_TEAM"

release_app=/tmp/QuickNoteDerived/Build/Products/Release/QuickNote.app
# Preserve the certificate signature across updates; never replace it with ad-hoc signing.
codesign --verify --deep --strict --verbose=2 \
  -R="identifier \"com.xixi.quicknote\" and anchor apple generic and certificate leaf[subject.OU] = \"$QUICKNOTE_DEVELOPMENT_TEAM\"" \
  "$release_app"

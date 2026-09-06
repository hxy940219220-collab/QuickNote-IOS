#!/bin/bash
set -euo pipefail

# Download build-time assets only. This script never records or uploads audio.
quicknote_root=$(cd "$(dirname "$0")/.." && pwd)
quicknote_assets="$quicknote_root/QuickNote/Resources/Speech"
quicknote_model_hash=c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51
quicknote_tokens_hash=f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc

check_hash() {
    test -f "$1" && test "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$2"
}

if check_hash "$quicknote_assets/model.int8.onnx" "$quicknote_model_hash" &&
   check_hash "$quicknote_assets/tokens.txt" "$quicknote_tokens_hash"; then
    echo 'SenseVoiceSmall assets already verified.'
    exit 0
fi

quicknote_stage=$(mktemp -d /tmp/quicknote-sensevoice-assets.XXXXXX)
quicknote_archive=${1:-"$quicknote_stage/model.tar.bz2"}
quicknote_package=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17
if test "$#" -eq 0; then
    curl --fail --location --retry 2 --output "$quicknote_archive" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$quicknote_package.tar.bz2"
fi
check_hash "$quicknote_archive" 7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e || {
    echo 'Model archive checksum mismatch; nothing installed.' >&2
    exit 1
}
tar -xjf "$quicknote_archive" -C "$quicknote_stage" \
    "$quicknote_package/model.int8.onnx" "$quicknote_package/tokens.txt"
check_hash "$quicknote_stage/$quicknote_package/model.int8.onnx" "$quicknote_model_hash"
check_hash "$quicknote_stage/$quicknote_package/tokens.txt" "$quicknote_tokens_hash"
mkdir -p "$quicknote_assets"
cp "$quicknote_stage/$quicknote_package/model.int8.onnx" "$quicknote_assets/"
cp "$quicknote_stage/$quicknote_package/tokens.txt" "$quicknote_assets/"
echo "SenseVoiceSmall assets verified and prepared. Download staging: $quicknote_stage"

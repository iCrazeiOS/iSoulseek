#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

command -v xcodegen >/dev/null || {
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
}

xcodegen generate

xcodebuild \
    -project iSoulseek.xcodeproj \
    -scheme iSoulseek \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

rm -rf build/Payload iSoulseek.ipa
mkdir -p build/Payload
cp -R build/Build/Products/Release-iphoneos/iSoulseek.app build/Payload/

strip build/Payload/iSoulseek.app/iSoulseek
(cd build && zip -qryX -9 ../iSoulseek.ipa Payload)

echo "Built iSoulseek.ipa"

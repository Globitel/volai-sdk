#!/bin/sh
# Copies the native Volai libraries into this plugin so it builds from pub or
# git without the rest of the repository. Run after changing the ios/ or android/ libraries at the repository root.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
rm -rf "$HERE/ios/volai_sdk/Sources/volai_sdk/VolaiSDK" "$HERE/android/src/main/kotlin/com/globitel/volai/"*.kt
mkdir -p "$HERE/ios/volai_sdk/Sources/volai_sdk/VolaiSDK" "$HERE/android/src/main/kotlin/com/globitel/volai"
cp "$REPO/ios/Sources/VolaiSDK/"*.swift "$HERE/ios/volai_sdk/Sources/volai_sdk/VolaiSDK/"
cp "$REPO/android/volai-sdk/src/main/kotlin/com/globitel/volai/"*.kt "$HERE/android/src/main/kotlin/com/globitel/volai/"
echo "synced native sources from $REPO/ios and $REPO/android"

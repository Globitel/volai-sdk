#!/bin/sh
# Copies the native Volai libraries into this package so it builds from npm
# without the rest of the repository. Run after changing ../ios or ../android.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$HERE/ios/VolaiSDK" "$HERE/android/src/main/kotlin/com/globitel/volai/"*.kt
mkdir -p "$HERE/ios/VolaiSDK" "$HERE/android/src/main/kotlin/com/globitel/volai"
cp "$HERE/../ios/Sources/VolaiSDK/"*.swift "$HERE/ios/VolaiSDK/"
cp "$HERE/../android/volai-sdk/src/main/kotlin/com/globitel/volai/"*.kt "$HERE/android/src/main/kotlin/com/globitel/volai/"
echo "synced native sources from ../ios and ../android"

# Releasing

All packages share one version and one tag: `vX.Y.Z` on `main`.

1. Bump the version in `android/volai-sdk/build.gradle.kts`, `react-native/package.json`, `flutter/volai_sdk/pubspec.yaml` + `ios/volai_sdk.podspec`, `web/package.json`, and the `SDK_VERSION` constants the native clients send in `User-Agent` / `client.hello` (`ios/Sources/VolaiSDK/VolaiClient.swift`, `android/.../VolaiClient.kt`).
2. Run `sh react-native/scripts/sync-native.sh` and `sh flutter/volai_sdk/scripts/sync-native.sh`; CI fails if the vendored sources drift.
3. Add the entry to `docs/CHANGELOG.md`, commit, and wait for CI to pass.
4. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow builds the web bundle, the Android AAR and the React Native tarball and attaches them to a GitHub Release with generated notes.

How consumers pick the release up:

| SDK | Mechanism |
|---|---|
| iOS | Swift Package Manager resolves the tag: `.package(url: "https://github.com/Globitel/volai-sdk", from: "X.Y.Z")` |
| Android | AAR attached to the release (`volai-android-sdk-vX.Y.Z.aar`); add it to `libs/` with the OkHttp and coroutines dependencies listed in `android/README.md` |
| React Native | `npm install https://github.com/Globitel/volai-sdk/releases/download/vX.Y.Z/volai-react-native-sdk-vX.Y.Z.tgz` (the package lives in `react-native/`, so the repository itself is not npm-installable) |
| Flutter | `volai_sdk: { git: { url: ..., ref: vX.Y.Z, path: flutter/volai_sdk } }` |
| Web | tarball on the release, or `web/` built from source |

Publishing to npm, pub.dev and Maven Central needs organisation accounts and is not wired yet; the workflow is the place to add it.

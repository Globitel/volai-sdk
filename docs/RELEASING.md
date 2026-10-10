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
| React Native | `npm install @volai/react-native-sdk` (published by the release workflow; the tarball is also attached to the release) |
| Flutter | `volai_sdk: { git: { url: ..., ref: vX.Y.Z, path: flutter/volai_sdk } }` |
| Web | `npm install @volai/web-sdk`, or the tarball on the release |

## npm

`@volai/web-sdk` and `@volai/react-native-sdk` publish from the `publish-npm` job through npm trusted publishing (GitHub Actions OIDC, provenance attached, no token stored). Each package lists this repository and `release.yml` as its trusted publisher in its npmjs.com settings. A package has to exist before that setting is available, so the first version of a new package is published by hand from a logged-in machine:

```bash
cd react-native && npm ci && npm publish   # prepublishOnly builds lib/; publishConfig is public
```

## pub.dev

`volai_sdk` publishes from the `publish-pub` job through pub.dev automated publishing (GitHub Actions OIDC, no credential stored). The package's admin page on pub.dev lists this repository, the tag pattern `v{{version}}` and the GitHub environment `pub.dev`; the tag's version must equal `version:` in `flutter/volai_sdk/pubspec.yaml`. The package was first published by hand (`flutter pub publish` from a machine logged in with `dart pub login`) and transferred to the `globitel.com` verified publisher.

Maven Central publishing is not wired yet.

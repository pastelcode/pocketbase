# Contributing

Thanks for your interest in improving the PocketBase Swift SDK. This guide covers the development setup, the full test matrix, and the conventions used in this repository.

## Requirements

- **Swift 6.2 or later** — the minimum is declared by `// swift-tools-version: 6.2` in `Package.swift`; development and CI use the latest Swift 6.x release (6.4 at the time of writing).
- **Xcode** for Apple platform builds, the iOS Simulator tests and DocC (Xcode 16.4 or later; the package targets iOS 15+, macOS 12+, tvOS 15+, watchOS 8+).
- **Android** (only for Android work): the [Swift SDK for Android](https://swift.org/documentation/articles/swift-sdk-for-android-getting-started.html) for your toolchain version, plus the Android NDK 27d or later and a running emulator.

## Getting started

```sh
git clone git@github.com:pastelcode/pocketbase.git
cd pocketbase
swift build
swift test
```

`swift test` runs the whole suite on macOS. It is the fast path for day-to-day work.

## Test matrix

Every behavior change should be verified on macOS, and preferably on iOS Simulator and Android before opening a pull request. CI runs all three.

### macOS

```sh
swift test
```

### iOS Simulator

```sh
xcrun simctl list devices available          # pick an installed iPhone
xcodebuild test -scheme pocketbase \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Adjust the device name to one that exists on your machine.

### Android

1. Install the Swift SDK for Android for your toolchain (see the [official guide](https://swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)) and confirm it is registered:

   ```sh
   swift sdk list
   ```

   The SDK identifier used by this package is `aarch64-unknown-linux-android28` (and the `x86_64` / `armv7` variants).

2. Cross-compile for each supported triple:

   ```sh
   swift build --swift-sdk aarch64-unknown-linux-android28
   swift build --swift-sdk x86_64-unknown-linux-android28
   swift build --swift-sdk armv7-unknown-linux-android28
   ```

3. Run the test bundle on an emulator:

   ```sh
   swift build --swift-sdk aarch64-unknown-linux-android28 --build-tests
   ```

   Stage the test bundle together with the Swift runtime libraries and `libc++_shared.so`, push them to the device and run:

   ```sh
   SDK_ROOT=~/Library/org.swift.swiftpm/swift-sdks
   BUNDLE=$SDK_ROOT/swift-6.4.0-RELEASE_android.artifactbundle
   NDK=$ANDROID_HOME/ndk/27.0.12077973

   mkdir -p /tmp/pbtests
   cp "$BUNDLE"/swift-android/swift-resources/usr/lib/swift-aarch64/android/*.so /tmp/pbtests/
   cp "$NDK"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /tmp/pbtests/
   cp .build/aarch64-unknown-linux-android28/debug/pocketbasePackageTests.xctest /tmp/pbtests/tests

   adb shell rm -rf /data/local/tmp/pbtests && adb shell mkdir -p /data/local/tmp/pbtests
   adb push /tmp/pbtests/. /data/local/tmp/pbtests/
   adb shell chmod +x /data/local/tmp/pbtests/tests
   adb shell "cd /data/local/tmp/pbtests && LD_LIBRARY_PATH=. ./tests --testing-library swift-testing"
   ```

   Adjust the SDK bundle name, NDK version and `.build` path to your installation. CI automates the same steps with [`skiptools/swift-android-action`](https://github.com/skiptools/swift-android-action).

### Documentation

DocC must build without diagnostics. The SDK publishes docs through the Swift Package Index; local builds use:

```sh
xcodebuild docbuild -scheme pocketbase -destination 'generic/platform=macOS'
```

To inspect the generated archive, find `pocketbase.doccarchive` in the build output and open it in Xcode, or preview it with `docc preview`.

## Conventions

- **Documentation is the source of truth.** Public declarations require `///` doc comments, and the DocC articles in `Sources/pocketbase/pocketbase.docc` must agree with the code, the README and the tests. If they disagree, treat it as a bug and fix all of them together.
- **No legacy JavaScript surface.** Deprecated JS APIs (`$autoCancel` / `$cancelKey`, `params`, positional overloads, the options-only `beforeSend` return shape, `legacy.ts`) are intentionally not ported. If a deviation from the JS SDK is unavoidable, document it in the API comment, the README [Parity Notes](README.md#-parity-notes) and the tests.
- **Prefer typed Swift APIs** over stringly-typed or JSON-driven surfaces, and follow the existing structure: `Services/` for API groups, `Stores/` for auth state, `Tools/` for shared helpers; tests mirror these names under `Tests/pocketbaseTests/`.
- **Add tests with every behavior change.** Test names use the `testXxx` style with Swift Testing (`@Test` / `#expect`).
- **Formatting:** use Xcode's default formatting for the repository; do not reformat unrelated code in the same change.

## Commit messages

This repository uses [Conventional Commits](https://www.conventionalcommits.org):

```text
feat: add interactive authWithOAuth2
fix: align batch multipart serialization with the reference SDK
docs: document the Android test procedure
test: cover connect-timeout rejection
```

- Use the imperative mood in the subject, no trailing period.
- Add a `BREAKING CHANGE:` footer for incompatible changes.
- Reference the GitHub issue in the pull request description (one issue per pull request keeps reviews focused).

Never commit build artifacts (`.build/`, `DerivedData/`), secrets, tokens or credentials.

## Pull requests

- CI must pass: macOS tests, DocC (zero diagnostics) and the Android build/test job.
- If you change a code sample, paste it into a scratch package and compile it — README and DocC snippets are not compiled by the test suite.
- Keep the CHANGELOG entry for user-visible changes in sync when preparing a release.

## Reporting issues

Open an issue at <https://github.com/pastelcode/pocketbase/issues> and include the platform, the Swift/Xcode version, the steps to reproduce and the expected behavior. Security-sensitive reports should be sent privately to the maintainer instead.

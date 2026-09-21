<!--
Thanks for contributing! Please fill in the sections below and make sure the
checklist is complete. See CONTRIBUTING.md for the full test matrix.
-->

## Summary

<!-- What does this change do, and why? -->

## Related issue

<!-- e.g. "Closes #28". One issue per pull request keeps reviews focused. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Refactor or internal change

## Testing

- [ ] macOS: `swift test`
- [ ] iOS Simulator: `xcodebuild test -scheme pocketbase -destination 'platform=iOS Simulator,name=…'`
- [ ] Android: `swift build --swift-sdk aarch64-unknown-linux-android28` (and the emulator test run when the change affects runtime behavior)
- [ ] New or updated tests cover the change

## Documentation and parity

- [ ] Public API changes have `///` doc comments
- [ ] DocC articles in `Sources/pocketbase/pocketbase.docc` are updated
- [ ] README and the [Parity Notes](../README.md#-parity-notes) are updated for behavior changes
- [ ] Any intentional deviation from the JS/Dart SDKs is documented in the API comment, README and tests

## Breaking changes

<!-- Describe any source-breaking change and the migration path, or write "None". -->

## Checklist

- [ ] Commit messages follow Conventional Commits
- [ ] CI is expected to pass (macOS tests, DocC with zero diagnostics, Android build/tests)
- [ ] No secrets, tokens or credentials are included

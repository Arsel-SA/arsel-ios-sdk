# Releasing

Swift Package Manager consumes git tags directly — there is no registry to publish to. Pushing a
`v*` tag runs `.github/workflows/release.yml`: the full test suite (macOS `swift test` + the
iOS-simulator build), then a GitHub Release with the matching CHANGELOG section as notes.

## Per release

These steps are **one commit, and that commit is the release** — never bump the version in a feature
commit. An untagged bump publishes nothing while burning the number: the API's per-layout SDK gate
then withholds layouts from a build that does not exist, and the feature stays dark in the field
even though the code is on `main`.

1. Retitle the changes in `CHANGELOG.md` as `## [X.Y.Z] — YYYY-MM-DD` — the workflow extracts this
   section and fails if it is missing.
2. Bump the SDK version in **both** places, or the `X-Arsel-SDK` header reports a stale build:
   `Sources/Arsel/Core/Wire.swift` (`Wire.sdkVersion`) and
   `Sources/ArselNotificationExtension/ExtensionContext.swift` (`ExtensionWire.sdkVersion`). The NSE
   helper duplicates the constant on purpose — it must not depend on the `Arsel` target.
3. Commit, then tag and push:

   ```bash
   git tag vX.Y.Z && git push origin main vX.Y.Z
   ```

Integrators pin the package with `from: "X.Y.Z"` (or `exact:`) against the repo URL.

CocoaPods distribution (a podspec + `pod trunk push`) is a possible later addition if integrators
ask for it; nothing here precludes it.

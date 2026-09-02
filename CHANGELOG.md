# Changelog

All notable changes to the Arsel iOS SDK.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/): breaking changes to the public API wait for a major release.

## [1.2.0] — 2026-09-02

### Added

- **`arsel.app_installed`.** Emitted once, on the first launch after the app is installed, ahead of
  that launch's `arsel.session_start`. Carries `app_version`, `sdk_version` and `platform`. Its flag
  lives beside the rest of the SDK's state, which the OS deletes with the app, so a reinstall counts
  again while `reset()` and `optOut()` do not.

  **Devices that already have your app get no install event when they update to this version.** They
  are seeded silently on their first launch: emitting would have reported the entire installed base
  as installs on the day you shipped. Install-based segments start empty and fill forward.

## [1.1.0] — 2026-08-23

### Added

- **`diagnostics()` answers before initialization.** It previously returned `nil` when nothing had
  started — exactly the state an integrator reaches for it in — so a refused start looked identical
  to never having called `initialize()`. It now reports the refusal reason in `configError`,
  matching the field the web and Android SDKs gained in the same release.

### Fixed

- **The loopback exemption was a prefix match.** `http://localhost.evil.com` satisfied
  `hasPrefix("http://localhost")` and was exempted from the HTTPS requirement despite being an
  attacker-controlled host that is not loopback at all. The match is anchored now.

### Internal

- The `UserNotifications` surface is now covered by tests, and a `push-smoke` target drives a real
  notification through `xcrun simctl push` on a simulator and asserts the SDK reported it. Three
  tests that need an app host are deliberately absent: `UNUserNotificationCenter.current()` traps
  with `bundleProxyForCurrentProcess is nil` in a SwiftPM test bundle, before any guard can run.
  A simulator CI cannot be granted notification authorisation, so the smoke job reports that path
  as explicitly skipped rather than passing it by omission.


## [1.0.0] — 2026-08-17

Initial release: the iOS implementation of the Arsel wire contract, at parity with the Android and
web SDKs.

### Added

- **Events API** — `track()`, `identify()`, `reset()`, `flushNow()`, `anonymousId`,
  `diagnostics()`. Durable file-backed queue (persist before send, oldest-first, stop at first
  retryable failure, 7-day age cap), per-event persisted `Idempotency-Key` UUIDs with deterministic
  batch keys, `{events: [...]}` batching up to 50, snake_case `IngestEventDto` bodies, client-side
  E.164/email validation, `arsel.` reserved-prefix rejection.
- **Sessions** — `arsel.session_start` / `arsel.session_end` from UIApplication lifecycle
  notifications; 30-minute gap; end events backdated to the real background moment; process-death
  clamp so a dead foregrounded session is dropped unclosed rather than closed days long.
- **Push API** — `setPushToken(apns:)`, registration carrying the `anonymousId` so a subscription
  lands on the same contact the events built, device secret in the Keychain
  (`AfterFirstUnlockThisDeviceOnly`), durable `optOut()`, five-state enablement reporting,
  `requestNotificationPermission()` (never called by `initialize`).
- **Direct APNs.** Arsel signs with your own `.p8` auth key and talks to Apple itself, so no
  Firebase project sits in the iOS path. Registration reports `apnsEnvironment`, read from the
  embedded provisioning profile's `aps-environment` entitlement rather than `#if DEBUG` — a compile
  flag describes how the code was built, not how it was signed, and would mislabel a TestFlight
  build compiled with debug symbols. One uploaded key therefore serves debug, TestFlight and App
  Store builds.
- **Engagements** — delegate helpers for `opened` / `clicked` / `dismissed` / `displayed`
  (one engagement per tap), signature echo (`arsel_sig` / `arsel_kid`), batch envelope up to 50.
- **`ArselNotificationExtension`** — standalone Notification Service Extension helper: `delivered` engagements
  (best-effort, App Group + shared Keychain access group) and rich media attachment.
- **CI** — Linux `swift test` (the Foundation-only core) plus macOS `xcodebuild`/`swift test` for
  the iOS surface.

### Known limitations

- `delivered` engagements depend on Notification Service Extension execution, which iOS does not
  guarantee.
- An FCM registration token minted on iOS is not addressable by Arsel and is not accepted; pass the
  APNs token from `didRegisterForRemoteNotificationsWithDeviceToken`. An app that runs Firebase
  Messaging for its own reasons is unaffected.

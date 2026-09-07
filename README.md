# Arsel iOS SDK

Events, identity and push notifications for iOS, for [Arsel](https://arsel.sa). Swift Package, zero
dependencies.

```swift
import Arsel

Arsel.initialize(config: ArselConfig(clientKey: "pub_…", baseUrl: "https://api.arsel.sa"))

Arsel.track("product.viewed", properties: ["sku": "A-1023", "price": 149.99])
Arsel.identify(externalId: user.id)
```

**Two subsystems, and only one of them needs push.** `track()` and `identify()` work on a device that has
never granted notification permission and has no push token at all — a user who declines
notifications still has a contact and a behavioural history. Only delivery needs push.

- Swift 5.10, iOS 15+. Swift Package Manager only.
- **No Firebase, anywhere.** Arsel sends to iOS through Apple directly, so there is no Firebase
  project in the path. Hand the SDK the APNs token from
  `didRegisterForRemoteNotificationsWithDeviceToken` and upload your `.p8` auth key once in the
  dashboard.
- Durable: events and engagements are persisted to disk before any send and drained with retry,
  surviving process death, offline periods and app kills.
- MIT licensed.

> **Stable since 1.0.** The public API follows [SemVer](https://semver.org/): additive changes come
> in minor releases and nothing breaks before 2.0 — see [CHANGELOG.md](CHANGELOG.md). Distributed
> as a Swift Package: SPM consumes the git tag directly, so there is no registry to install from.

---

## Documentation

| | |
| --- | --- |
| **[Quickstart](docs/quickstart.md)** | Install, initialize, and verify. Start here. |
| **[Identity](docs/identity.md)** | Anonymous → identified, the identifier ladder, merges, `reset()` vs `optOut()`. |
| **[Push notifications](docs/push-notifications.md)** | Tokens, permission UX, delegate wiring, rich push, engagements. |
| **[API reference](docs/api-reference.md)** | Every method: signature, arguments, threading, and the cross-SDK parity table. |
| **[Changelog](CHANGELOG.md)** | Release notes. |

## Requirements

| | |
| --- | --- |
| iOS | 15.0+ |
| Swift | 5.10+ (Xcode 15.4+) |
| For events only | No push entitlement, no permission, no token needed |
| For push | Your own APNs `.p8` auth key, uploaded once in the dashboard; Arsel never holds your signing certificate |
| Runtime deps | None |

## Install

Xcode → *File → Add Package Dependencies…* → this repository's URL. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Arsel-SA/arsel-ios-sdk.git", from: "1.0.0")
```

Two products:

- **`Arsel`** — the SDK. Link it into your app target.
- **`ArselNotificationExtension`** — a tiny helper for a Notification Service Extension (`delivered`
  engagements + rich media). Link it *only* into the extension target. Optional; see
  [push-notifications.md](docs/push-notifications.md#notification-service-extension).

## Integrate

```swift
// AppDelegate / App init — early, once.
Arsel.initialize(config: ArselConfig(
    clientKey: "pub_…",                    // the org's PUBLISHABLE key. Safe in an app binary.
    baseUrl: "https://api.arsel.sa"))

Arsel.track("product.viewed", properties: ["sku": "A-1023"])

// On login. Everything tracked beforehand merges onto this contact.
Arsel.identify(externalId: user.id)

// On logout — new anonymous identity; the device stays subscribed.
Arsel.reset()

// Only when the USER asks to stop receiving notifications. Durable; not resurrected by re-registration.
Arsel.optOut()
```

`reset()` and `optOut()` are deliberately different calls. Calling `optOut()` on logout would leave
the device unreachable for the life of the install: a user who signs back in would not receive push
again. See [Identity](docs/identity.md).

`clientKey` is the org's **publishable** `pub_…` key — the same design as Klaviyo's site ID or
CleverTap's Account ID. It authenticates both APIs and grants nothing a secret API key does.
**Your secret API key is not safe in an app**: anyone can inspect an IPA.

## Module layout

```
Sources/Arsel/            # the SDK
  Arsel.swift             #   public facade
  Core/                       #   Foundation-only: transport, queue, bodies, identity, sessions
  Platform/                   #   UIKit / UserNotifications integration, compile-time gated
Sources/ArselNotificationExtension/   # standalone NSE helper (delivered engagements + rich media)
```

The `Core/` layer imports nothing beyond Foundation, which is what makes the whole logic surface
unit-testable on Linux (`swift test` with the Linux toolchain passes; CI also builds the iOS
surface with `xcodebuild`).

## Build & test

```bash
swift build
swift test        # 75 tests; Foundation-only core, runs on macOS and Linux
```

## License

MIT.

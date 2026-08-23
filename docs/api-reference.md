# API reference

`Arsel` — a case-less enum used as a namespace; every entry point is a static member.

**Every entry point is failure-isolated.** Misuse is logged, never thrown at your app. Calls made
before `initialize()` are logged and ignored; getters return nil. All methods are safe from any
thread — work hops onto the SDK's serial queue and returns immediately (the `async` ones await
their own completion only).

---

## `initialize(config:)`

```swift
static func initialize(config: ArselConfig)
```

Idempotent; call once, early. Restores persisted state, attaches lifecycle observers (sessions),
polls notification permission, and drains anything a previous run left queued. Refuses (loudly, via
log) on a blank/non-`pub_` client key or a non-HTTPS `baseUrl` — `http://localhost` is the one
exemption, for a local backend.

### `ArselConfig`

| | Default | |
| --- | --- | --- |
| `clientKey` | — | The org's publishable `pub_…` key. Safe in an app binary |
| `baseUrl` | — | **HTTPS enforced** (localhost excepted). Trailing slashes trimmed |
| `logLevel` | `.warn` | `.verbose` … `.none` |
| `networkTimeout` | `15` | Seconds, per request |
| `appGroupId` | nil | Shared container for the NSE's `delivered` engagements |
| `keychainAccessGroup` | nil | Shared Keychain group so the NSE can read the device secret |

---

## `track(_:properties:)`

```swift
static func track(_ name: String, properties: [String: Any] = [:])
```

Records something the user did. Persisted before send; returns immediately. Blank names and names
starting `arsel.` are ignored; names are truncated at 80 characters. Property values: strings,
numbers and booleans pass through; `Date` becomes an ISO-8601 UTC string; non-finite numbers and
everything else are stringified; nesting is capped at depth 8 and ~64 KB serialized. Needs no push
token, no permission, no registration.

## `identify(externalId:email:phoneNumber:)`

```swift
static func identify(externalId: String? = nil, email: String? = nil, phoneNumber: String? = nil)
```

Client-asserted identity; persists and rides every later event; emits `arsel.identify` now. At
least one argument required. Shape-validated (E.164 / email-ish) — invalid values are rejected with
a logged error, never stored. A *different* `externalId` drops stored email/phone. Triggers
re-registration so the device's contact binding follows. See [Identity](identity.md).

## `reset()`

Logout. Rotates the anonymous id, forgets identifiers, re-registers under the new anonymous
identity. **Never touches push opt-out.**

## `optOut()`

Durable per-device push revocation — server-side and non-resurrectable. Not logout.

## `setPushToken(apns:)`

```swift
static func setPushToken(apns deviceToken: Data)   // the raw APNs device token
```

Hands the SDK the push token; registration (or re-registration, if anything changed) follows
automatically and survives process death. An unchanged device is never re-reported.

## `requestNotificationPermission(options:)`

```swift
@discardableResult
static func requestNotificationPermission(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async -> Bool
```

Shows the system prompt (once per install — call from a user-chosen moment, never cold start).
Reports the resulting five-state `enablementStatus`; on grant also calls
`registerForRemoteNotifications()`. Declining is a normal outcome, not an error.

## `handleNotificationResponse(_:)` / `handleForegroundNotification(_:)`

```swift
@discardableResult static func handleNotificationResponse(_ response: UNNotificationResponse) -> ArselPushMessage?
@discardableResult static func handleForegroundNotification(_ notification: UNNotification) -> ArselPushMessage?
```

Call from the two `UNUserNotificationCenterDelegate` methods. Engagement `opened`/`clicked`/`dismissed`
(one per tap) and `displayed` respectively; return the parsed message, or nil when the push is not
Arsel's. Routing `message.deepLink` is the host's job.

## `isArselNotification(userInfo:)`

```swift
static func isArselNotification(userInfo: [AnyHashable: Any]) -> Bool
```

Cheap claim check for multiplexing hosts.

## `anonymousId` / `diagnostics()` / `flushNow()`

```swift
static var anonymousId: String?                       // nil before initialize()
static func diagnostics() -> ArselDiagnostics?    // support-ticket snapshot, no secrets
static func flushNow() async                          // deliver everything queued, now
```

---

## Public types

| Type | |
| --- | --- |
| `ArselConfig` | configuration (struct) |
| `ArselDiagnostics` | the snapshot above |
| `ArselPushVendor` | `.apns` (iOS reaches Apple directly; there is no second transport) |
| `ArselEnablementStatus` | `AUTHORIZED`, `DENIED`, `NOT_DETERMINED`, `PROVISIONAL`, `UNAUTHORIZED` |
| `ArselPushMessage` | a parsed inbound push (`messageId`, `title`, `body`, `imageUrl`, `deepLink`, `actions`, …) |
| `ArselPushAction` | `actionId`, `label`, `deepLink` |
| `ArselLogLevel` | `.verbose` … `.none` |

`ArselNotificationExtension` product: `ArselNotificationExtensionHandler.didReceive(_:appGroupId:withContentHandler:)`
— see [push-notifications.md](push-notifications.md#notification-service-extension).

---

## Cross-SDK parity

The three SDKs deliberately share their conceptual surface; where names diverge it is per-platform
on purpose (push opt-in goes through each platform's own permission machinery, and initialization
follows each platform's idiom).

| Concept | Android | Web | iOS |
| --- | --- | --- | --- |
| Initialize | `initialize(context, config)` | `init(config)` | `initialize(config:)` |
| Identity | `identify(externalId, email, phoneNumber)` | `identify(identity)` | `identify(externalId:email:phoneNumber:)` |
| Custom events | `track(name, properties)` | `track(name, properties)` | `track(_:properties:)` |
| Logout | `reset()` | `reset()` | `reset()` |
| Durable push opt-out | `optOut()` | `optOut()` | `optOut()` |
| Push opt-in | `requestNotificationPermission(launcher)` | `promptForPush()` | `requestNotificationPermission()` |
| Push token in | (SDK obtains via FCM) | (browser subscription) | `setPushToken(apns:)` |
| Force delivery | `flushNow()` | `flushNow()` | `flushNow()` |
| Person-shaped id | `getAnonymousId()` | `getAnonymousId()` | `anonymousId` |
| Support snapshot | `diagnostics()` | `diagnostics()` | `diagnostics()` |

---


### Invalid configuration

All three SDKs apply the same four rules, in the same order, and all three respond the same way:
they **log an error, decline to start, and never throw**.

1. `clientKey` is non-blank
2. `clientKey` begins `pub_` — the check that catches a secret API key shipped inside an app bundle
3. `baseUrl` is HTTPS, except plain http to `localhost` / `127.0.0.1` (and `10.0.2.2` on Android,
   the only address an emulator can reach the developer's host on)
4. `baseUrl` parses as a URL

Nothing is collected while a config error stands, and no call has any effect. The reason is
readable at any time from the support snapshot:

| SDK | Reading it |
| --- | --- |
| Android | `Arsel.diagnostics()?.configError` |
| Web | `(await Arsel.diagnostics()).configError` |
| iOS | `Arsel.diagnostics()?.configError` |

Refusing rather than throwing is deliberate. The mistake is made at development time but the
failure lands at runtime on a user's device — the key may come from a build variant, a remote
config, or a CI secret that arrived empty — and an analytics SDK crashing an app over its own
configuration is a worse outcome than losing telemetry. `diagnostics()` answers with the reason
even before initialization, which is the state it describes.

## Network calls

For your security review. The SDK talks only to the `baseUrl` you configure.

| Call | Auth |
| --- | --- |
| `POST /v1/events/send` | `Authorization: Bearer <clientKey>` + `Idempotency-Key` |
| `POST /api/v1/orgs/{clientKey}/push/subscriptions` | none on create; mints the device secret |
| `POST /api/v1/orgs/{clientKey}/push/subscriptions/state` | `X-Arsel-Device-Auth` |
| `POST /api/v1/orgs/{clientKey}/push/subscriptions/unsubscribe` | `X-Arsel-Device-Auth` |
| `POST /api/v1/orgs/{clientKey}/push/engagements` | `X-Arsel-Device-Auth` |

Every request also carries `X-Arsel-SDK: ios/<version>`. This table describes what this SDK version
sends; the authoritative contract is the Arsel API itself.

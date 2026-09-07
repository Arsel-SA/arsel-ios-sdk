# Arsel Push — iOS Sample / Test App

A standalone iOS app (its **own repo**) that consumes the
**[Arsel iOS SDK](https://github.com/Arsel-SA/arsel-ios-sdk)** exactly the way a real
integrator would. This is the test sandbox — no production app required. The iOS counterpart of
[android-sample-push-app](https://github.com/Arsel-SA/android-sample-push-app).

> Contains no SDK source. It links the `Arsel` and `ArselNotificationExtension` SPM products, so
> it sees exactly what a customer sees.

---

> 📖 **Step-by-step walkthrough and what each diagnostics field means: [`HARNESS.md`](HARNESS.md).**

## What you need

- A **Mac with Xcode 15.4+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**
  (`brew install xcodegen`). The `.xcodeproj` is generated, not committed.
- **For events and identity: nothing else.** The events API works on any simulator with no
  signing, no push entitlement and no Apple Developer account.
- **For real push delivery: things that cannot be faked** — an Apple Developer Program team, a
  bundle id you registered under it (replace `com.example.arselsample` in `Config/*.xcconfig`
  if you prefer your own), the Push Notifications capability on that App ID, and a **physical
  device** in the general case. Arsel never holds your signing assets.
- For the full round trip: an **Arsel org with push enabled** — create a push app in your Arsel
  dashboard, or contact Arsel to enable push for your org.

### Simulator vs device, honestly

- The **events API** (track / identify / merge / reset) is fully real on any simulator.
- `xcrun simctl push` injects an APNs payload locally — good for the **rendering path** (does the
  SDK parse and report an engagement for a payload) without any Apple setup. Engagements it produces are unsigned, so
  the backend parks rather than counts them — expected, same as the Android sample's raw-FCM curl.
- **Real remote APNs delivery** needs a physical device — except that on an Apple-silicon Mac,
  iOS 16+ simulators can register with APNs too. Keep it simple: test rendering on the simulator,
  test delivery on a device.

> This harness holds a raw APNs token and links no Firebase project — iOS push goes straight from
> Arsel to Apple. For campaigns to actually reach this device, upload your `.p8` auth key under
> **Push → iOS** in the Arsel dashboard, with the bundle id matching the configuration you built.
> A debug build registers as `sandbox` and a TestFlight or App Store build as `production`; the SDK
> reports which, so the same key serves both.

## Step 1 — Configure

Two build configurations, the Android sample's two flavors. Each carries its own backend, client
key and bundle id in an `xcconfig`, so staging and prod install **side by side**, each with its
own SDK state:

| Configuration | Bundle id | Backend | Edit |
| --- | --- | --- | --- |
| `Debug-Staging` | `com.example.arselsample.staging` | the test environment Arsel gives you | [`Config/Staging.xcconfig`](Config/Staging.xcconfig) |
| `Release-Prod` | `com.example.arselsample` | `https://api.arsel.sa` | [`Config/Prod.xcconfig`](Config/Prod.xcconfig) |

Replace `REPLACE_WITH_STAGING_BASE_URL` and the `REPLACE_WITH_…_PK_KEY` placeholders. The client
key is the org's opaque **`pub_…` publishable key** — publishable by design, but always a
**dedicated test org's**, never a real customer's. The base URL must be HTTPS; the SDK refuses
cleartext at initialize. Mind the xcconfig comment gotcha: write URLs as `https:/$()/host`.

## Step 2 — Generate and run

```bash
xcodegen generate
open ArselSample.xcodeproj
```

Pick the **ArselSample-Staging** scheme → any iOS 15+ simulator → Run. On launch the app
initializes the SDK and shows the **backend it talks to**, the **installation id**, the
**anonymous id**, the **APNs token** (device / capable simulators only), live **diagnostics**,
and an event log. Everything SDK-owned on screen is read back through `Arsel.diagnostics()`.

**Local SDK development:** drag your local `arsel-ios-sdk` folder into Xcode's project navigator.
A local package automatically overrides the GitHub reference — the standard SPM override — and
edits to the SDK take effect on the next build, no publish step.

## Step 3 — Send a push

**Option A — the real path** (needs your `.p8` uploaded, per the note above): send a campaign from
your Arsel dashboard to the bound contact, or `POST {baseUrl}/v1/push/send` with your org API key.
This is the only option that exercises signature verification, engagement reconciliation and
analytics.

**Option B — simulated payload (rendering path only):**

```bash
xcrun simctl push booted com.example.arselsample.staging Payloads/arsel-test.apns
```

The notification renders; tapping it produces an `opened` engagement (unsigned → parked server-side,
as expected). See [`HARNESS.md`](HARNESS.md) for the full walkthrough.

## Notification Service Extension

The `NotificationService` target links **`ArselNotificationExtension`** and demonstrates `delivered`
engagements + rich media. It only does anything once you provision an **App Group** and a shared
**Keychain access group** under your own team — placeholders and instructions are in
`Config/*.xcconfig` and the two `.entitlements` files. Without them the app runs fine; the
extension path is simply inert.

## CI

`.github/workflows/ci.yml` generates the project with XcodeGen and builds it for the iOS
Simulator on macOS.

The sample resolves the SDK as a local package (`path: ../..` in `project.yml`), so it builds from
a plain checkout with no token and no network. To rehearse a real integration against a released
tag, swap that for the `url:`/`from:` form shown in `project.yml`.

## Troubleshooting

- **Diagnostics says "SDK not initialized"** → a `REPLACE_WITH_…` placeholder is still in the
  active xcconfig; the Xcode console has the SDK's exact refusal reason.
- **No APNs token** → normal on Intel-Mac or older simulators; on a device, check the Push
  Notifications capability and your team in `project.yml` (`DEVELOPMENT_TEAM`).
- **Nothing renders from `simctl push`** → the payload must carry the `arsel_*` keys and your
  booted simulator must run the **staging** bundle id in `Payloads/arsel-test.apns`.
- **Register returns 404** → push is not enabled for that org, or the key is not the `pub_…` key.
  Retryable — fix the key and the queue drains.
- **Engagements stay queued** → `hasDeviceSecret: false`. The secret is issued **once**, at first
  registration. Delete the app (a new install = new installation) and register again.
- **`xcodegen: command not found`** → `brew install xcodegen`.

## License

MIT — see [LICENSE](../../LICENSE).

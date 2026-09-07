# Running the push test harness

This app is the end-to-end harness for the Arsel iOS SDK. Everything SDK-owned on screen is read
back through the SDK's own public surface (`diagnostics()`, `Arsel.anonymousId`), so what you
see is exactly what an integrator can see in the field.

Companion docs: the SDK's
[quickstart](https://github.com/Arsel-SA/arsel-ios-sdk/blob/main/docs/quickstart.md) and
[push-notifications guide](https://github.com/Arsel-SA/arsel-ios-sdk/blob/main/docs/push-notifications.md).

---

## 1. Point it at a backend

The backend is chosen by **picking a scheme**, not by editing a URL at runtime:

| Scheme | Configuration | Backend | Use for |
| --- | --- | --- | --- |
| `ArselSample-Staging` | `Debug-Staging` | the test/sandbox environment Arsel gives you | day-to-day testing |
| `ArselSample-Prod` | `Release-Prod` | `https://api.arsel.sa` | a final check against production, once provisioned |

Fill in `Config/Staging.xcconfig` (`ARSEL_BASE_URL`, `ARSEL_CLIENT_KEY`). The client key is the
opaque `pub_…` publishable key from the org's push app, never a raw org id. It ships inside every
integrator's binary by design, so it belongs in tracked source. **Point it at a dedicated test
org** — never a real customer's.

Why schemes rather than a runtime switch: the SDK keeps `installationId` and the device secret
per install, so one install retargeted at another backend would present a secret that backend
never issued. The per-configuration bundle id (`….staging` vs the bare id — the Android sample's
`applicationIdSuffix` scheme) gives each environment its own install and its own SDK state, and
both install side by side as "Arsel Push (staging)" and "Arsel Push (prod)".

**`Release-Prod` is deliberately unusable until you provision it** — its key is a placeholder,
and its one risk is real: a filled-in prod key registers test devices into a real org. Treat
changing it as a reviewed change.

## 2. Generate and build

```bash
brew install xcodegen        # once
xcodegen generate            # after every project.yml change
open ArselSample.xcodeproj
```

The SDK resolves as a Swift Package from the checkout above this one (`path: ../..`), so an SDK
edit is picked up on the next build — there is no publish step to forget, unlike the Android
`publishToMavenLocal` loop.

## 3. What to exercise, in order

### The events API — do this first, on a fresh install

Deliberately before anything push-related, because none of it needs push. **Do not grant
notification permission yet.**

1. **`track()`.** Type an event name and an optional property, press *track()*.
   `pendingRequests` in diagnostics rises, then returns to 0 as the queue drains. In the Arsel
   dashboard the event appears against an anonymous contact — one with no email and no phone,
   identified only by the anonymous id shown on screen.
2. **The merge proof.** Enter an external ID and press *Run the merge proof*. It tracks an event,
   identifies, then tracks another. **Both events must end up on one contact**, keyed by your
   external ID, and the anonymous contact must be gone. This is the only end-to-end proof that an
   anonymous history survives identification — if it regresses, every pre-login event a customer
   collects is silently orphaned.
3. **Confirm no subscription exists.** `enablementStatus` should still read `NOT_DETERMINED`, and
   the contact should show no push subscription. A contact with a real event history and no way
   to push to them is the correct shape, not a bug.
4. **`reset()`, then track again.** The anonymous ID on screen must change, and the new event
   must land on a *different* contact. This is what stops a shared handset handing the next user
   the previous one's history.

### The push API

5. **APNs token appears** near the top (device, or iOS 16+ simulator on an Apple-silicon Mac).
   The SDK registers with the backend as soon as it holds the token — registration is not
   consent, and it happens before any permission prompt.
6. **Registration confirmed** → diagnostics flips to `hasDeviceSecret: true` once the queue
   drains. *flushNow()* drains immediately instead of on the natural schedule.
7. **Confirm the contact binding.** The registration carries the anonymous id, so the
   subscription lands on the same contact the events built — the push subscription should appear
   on the contact from step 2, not a separate one. To assert the binding from a server instead,
   send the installation id shown on screen to your backend and have it call
   `POST /v1/push/devices` with your secret API key.
8. **Permission.** Press *Request notification permission* and watch the harness report the
   result. iOS shows this prompt **once per install**; on grant the SDK re-registers with the new
   `enablementStatus`.
9. **Send a push.** From the dashboard once the APNs send path ships (Option A), or simulate the
   payload locally today:

```bash
xcrun simctl push booted com.example.arselsample.staging Payloads/arsel-test.apns
```

Foreground: the `willPresent` delegate reports `displayed`. Background tap: `opened`. An action
button: `clicked` — one engagement per tap, never two. Simulated payloads carry no `arsel_sig`, so
the backend parks their engagements as unsigned rather than counting them — expected, and exactly why
a dashboard-sent campaign is the real test.

### Two ways to bind a device to a contact

| | Who asserts it | Trust |
| --- | --- | --- |
| `identify(externalId:…)` in the app | the **app** | A claim, resolved through the identifier ladder. Right for a value your own app already knows. |
| `POST /v1/push/devices` from your server | your **backend** | Authoritative, and it overrides the anonymous binding. Needs the secret API key. |

The harness only does the first: it has no backend of its own, and **the org's secret API key must
never be compiled into an app.** Do not "fix" that by adding a secret-key call here.

## 4. Reading `diagnostics()`

| Field | Means |
| --- | --- |
| `hasPushToken` / `pushVendor` | The SDK holds a token; this harness always registers `apns`. |
| `hasDeviceSecret` | `false` means every device-authenticated call is being refused; registration has not landed. |
| `hasAssertedIdentity` | `identify()` has supplied at least one identifier. Local state; the backend's own binding is what a campaign targets. |
| `optedOut` | `optOut()` was called; durable, survives re-registration. |
| `enablementStatus` | The five-state permission fact (`AUTHORIZED` / `DENIED` / `NOT_DETERMINED` / `PROVISIONAL` / `UNAUTHORIZED`), reported to the backend either way. |
| `anonymousId` | The identity events carry before login. Must change after `reset()`. |
| `pendingRequests` | Requests persisted but not yet delivered. A number that only grows is the tell — check `lastResponse`. |
| `lastResponse…` | Status + path of the last drained request. `400` is a contract error, `404` on a mutation is a rejected device secret or push not enabled for the org. |

## 5. Expected behaviours that look like bugs

| Symptom | Actually |
| --- | --- |
| `reset()` leaves the device receiving the old contact's campaigns | `reset()` rotates the identity for *future* events; it does not unbind the push subscription. Use `optOut()` when the user asks to stop entirely. |
| After `optOut()`, registration succeeds but nothing arrives | Correct. Opt-out is durable and is never resurrected by registration. |
| Engagements accepted (`202`) but no analytics rows | An engagement with no base `sent` record — or no valid signature — is parked, not counted. |
| No `delivered` engagements at all | The NSE needs `mutable-content: 1` in the payload **and** a provisioned App Group + shared Keychain group. iOS may still skip the extension; `delivered` is a floor, not a total. |
| Second `delivered` for the same message does nothing | Deduped server-side. |
| An event name starting `arsel.` is ignored | Reserved for the SDK's own events so customer names can never collide. |
| No `arsel.session_end` after backgrounding the app | Correct. It is emitted on the *next* foreground, backdated — there is no timer. A user who never returns produces none. |
| Events flow with `enablementStatus: NOT_DETERMINED` | Correct. The events API authenticates with the publishable key and never needs a device secret. |
| Campaign sends don't reach this device | The backend's direct-APNs send path is pending; this harness registers `vendor: "apns"`. See the README status note. |

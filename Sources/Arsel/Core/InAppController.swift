import Foundation

/// Everything in-app persists, in its own file.
///
/// Deliberately NOT folded into `PersistedState`: `StateStore.mutate` rewrites the whole file on
/// every change, and that file is touched on the hot path of every event. Putting a catalogue blob
/// in it would make each `track()` rewrite kilobytes of JSON.
struct InAppPersisted: Codable {
    var catalogueBody: String?
    var states: [String: InAppMessageState] = [:]
    var sessionStartedAtMs: Int64 = 0
    var sessionCounts: [String: Int] = [:]
}

final class InAppStore {
    private let fileURL: URL
    private var state: InAppPersisted
    private let log: ArselLog

    init(directory: URL, log: ArselLog) {
        self.fileURL = directory.appendingPathComponent("inapp.json")
        self.log = log
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(InAppPersisted.self, from: data) {
            self.state = decoded
        } else {
            self.state = InAppPersisted()
        }
    }

    var current: InAppPersisted { state }

    func mutate(_ change: (inout InAppPersisted) -> Void) {
        change(&state)
        do {
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch {
            log.e("could not persist in-app state: \(error)")
        }
    }
}

/// In-app messaging: fetch the eligibility catalogue, match triggers locally, enforce the
/// frequency rules, and report what was shown.
///
/// The division of labour is the whole design. The server answers *which* messages this device may
/// show — resolving audience, consent, campaign window, grants and lifetime caps, none of which a
/// handset can know — and this type answers *when*, so drawing a message costs no network call and
/// works with no connection at all.
///
/// Foundation only. Nothing here may import UIKit: the Linux CI job exists precisely to fail if it
/// does. `InAppPresenter` under `Platform/` is the only part that draws.
final class InAppController {
    private let store: InAppStore
    private let transport: Transport
    private let secrets: SecretStore
    private let enqueue: (QueuedRequest) -> Void
    private let log: ArselLog
    private let clock: () -> Int64

    private var catalogue: InAppCatalogue?
    private var activeMessageId: String?
    private var suppressed = false
    private var fetching = false

    /// Set once a display surface exists; absent on a headless host, where in-app stays inert.
    var present: ((InAppMessage) -> Void)?

    /// Defers a catalogue fetch to a later turn of the core's queue.
    ///
    /// `refresh()` blocks on the network, and `onEvent` runs inline on the event path — calling it
    /// directly would make an ordinary `track()` wait out an HTTP round-trip.
    var scheduleRefresh: (() -> Void)?

    /// Resolved lazily so the controller can be built before registration completes.
    private let context: () -> (clientKey: String, baseUrl: String, installationId: String)?

    init(
        store: InAppStore,
        transport: Transport,
        secrets: SecretStore,
        enqueue: @escaping (QueuedRequest) -> Void,
        context: @escaping () -> (clientKey: String, baseUrl: String, installationId: String)?,
        log: ArselLog,
        clock: @escaping () -> Int64 = nowMillis
    ) {
        self.store = store
        self.transport = transport
        self.secrets = secrets
        self.enqueue = enqueue
        self.context = context
        self.log = log
        self.clock = clock
        self.catalogue = InAppParser.catalogue(
            from: store.current.catalogueBody?.data(using: .utf8),
            nowMs: clock())
    }

    func setSuppressed(_ value: Bool) {
        suppressed = value
    }

    /// Every event the SDK enqueues passes through here, exactly once and never on a retry.
    ///
    /// App-open keys on the reserved `arsel.session_start` rather than the raw foreground signal:
    /// a session has a 30-minute gap rule, so a two-second tab-out is correctly not an app open.
    func onEvent(name: String, properties: [String: Any], timestampMs: Int64) {
        switch name {
        case EventBodies.sessionStart:
            onSessionWindow(timestampMs)
            // Deferred, so opening a session never blocks on the network. The trigger below
            // evaluates against the catalogue already on disk, which is the point of caching it.
            scheduleRefresh?()
            observe(type: InAppTrigger.appOpen, eventName: nil, properties: [:])
        case Self.screenViewEvent:
            guard let screen = properties[Self.screenNameProperty] as? String else { return }
            observe(type: InAppTrigger.screenView, eventName: screen, properties: stringify(properties))
        default:
            // Other reserved SDK events are bookkeeping, not intent.
            guard !name.hasPrefix(Self.reservedPrefix) else { return }
            observe(type: InAppTrigger.customEvent, eventName: name, properties: stringify(properties))
        }
    }

    /// Reserved `arsel_iam_sync` push: refresh only, and never render.
    func onSyncRequested() {
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        let now = clock()
        if !force, let cached = catalogue,
           now - cached.fetchedAtMs < Int64(cached.ttlSeconds) * 1000 {
            return
        }
        // Single-flight. The catalogue endpoint is throttled per ORG but not per device, so one
        // handset refetching in a loop can 429 every other device in the organization.
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        fetchCatalogue()
    }

    private func fetchCatalogue() {
        // No secret means registration has not completed. Silent by design: an org still being
        // set up is ordinary onboarding, not an error.
        guard let ctx = context(), let secret = secrets.read() else { return }

        let path = Wire.inAppCataloguePath(clientKey: ctx.clientKey, installationId: ctx.installationId)
        guard let url = URL(string: ctx.baseUrl + path) else { return }

        var headers = [Wire.deviceAuthHeader: secret]
        if let known = catalogue?.version {
            headers[Wire.ifNoneMatchHeader] = "\"\(known)\""
        }

        let response = transport.get(url: url, headers: headers, authenticated: true)

        // Checked before the result: a 304 classifies as success but carries no body, and parsing
        // one would blank the very cache the conditional request exists to preserve.
        if response.code == HTTP_NOT_MODIFIED {
            if let existing = catalogue {
                catalogue = InAppCatalogue(
                    version: existing.version,
                    ttlSeconds: existing.ttlSeconds,
                    fetchedAtMs: clock(),
                    messages: existing.messages)
            }
            return
        }
        guard response.result == .success,
              let parsed = InAppParser.catalogue(from: response.body, nowMs: clock()) else {
            // `reauth` deliberately does not clear the device secret: a bare 404 here also means an
            // unknown client key or an unprovisioned org, and the secret is minted exactly once.
            return
        }

        catalogue = parsed
        let body = response.body.flatMap { String(data: $0, encoding: .utf8) }
        let now = clock()
        store.mutate { persisted in
            persisted.catalogueBody = body
            persisted.states = Self.pruned(persisted.states, catalogue: parsed, nowMs: now)
        }
    }

    /// A trigger fired. Never throws — it sits on the caller's event path, and an in-app failure
    /// must not take an analytics event down with it.
    func observe(type: String, eventName: String?, properties: [String: String]) {
        guard let chosen = pick(nowMs: clock(), type: type, eventName: eventName, properties: properties) else {
            return
        }
        guard let present = present else {
            // Nothing can draw it, so the reservation must not be held.
            activeMessageId = nil
            return
        }
        present(chosen)
    }

    /// The first message in SERVER order that survives every rule.
    ///
    /// Deliberately no client-side sort: the backend already emits the documented precedence, and
    /// re-sorting here could only diverge from it invisibly.
    func pick(nowMs: Int64, type: String, eventName: String?, properties: [String: String]) -> InAppMessage? {
        // A trigger arriving while a message is on screen is DROPPED, not queued: a queued message
        // surfaces seconds after the interaction that supposedly caused it.
        guard !suppressed, activeMessageId == nil, let messages = catalogue?.messages else { return nil }
        let persisted = store.current

        for message in messages {
            guard message.triggerType == type else { continue }
            // A screen view and a custom event of the same name are distinct on the backend, and
            // collapsing them would fire screen-scoped messages everywhere.
            if type != InAppTrigger.appOpen, message.triggerEventName != eventName { continue }
            guard Self.propertiesMatch(want: message.triggerProperties, got: properties) else { continue }

            if let expiry = message.expiresAtMs, expiry <= nowMs {
                reportExpiryOnce(message)
                continue
            }
            let state = persisted.states[message.messageId]
            if (state?.shown ?? 0) >= message.maxLifetime { continue }
            if (persisted.sessionCounts[message.messageId] ?? 0) >= message.maxPerSession { continue }
            if let state = state,
               nowMs - state.lastShownAtMs < Int64(message.minSecondsBetween) * 1000 {
                continue
            }

            // Reserved at selection time, so a second trigger during a delay window cannot start a
            // competing message. Released by the presenter on close.
            activeMessageId = message.messageId
            return message
        }
        return nil
    }

    func releaseActive() {
        activeMessageId = nil
    }

    func recordImpression(_ message: InAppMessage, triggerEventName: String?) {
        let now = clock()
        store.mutate { persisted in
            let existing = persisted.states[message.messageId]
            persisted.states[message.messageId] = InAppMessageState(
                shown: (existing?.shown ?? 0) + 1,
                lastShownAtMs: now,
                lastSeenAtMs: existing?.lastSeenAtMs ?? now,
                expiredReported: existing?.expiredReported ?? false)
            persisted.sessionCounts[message.messageId] =
                (persisted.sessionCounts[message.messageId] ?? 0) + 1
        }
        var extra: [String: Any] = [:]
        if let triggerEventName = triggerEventName { extra["triggerEventName"] = triggerEventName }
        enqueueBeacon(message, event: InAppBeacon.impression, extra: extra)
    }

    func recordClick(_ message: InAppMessage, buttonId: String) {
        enqueueBeacon(message, event: InAppBeacon.clicked, extra: ["buttonId": buttonId])
    }

    /// Answers are keyed by `fieldId`, never by a destination.
    ///
    /// The catalogue does not carry `fieldKey` at all, so this SDK could not name where an
    /// answer lands even if it wanted to — the server resolves each id against the campaign.
    func recordSubmit(_ message: InAppMessage, submission: [String: String]) {
        guard !submission.isEmpty else { return }
        enqueueBeacon(message, event: InAppBeacon.submitted, extra: ["submission": submission])
    }

    func recordDismiss(_ message: InAppMessage, visibleSeconds: Int64) {
        let clamped = min(max(visibleSeconds, 0), Self.maxVisibleSeconds)
        enqueueBeacon(message, event: InAppBeacon.dismissed, extra: ["visibleSeconds": clamped])
    }

    private func reportExpiryOnce(_ message: InAppMessage) {
        guard store.current.states[message.messageId]?.expiredReported != true else { return }
        let now = clock()
        store.mutate { persisted in
            let existing = persisted.states[message.messageId]
            persisted.states[message.messageId] = InAppMessageState(
                shown: existing?.shown ?? 0,
                lastShownAtMs: existing?.lastShownAtMs ?? 0,
                lastSeenAtMs: existing?.lastSeenAtMs ?? now,
                expiredReported: true)
        }
        enqueueBeacon(message, event: InAppBeacon.expired, extra: [:])
    }

    /// `eventType` is LOWERCASE, and no key outside the DTO may be sent: the endpoint runs
    /// `forbidNonWhitelisted` with no per-route override, so an uppercase value or one stray
    /// property 400s the whole batch, taking every other beacon in it along.
    private func enqueueBeacon(_ message: InAppMessage, event: String, extra: [String: Any]) {
        var beacon: [String: Any] = [
            "messageId": message.messageId,
            "campaignId": message.campaignId,
            "eventType": event,
            // Stamped when it HAPPENED, not at drain: a beacon that waits out an offline spell
            // would otherwise land in the wrong hour bucket.
            "timestamp": InAppParser.isoTimestamp(clock()),
            "variantKey": message.variantKey,
        ]
        for (key, value) in extra { beacon[key] = value }

        guard let data = try? JSONSerialization.data(withJSONObject: beacon),
              let json = String(data: data, encoding: .utf8) else {
            log.e("could not serialize in-app beacon — dropping")
            return
        }
        enqueue(QueuedRequest(
            id: UUID().uuidString.lowercased(),
            kind: .inAppEvent,
            body: json,
            // Nil, matching events and engagements: two impressions of the same message are
            // distinct facts, and a shared key would let one evict the other before it was sent.
            dedupeKey: nil,
            createdAtMs: clock()))
    }

    private func onSessionWindow(_ startedAtMs: Int64) {
        guard store.current.sessionStartedAtMs != startedAtMs else { return }
        store.mutate { persisted in
            persisted.sessionStartedAtMs = startedAtMs
            persisted.sessionCounts = [:]
        }
    }

    private func stringify(_ properties: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in properties where !(value is NSNull) {
            out[key] = (value as? String) ?? String(describing: value)
        }
        return out
    }

    private static func propertiesMatch(want: [String: String], got: [String: String]) -> Bool {
        guard !want.isEmpty else { return true }
        return want.allSatisfy { got[$0.key] == $0.value }
    }

    /// Prune on age, never on catalogue membership.
    ///
    /// The catalogue is truncated server-side, so absence is not death: pruning on membership would
    /// reset the lifetime counters of a message pushed past the cap by a higher-priority campaign,
    /// and it would show all over again.
    private static func pruned(
        _ states: [String: InAppMessageState],
        catalogue: InAppCatalogue,
        nowMs: Int64
    ) -> [String: InAppMessageState] {
        let present = Set(catalogue.messages.map(\.messageId))
        var next: [String: InAppMessageState] = [:]
        for (id, state) in states {
            let lastSeen = present.contains(id) ? nowMs : state.lastSeenAtMs
            guard nowMs - lastSeen <= stateTtlMs else { continue }
            next[id] = InAppMessageState(
                shown: state.shown,
                lastShownAtMs: state.lastShownAtMs,
                lastSeenAtMs: lastSeen,
                expiredReported: state.expiredReported)
        }
        return next
    }

    private static let stateTtlMs: Int64 = 30 * 24 * 60 * 60 * 1000
    private static let maxVisibleSeconds: Int64 = 86_400
    private static let reservedPrefix = "arsel."

    /// Reserved event name for a screen view; the screen itself travels as a property.
    static let screenViewEvent = "arsel.screen_view"
    static let screenNameProperty = "screen_name"
}

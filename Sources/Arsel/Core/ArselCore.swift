import Foundation

/// Breaks the init-order cycle between the enqueue closure and `self`.
private final class DrainTrigger {
    var fire: (() -> Void)?
}

/// The engine behind the `Arsel` facade. All state mutation and all network
/// draining happen on one serial queue: drains are serialized by construction, and
/// there is exactly one writer for the state and queue files.
final class ArselCore {
    let config: ArselConfig
    private let serial = DispatchQueue(label: "sa.arsel.push.core", qos: .utility)
    private let log: ArselLog
    private let store: StateStore
    private let secrets: SecretStore
    private let requestQueue: RequestQueue
    private let drainer: Drainer
    let events: EventController
    let sessions: SessionTracker
    let push: PushController
    let inApp: InAppController

    private var drainScheduled = false
    private var consecutiveFailures = 0
    private var retryNotBeforeMs: Int64 = 0
    private let clock: () -> Int64

    init(
        config: ArselConfig,
        directory: URL,
        transport: Transport? = nil,
        secrets: SecretStore? = nil,
        clock: @escaping () -> Int64 = nowMillis,
        deviceSnapshot: @escaping () -> DeviceSnapshot = DeviceSnapshot.capture
    ) {
        let log = ArselLog(level: config.logLevel)
        self.log = log
        self.clock = clock
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.config = config
        self.store = StateStore(directory: directory, log: log)
        #if canImport(Security)
        self.secrets = secrets ?? KeychainSecretStore(accessGroup: config.keychainAccessGroup)
        #else
        self.secrets = secrets ?? FileSecretStore(directory: directory)
        #endif
        self.requestQueue = RequestQueue(directory: directory, log: log)
        // One instance, shared: a second URLSession would mean a second connection pool for the
        // same host, and the tests inject a single mock.
        let http = transport ?? URLSessionTransport(timeout: config.networkTimeout, log: log)
        self.drainer = Drainer(
            queue: requestQueue,
            store: store,
            secrets: self.secrets,
            transport: http,
            log: log,
            clock: clock)

        // Late-bound so the enqueue closure can be built before `self` is fully
        // initialized without capturing it.
        let trigger = DrainTrigger()
        let queueRef = requestQueue
        let enqueueRef: (QueuedRequest) -> Void = { request in
            queueRef.enqueue(request)
            trigger.fire?()
        }
        self.events = EventController(store: store, enqueue: enqueueRef, log: log, clock: clock)
        self.push = PushController(
            store: store, enqueue: enqueueRef, log: log, clock: clock, deviceSnapshot: deviceSnapshot)
        self.sessions = SessionTracker(store: store, events: events, clock: clock)

        let storeRef = store
        let clientKey = config.clientKey
        let baseUrl = config.baseUrl
        self.inApp = InAppController(
            store: InAppStore(directory: directory, log: log),
            transport: http,
            secrets: self.secrets,
            enqueue: enqueueRef,
            context: {
                guard let installationId = storeRef.current.installationId else { return nil }
                return (clientKey: clientKey, baseUrl: baseUrl, installationId: installationId)
            },
            log: log,
            clock: clock)
        // Wired here rather than at a later call site: the cold-start session fires from
        // `Arsel.initialize` before any host code runs, so an observer attached afterwards would
        // miss the first `arsel.session_start` of every launch — which is the app-open trigger.
        self.events.onEvent = { [weak self] name, properties, timestampMs in
            self?.inApp.onEvent(name: name, properties: properties, timestampMs: timestampMs)
        }
        self.inApp.scheduleRefresh = { [weak self] in
            guard let self = self else { return }
            self.serial.async { self.inApp.refresh() }
        }

        trigger.fire = { [weak self] in self?.scheduleDrain() }
        drainer.onNeedsRegistration = { [weak self] in
            // Called from inside a drain, already on the serial queue.
            self?.push.registerIfNeeded(force: true)
        }
        mirrorExtensionContext()
    }

    // MARK: Public-surface operations (each hops onto the serial queue)

    func track(_ name: String, properties: [String: Any] = [:]) {
        serial.async { self.events.track(name, properties: properties) }
    }

    /// For SDK-owned event names only. `track` refuses the `arsel.` prefix by design, and a screen
    /// view is one of ours: it carries trigger meaning the host cannot spell by convention.
    func trackReserved(_ name: String, properties: [String: Any] = [:]) {
        serial.async { self.events.trackReserved(name, properties: properties) }
    }

    func identify(externalId: String? = nil, email: String? = nil, phoneNumber: String? = nil) {
        serial.async {
            var email = email
            var phone = phoneNumber
            // Rejected here rather than stored: one malformed identifier would ride
            // every subsequent event, 400 each one, and silently drop them all.
            if let value = email, !Identifiers.isValidEmail(value) {
                self.log.e("identify(): '\(value)' is not a valid email address — ignored")
                email = nil
            }
            if let value = phone, !Identifiers.isValidPhone(value) {
                self.log.e("identify(): '\(value)' is not E.164 (e.g. +966501234567) — ignored")
                phone = nil
            }
            guard externalId != nil || email != nil || phone != nil else {
                self.log.w("identify() needs at least one of externalId, email or phoneNumber")
                return
            }
            self.store.mutate { state in
                if let externalId {
                    // A different externalId is a different person: the stored email
                    // and phone belonged to the previous identity.
                    if let previous = state.externalId, previous != externalId {
                        state.email = nil
                        state.phoneNumber = nil
                    }
                    state.externalId = externalId
                }
                if let email { state.email = email }
                if let phone { state.phoneNumber = phone }
            }
            // Sent immediately rather than on the next track(): the merge is what
            // the caller asked for.
            self.events.trackReserved(EventBodies.identify)
            self.push.registerIfNeeded()
        }
    }

    /// Logout. Rotates the anonymous identity so the next person on this device
    /// does not inherit the previous one's history, and forgets the identifiers.
    /// Deliberately does NOT touch the push opt-out — that is `optOut()`, and
    /// calling it here would permanently kill push on a shared device.
    func reset() {
        serial.async {
            self.store.mutate { state in
                state.externalId = nil
                state.email = nil
                state.phoneNumber = nil
                state.sessionStartedAtMs = 0
                state.backgroundedAtMs = 0
                state.anonymousId = UUID().uuidString.lowercased()
                // The registration carried the old anonymousId; invalidate so the
                // next one re-sends the new binding.
                state.lastRegisteredFingerprint = nil
            }
            self.push.registerIfNeeded()
            self.log.i("identity reset")
        }
    }

    func optOut() {
        serial.async { self.push.optOut() }
    }

    func setPushToken(_ token: String, vendor: ArselPushVendor) {
        serial.async {
            self.push.setToken(token, vendor: vendor)
            self.mirrorExtensionContext()
        }
    }

    func setEnablementStatus(_ status: ArselEnablementStatus) {
        serial.async { self.push.setEnablementStatus(status) }
    }

    func engagement(_ record: EngagementRecord) {
        serial.async { self.push.engagement(record) }
    }

    func onForeground() {
        serial.async {
            // Order matters: the session opens first, and its `arsel.session_start` is what drives
            // the in-app app-open trigger through the event observer. The refresh below only
            // covers a foreground that did NOT open a new session — inside the 30-minute gap the
            // catalogue can still have gone stale.
            self.sessions.onForeground()
            self.inApp.refresh()
            self.scheduleDrainLocked()
        }
    }

    /// Attach the display surface.
    ///
    /// Set from `Arsel.initialize` under `#if canImport(UIKit)` rather than constructed here:
    /// `Core/` is Foundation-only by CI contract, so it cannot name a UIKit type. Until this is
    /// set, in-app resolves triggers and then releases the slot without drawing.
    func setInAppPresenter(_ present: @escaping (InAppMessage) -> Void) {
        serial.async { self.inApp.present = present }
    }

    /// Hold in-app messages back, or let them through again.
    func setInAppMessagingEnabled(_ enabled: Bool) {
        serial.async { self.inApp.setSuppressed(!enabled) }
    }

    /// A reserved sync push asked us to refetch. Never renders.
    func onInAppSyncRequested() {
        serial.async { self.inApp.onSyncRequested() }
    }

    /// Called by the presenter once a message closes, so the next trigger can be taken.
    func releaseInAppSlot() {
        serial.async { self.inApp.releaseActive() }
    }

    func recordInAppImpression(_ message: InAppMessage, triggerEventName: String?) {
        serial.async { self.inApp.recordImpression(message, triggerEventName: triggerEventName) }
    }

    func recordInAppClick(_ message: InAppMessage, buttonId: String) {
        serial.async { self.inApp.recordClick(message, buttonId: buttonId) }
    }

    func recordInAppDismiss(_ message: InAppMessage, visibleSeconds: Int64) {
        serial.async { self.inApp.recordDismiss(message, visibleSeconds: visibleSeconds) }
    }

    func onBackground() {
        serial.async { self.sessions.onBackground() }
    }

    var anonymousId: String {
        serial.sync { store.anonymousIdOrCreate() }
    }

    func diagnostics() -> ArselDiagnostics {
        serial.sync {
            let state = store.current
            return ArselDiagnostics(
                sdkVersion: Wire.sdkVersion,
                configError: nil,
                anonymousId: state.anonymousId,
                hasAssertedIdentity: state.externalId != nil || state.email != nil || state.phoneNumber != nil,
                installationId: state.installationId,
                hasPushToken: state.pushToken != nil,
                pushVendor: state.pushVendor,
                hasDeviceSecret: secrets.read() != nil,
                optedOut: state.optedOut,
                enablementStatus: state.enablementStatus,
                pendingRequests: requestQueue.count,
                lastResponseCode: state.lastResponseCode,
                lastResponsePath: state.lastResponsePath,
                lastResponseAtMs: state.lastResponseAtMs)
        }
    }

    func flushNow() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            serial.async {
                self.drainOnce(force: true)
                continuation.resume()
            }
        }
    }

    // MARK: Drain scheduling

    /// Callable from any thread; coalesces to one queued drain.
    func scheduleDrain() {
        serial.async { self.scheduleDrainLocked() }
    }

    private func scheduleDrainLocked() {
        guard !drainScheduled else { return }
        drainScheduled = true
        serial.async {
            self.drainScheduled = false
            self.drainOnce(force: false)
        }
    }

    private func drainOnce(force: Bool) {
        // Honor Retry-After / backoff, except for an explicit flushNow().
        if !force && clock() < retryNotBeforeMs { return }
        guard let baseUrl = URL(string: config.baseUrl) else { return }
        let context = Drainer.Context(
            clientKey: config.clientKey,
            baseUrl: baseUrl,
            installationId: store.installationIdOrCreate())
        switch drainer.drain(context: context) {
        case .drained:
            consecutiveFailures = 0
            retryNotBeforeMs = 0
        case .retryLater(let retryAfterMs):
            consecutiveFailures += 1
            let backoffMs = min(Self.baseBackoffMs << min(consecutiveFailures - 1, 6), Self.maxBackoffMs)
            let waitMs = max(retryAfterMs ?? 0, backoffMs)
            retryNotBeforeMs = clock() + waitMs
            serial.asyncAfter(deadline: .now() + .milliseconds(Int(waitMs))) {
                self.drainOnce(force: false)
            }
        }
    }

    private static let baseBackoffMs: Int64 = 5_000
    private static let maxBackoffMs: Int64 = 5 * 60_000

    // MARK: Extension context

    /// Mirror the non-secret facts a Notification Service Extension needs for
    /// `delivered` engagements into the App Group container. The device secret is NOT
    /// here — it stays in the Keychain, shared via `keychainAccessGroup`.
    private func mirrorExtensionContext() {
        #if canImport(Darwin)
        guard let groupId = config.appGroupId,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupId) else { return }
        var context: [String: Any] = [
            "clientKey": config.clientKey,
            "baseUrl": config.baseUrl,
            "installationId": store.installationIdOrCreate(),
        ]
        if let accessGroup = config.keychainAccessGroup {
            context["keychainAccessGroup"] = accessGroup
        }
        let url = container.appendingPathComponent("arsel-extension-context.json")
        if let data = try? JSONSerialization.data(withJSONObject: context) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }

    // MARK: Default storage location

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("sa.arsel.push", isDirectory: true)
    }
}

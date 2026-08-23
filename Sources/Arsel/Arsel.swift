import Foundation

/// The Arsel iOS SDK: events, identity and push notifications.
///
/// **Two subsystems, and only one of them needs push.** `track()` and `identify()` work
/// on a device that has never granted notification permission and has no push token
/// at all — a user who declines notifications still has a contact and a behavioural
/// history. Only delivery needs push.
///
/// Every entry point is failure-isolated: an unconfigured or misconfigured SDK
/// logs and no-ops, it never throws at the host. Calls made before `initialize()`
/// are logged and ignored; getters return nil.
public enum Arsel {
    static var core: ArselCore?

    /// Why `initialize` declined to start, or nil. Surfaced via `diagnostics()`.
    static var configError: String?

    /// Start the SDK. Idempotent — call once, early (e.g. from
    /// `application(_:didFinishLaunchingWithOptions:)`).
    ///
    /// Deliberately does **not** request notification permission — a prompt with no
    /// user context converts terribly and is unrecoverable once declined. Call
    /// `requestNotificationPermission()` from a moment that explains itself.
    public static func initialize(config: ArselConfig) {
        guard core == nil else { return }
        if let problem = config.validationError() {
            // Log-and-refuse, never throw: the SDK must not crash the host over
            // configuration, but silence would be worse — this is loud on purpose,
            // and `diagnostics()` keeps the reason readable afterwards.
            configError = problem
            print("[arsel] initialize() refused: \(problem)")
            return
        }
        configError = nil
        let instance = ArselCore(config: config, directory: ArselCore.defaultDirectory())
        core = instance
        attachInAppPresenter(instance)
        attachLifecycleObservers()
        refreshPermissionState()
        // Anything stranded by a previous run's death goes out now.
        instance.scheduleDrain()
    }

    // MARK: Events

    /// Record something the user did. Persisted before send; returns immediately;
    /// safe from any thread and any actor.
    ///
    /// Property values must be JSON-representable; `Date` becomes an ISO-8601
    /// string, anything else is stringified. Blank names and names starting
    /// `arsel.` (the SDK's reserved prefix) are ignored.
    public static func track(_ name: String, properties: [String: Any] = [:]) {
        guard let core = requireCore("track") else { return }
        core.track(name, properties: properties)
    }

    // MARK: Identity

    /// The person using this device, as an id you already have. Everything tracked
    /// beforehand under the anonymous identity merges onto the contact this
    /// resolves to. Prefer `externalId` alone: it binds a contact without putting
    /// an email address into the app, and survives the user changing their address.
    ///
    /// `email` and `phoneNumber` are shape-checked (basic email shape; E.164 such
    /// as `+966501234567`) — an invalid value is rejected with a logged error, not
    /// stored. Changing `externalId` to a different value drops any stored email
    /// and phone: they belonged to the previous identity.
    public static func identify(
        externalId: String? = nil,
        email: String? = nil,
        phoneNumber: String? = nil
    ) {
        guard let core = requireCore("identify") else { return }
        core.identify(externalId: externalId, email: email, phoneNumber: phoneNumber)
    }

    /// Logout. Rotates the anonymous id and forgets the identifiers so the next
    /// person on this device does not inherit this one's history.
    ///
    /// Deliberately does **not** unsubscribe from push: the backend's opt-out is
    /// durable and non-resurrectable, so a logout that called it would permanently
    /// kill push on a shared device. That opt-out exists as `optOut()`, for the
    /// user who asks to stop receiving notifications.
    public static func reset() {
        guard let core = requireCore("reset") else { return }
        core.reset()
    }

    /// Durable push opt-out for this device — "stop sending me notifications", not
    /// logout. The revocation is server-side and non-resurrectable: a later
    /// registration of the same installation does not undo it.
    public static func optOut() {
        guard let core = requireCore("optOut") else { return }
        core.optOut()
    }

    // MARK: Push tokens

    /// Hand over the raw APNs device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func setPushToken(apns deviceToken: Data) {
        guard let core = requireCore("setPushToken") else { return }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        core.setPushToken(hex, vendor: .apns)
    }

    // MARK: Introspection

    /// Record a screen view.
    ///
    /// One event, two consumers: it reaches segments and automations exactly as `track` does, and
    /// it is the trigger source for screen-scoped in-app messages. Deliberately not a `track` call
    /// with a convention name — the backend treats a screen view and a custom event of the same
    /// name as different trigger types, and collapsing them here would fire screen-scoped messages
    /// on every event that happened to share a name.
    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var enriched = properties
        enriched[InAppController.screenNameProperty] = trimmed
        requireCore("screen")?.trackReserved(InAppController.screenViewEvent, properties: enriched)
    }

    /// Hold in-app messages back, or let them through again.
    ///
    /// For the moments a host knows are wrong — a checkout step, a video playing full screen. Not
    /// persisted: it describes the current screen, not the device.
    public static func setInAppMessagingEnabled(_ enabled: Bool) {
        requireCore("setInAppMessagingEnabled")?.setInAppMessagingEnabled(enabled)
    }

    /// The identity events carry before login. Rotated by `reset()`.
    /// Nil before `initialize()`.
    public static var anonymousId: String? {
        core?.anonymousId
    }

    /// A snapshot safe to paste into a support ticket — no secrets in it.
    /// Nil before `initialize()`.
    public static func diagnostics() -> ArselDiagnostics? {
        // A refused start is exactly when an integrator reaches for this, so it
        // answers with the reason rather than the nil that means "not called yet".
        if let configError {
            return ArselDiagnostics(
                sdkVersion: Wire.sdkVersion,
                configError: configError,
                anonymousId: nil,
                hasAssertedIdentity: false,
                installationId: nil,
                hasPushToken: false,
                pushVendor: nil,
                hasDeviceSecret: false,
                optedOut: false,
                enablementStatus: nil,
                pendingRequests: 0,
                lastResponseCode: nil,
                lastResponsePath: nil,
                lastResponseAtMs: nil)
        }
        return core?.diagnostics()
    }

    /// Deliver anything queued now, rather than on the next natural drain.
    public static func flushNow() async {
        await core?.flushNow()
    }

    // MARK: -

    private static func requireCore(_ entryPoint: String) -> ArselCore? {
        guard let core else {
            print("[arsel] \(entryPoint)() called before initialize() — ignoring")
            return nil
        }
        return core
    }
}

#if canImport(UIKit)
private var inAppPresenter: InAppPresenter?

/// Attaches the UIKit display surface.
///
/// Held in a file-scope variable rather than on `Arsel` so the enum's public surface stays exactly
/// what integrators see, and so `Core/` never names a UIKit type.
private func attachInAppPresenter(_ core: ArselCore) {
    let presenter = InAppPresenter(core: core)
    inAppPresenter = presenter
    core.setInAppPresenter { message in presenter.present(message) }
}
#else
/// No display surface off-Apple-platforms; in-app resolves triggers and draws nothing.
private func attachInAppPresenter(_ core: ArselCore) {}
#endif

import Foundation

/// Configuration for `Arsel.initialize(config:)`.
public struct ArselConfig: Sendable {
    /// The org's publishable `pub_…` key. Safe to compile into an app — it
    /// authenticates the events and push APIs and grants nothing a secret API key
    /// does. Your secret API key is not: anyone can inspect an IPA.
    public let clientKey: String

    /// Arsel API base, e.g. `https://api.arsel.sa`. HTTPS enforced, except
    /// `http://localhost` / `http://127.0.0.1` for a local backend.
    public let baseUrl: String

    /// Off (`.warn`) by default.
    public let logLevel: ArselLogLevel

    /// Per-request network timeout.
    public let networkTimeout: TimeInterval

    /// An App Group identifier shared with your Notification Service Extension
    /// (e.g. `group.com.example.app`). Required only for `delivered` engagements: the
    /// SDK mirrors non-secret context (client key, base URL, installation id) into
    /// the shared container so the extension can report deliveries.
    public let appGroupId: String?

    /// A shared Keychain access group so the Notification Service Extension can
    /// read the device secret that authenticates its `delivered` engagements. Both
    /// targets must carry the matching Keychain Sharing entitlement.
    public let keychainAccessGroup: String?

    public init(
        clientKey: String,
        baseUrl: String,
        logLevel: ArselLogLevel = .warn,
        networkTimeout: TimeInterval = 15,
        appGroupId: String? = nil,
        keychainAccessGroup: String? = nil
    ) {
        self.clientKey = clientKey
        var trimmed = baseUrl
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseUrl = trimmed
        self.logLevel = logLevel
        self.networkTimeout = networkTimeout
        self.appGroupId = appGroupId
        self.keychainAccessGroup = keychainAccessGroup
    }

    /// Nil when the configuration cannot work; `initialize` logs and refuses to
    /// start rather than crashing the host.
    func validationError() -> String? {
        if clientKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return "clientKey is required (the org's publishable pub_… key)"
        }
        if !clientKey.hasPrefix("pub_") {
            return "clientKey should be the publishable pub_… key — never a secret API key"
        }
        // Anchored, not a prefix match: `http://localhost.evil.com` satisfies
        // hasPrefix("http://localhost") and would otherwise be exempted.
        let localhostHttp = baseUrl.range(
            of: #"^http://(localhost|127\.0\.0\.1)(:\d+)?(/.*)?$"#,
            options: .regularExpression) != nil
        if !baseUrl.hasPrefix("https://") && !localhostHttp {
            return "baseUrl must be HTTPS (http is allowed for localhost only)"
        }
        if URL(string: baseUrl) == nil { return "baseUrl is not a valid URL" }
        return nil
    }
}

/// A point-in-time snapshot safe to paste into a support ticket — no secrets in it.
public struct ArselDiagnostics: Sendable {
    public let sdkVersion: String
    /// Why the SDK refused to start, or nil. Set when `initialize` was given an
    /// invalid configuration: nothing is collected and no call has any effect
    /// until it is fixed. Same field, same rules, on all three Arsel SDKs.
    public let configError: String?
    public let anonymousId: String?
    public let hasAssertedIdentity: Bool
    public let installationId: String?
    public let hasPushToken: Bool
    public let pushVendor: String?
    public let hasDeviceSecret: Bool
    public let optedOut: Bool
    public let enablementStatus: String?
    /// Requests persisted but not yet delivered. A number that only grows is the tell.
    public let pendingRequests: Int
    public let lastResponseCode: Int?
    public let lastResponsePath: String?
    public let lastResponseAtMs: Int64?
}

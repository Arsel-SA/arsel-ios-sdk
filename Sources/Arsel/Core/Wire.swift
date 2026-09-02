import Foundation

/// The wire contract as this SDK implements it, mirrored from the Arsel API.
/// When this file and the backend disagree, the backend wins.
enum Wire {
    /// Bumped per release — and `ExtensionWire.sdkVersion` with it (see RELEASING.md).
    static let sdkVersion = "1.4.0"

    // MARK: Routes

    static let eventsPath = "/v1/events/send"

    static func subscriptionsPath(clientKey: String) -> String {
        "/api/v1/orgs/\(clientKey)/push/subscriptions"
    }

    static func statePath(clientKey: String) -> String {
        subscriptionsPath(clientKey: clientKey) + "/state"
    }

    static func unsubscribePath(clientKey: String) -> String {
        subscriptionsPath(clientKey: clientKey) + "/unsubscribe"
    }

    static func engagementsPath(clientKey: String) -> String {
        "/api/v1/orgs/\(clientKey)/push/engagements"
    }

    static func inAppCataloguePath(clientKey: String, installationId: String) -> String {
        "/api/v1/orgs/\(clientKey)/in-app/bundle?installationId=\(installationId)"
    }

    static func inAppEventsPath(clientKey: String) -> String {
        "/api/v1/orgs/\(clientKey)/in-app/events"
    }

    // MARK: Headers

    static let sdkHeader = "X-Arsel-SDK"
    static let sdkHeaderValue = "ios/\(sdkVersion)"
    static let deviceAuthHeader = "X-Arsel-Device-Auth"
    static let authorizationHeader = "Authorization"
    static let bearerPrefix = "Bearer "
    static let idempotencyKeyHeader = "Idempotency-Key"
    static let ifNoneMatchHeader = "If-None-Match"

    // MARK: Limits

    /// `PUSH_ENGAGEMENT_BATCH_MAX` / the `{ events: [...] }` ceiling on `POST /v1/events/send`.
    /// Raising either on the backend is safe; lowering is not.
    static let eventBatchMax = 50
    static let engagementBatchMax = 50

    /// `IngestEventDto` `@Length` caps, applied client-side so the 400 never happens.
    static let maxEventName = 80
    static let maxAnonymousId = 128
    static let maxExternalId = 255

    // MARK: Push payload data keys (`PUSH_DATA_KEYS`)

    /// Same keys for both vendors; they arrive in the APNs `userInfo` dictionary.
    enum DataKey {
        static let version = "arsel_v"
        static let messageId = "arsel_mid"
        static let signature = "arsel_sig"
        static let signatureKeyId = "arsel_kid"
        static let title = "arsel_title"
        static let body = "arsel_body"
        static let image = "arsel_image"
        static let deepLink = "arsel_deep_link"
        static let channelId = "arsel_channel_id"
        static let actions = "arsel_actions"
        static let collapseId = "arsel_collapse_id"

        /// Reserved: refresh the in-app catalogue and render nothing at all.
        static let inAppSync = "arsel_iam_sync"
    }

    /// Current `arsel_v`.
    static let wireVersion = "1"
}

/// `PushPlatform` / `PushVendor` wire values.
enum WirePlatform {
    static let ios = "ios"
}

/// Only one value on iOS: Arsel talks to Apple directly, so an FCM token minted
/// by the host's own Firebase project is not addressable by us.
public enum ArselPushVendor: String, Sendable {
    /// A raw APNs device token from `didRegisterForRemoteNotificationsWithDeviceToken`.
    case apns
}

/// OS notification permission, in the five states the backend's
/// `PushEnablementStatus` enum records. Values match the wire exactly.
public enum ArselEnablementStatus: String, Sendable {
    case authorized = "AUTHORIZED"
    case denied = "DENIED"
    case notDetermined = "NOT_DETERMINED"
    case provisional = "PROVISIONAL"
    /// Reserved on the wire; not produced by this SDK's `UNAuthorizationStatus` mapping.
    case unauthorized = "UNAUTHORIZED"
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The handful of wire constants this target shares with the main SDK, duplicated
/// on purpose: `ArselNotificationExtension` is linked into a Notification Service
/// Extension and must stay tiny, so it does not depend on the `Arsel` target.
/// Change one, change both (the authoritative contract is the Arsel API).
enum ExtensionWire {
    /// Kept in lockstep with `Wire.sdkVersion` (see RELEASING.md).
    static let sdkVersion = "1.3.0"
    static let sdkHeader = "X-Arsel-SDK"
    static let sdkHeaderValue = "ios/\(sdkVersion)"
    static let deviceAuthHeader = "X-Arsel-Device-Auth"
    static let messageIdKey = "arsel_mid"
    static let versionKey = "arsel_v"
    static let signatureKey = "arsel_sig"
    static let signatureKeyIdKey = "arsel_kid"
    static let imageKey = "arsel_image"
    static let contextFileName = "arsel-extension-context.json"

    static func engagementsPath(clientKey: String) -> String {
        "/api/v1/orgs/\(clientKey)/push/engagements"
    }
}

/// The non-secret facts the main SDK mirrors into the App Group container.
struct ExtensionContext {
    let clientKey: String
    let baseUrl: String
    let installationId: String
    let keychainAccessGroup: String?

    static func decode(_ data: Data) -> ExtensionContext? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientKey = parsed["clientKey"] as? String,
              let baseUrl = parsed["baseUrl"] as? String,
              let installationId = parsed["installationId"] as? String else { return nil }
        return ExtensionContext(
            clientKey: clientKey,
            baseUrl: baseUrl,
            installationId: installationId,
            keychainAccessGroup: parsed["keychainAccessGroup"] as? String)
    }

    static func load(appGroupId: String) -> ExtensionContext? {
        #if canImport(Darwin)
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let url = container.appendingPathComponent(ExtensionWire.contextFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
        #else
        return nil
        #endif
    }
}

/// Builds the one-engagement `PushEngagementBatchDto` body the extension sends. Pure, so
/// the Linux tests can pin the shape.
enum ExtensionEngagement {
    static func deliveredBody(
        installationId: String,
        messageId: String,
        signature: String?,
        signatureKeyId: String?,
        timestamp: Date = Date()
    ) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        var event: [String: Any] = [
            "messageId": messageId,
            "eventType": "delivered",
            "timestamp": formatter.string(from: timestamp),
        ]
        if let signature { event["signature"] = signature }
        if let signatureKeyId { event["signatureKeyId"] = signatureKeyId }
        return ["installationId": installationId, "events": [event]]
    }
}

#if canImport(Security)
import Security

/// Reads the device secret the main SDK stored, via the shared Keychain access
/// group. Read-only: the extension never mints or rotates secrets.
enum ExtensionSecret {
    static func read(accessGroup: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sa.arsel.push",
            kSecAttrAccount as String: "deviceSecret",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif

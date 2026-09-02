import Foundation

/// A parsed engagement signal, persisted as one queue record; the drain wraps
/// consecutive runs into the `PushEngagementBatchDto` envelope.
struct EngagementRecord {
    /// The SDK-reportable subset of the backend's `PushEventType`.
    enum EventType: String {
        case delivered, displayed, suppressed, opened, clicked, dismissed
    }

    let messageId: String
    // var: the tap handler builds an `opened` record and rewrites it to
    // `clicked`/`dismissed` once the action identifier is known.
    var eventType: EventType
    let timestampMs: Int64
    var signature: String? = nil
    var signatureKeyId: String? = nil
    /// Present on `clicked`: which action button was tapped.
    var actionId: String? = nil
    var deepLink: String? = nil
    var suppressionReason: String? = nil

    /// `PushEngagementDto`.
    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "messageId": messageId,
            "eventType": eventType.rawValue,
            "timestamp": EventBodies.iso8601(timestampMs: timestampMs),
        ]
        if let signature { json["signature"] = signature }
        if let signatureKeyId { json["signatureKeyId"] = signatureKeyId }
        if let actionId { json["actionId"] = actionId }
        if let deepLink { json["deepLink"] = deepLink }
        if let suppressionReason { json["suppressionReason"] = suppressionReason }
        return json
    }
}

/// A device snapshot at registration/state-report time. Foundation-only — model and
/// OS facts come from `utsname`/`ProcessInfo`, so the Linux tests can build one.
struct DeviceSnapshot {
    var appVersion: String?
    var osVersion: String?
    var deviceModel: String?
    var deviceManufacturer: String? = "Apple"
    var deviceTimezone: String?
    var deviceLocale: String?
    var enablementStatus: String?

    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func capture() -> DeviceSnapshot {
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceSnapshot(
            appVersion: Self.appVersion,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            deviceModel: model.isEmpty ? nil : model,
            deviceTimezone: TimeZone.current.identifier,
            deviceLocale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
    }
}

/// Pure construction of the push-API request bodies. These must match the backend
/// DTOs byte for byte — `forbidNonWhitelisted` turns a stray field into a 400 that
/// fails the whole call. Each builder names its DTO so a backend change has an
/// obvious counterpart here.
enum PushBodies {
    /// `RegisterPushSubscriptionDto`.
    ///
    /// - Parameter anonymousId: the device→contact binding. The backend resolves it
    ///   through the same identifier ladder the events API uses, so a subscription
    ///   registered before `identify()` still reaches the contact the events built.
    static func register(
        installationId: String,
        vendor: ArselPushVendor,
        deviceToken: String,
        anonymousId: String,
        apnsEnvironment: String,
        device: DeviceSnapshot
    ) -> [String: Any] {
        var body: [String: Any] = [
            "installationId": installationId,
            "platform": WirePlatform.ios,
            "vendor": vendor.rawValue,
            "deviceToken": deviceToken,
            "anonymousId": anonymousId,
        ]
        // Which Apple host the token is addressable on; nothing in the token says.
        body["apnsEnvironment"] = apnsEnvironment
        // Absent facts stay absent — never JSON null.
        if let status = device.enablementStatus { body["enablementStatus"] = status }
        if let value = device.appVersion { body["appVersion"] = value }
        if let value = device.osVersion { body["osVersion"] = value }
        if let value = device.deviceModel { body["deviceModel"] = value }
        if let value = device.deviceManufacturer { body["deviceManufacturer"] = value }
        if let value = device.deviceTimezone { body["deviceTimezone"] = value }
        if let value = device.deviceLocale { body["deviceLocale"] = value }
        return body
    }

    /// `PushDeviceStateDto`. `deviceModel`/`deviceManufacturer` are absent from the
    /// DTO because they cannot change for an installation; `anonymousId` has no
    /// field here either, which is why an identity change routes to `register`.
    static func state(
        installationId: String,
        deviceToken: String,
        device: DeviceSnapshot
    ) -> [String: Any] {
        var body: [String: Any] = [
            "installationId": installationId,
            "deviceToken": deviceToken,
        ]
        if let status = device.enablementStatus { body["enablementStatus"] = status }
        if let value = device.appVersion { body["appVersion"] = value }
        if let value = device.osVersion { body["osVersion"] = value }
        if let value = device.deviceTimezone { body["deviceTimezone"] = value }
        if let value = device.deviceLocale { body["deviceLocale"] = value }
        return body
    }

    /// `UnsubscribePushSubscriptionDto`.
    static func unsubscribe(installationId: String) -> [String: Any] {
        ["installationId": installationId]
    }

    /// `PushEngagementBatchDto`. The caller is responsible for the batch ceiling.
    static func engagements(installationId: String, events: [[String: Any]]) -> [String: Any] {
        ["installationId": installationId, "events": events]
    }
}

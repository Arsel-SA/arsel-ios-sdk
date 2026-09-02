import Foundation

/// Pure construction of the `POST /v1/events/send` body.
///
/// Every field name below is a `class-validator` property on the backend's
/// `IngestEventDto` (snake_case on the wire), and `forbidNonWhitelisted` turns a
/// stray one into a 400 that loses the event. Foundation-only so the Linux tests
/// can assert the shape field by field.
enum EventBodies {
    /// Reserved prefix for SDK-emitted events, so a customer's own names can never collide.
    static let reservedPrefix = "arsel."
    static let sessionStart = "\(reservedPrefix)session_start"
    static let sessionEnd = "\(reservedPrefix)session_end"
    static let identify = "\(reservedPrefix)identify"
    static let appInstalled = "\(reservedPrefix)app_installed"

    static let maxDataDepth = 8
    static let maxDataBytes = 64 * 1024

    /// - Parameter anonymousId: always sent, even once identified — it is the
    ///   identity the backend merges FROM.
    static func event(
        name: String,
        properties: [String: Any],
        anonymousId: String,
        externalId: String?,
        email: String?,
        phoneNumber: String?,
        timestampMs: Int64
    ) -> [String: Any] {
        var body: [String: Any] = [
            "event": String(name.prefix(Wire.maxEventName)),
            "anonymous_id": String(anonymousId.prefix(Wire.maxAnonymousId)),
            "data": sanitize(properties),
            "timestamp": iso8601(timestampMs: timestampMs),
        ]
        // Absent, never JSON null — the DTO's @IsString would reject null.
        if let externalId { body["external_id"] = String(externalId.prefix(Wire.maxExternalId)) }
        if let email { body["email"] = email }
        if let phoneNumber { body["phone_number"] = phoneNumber }
        return body
    }

    /// `data` must be wire-safe JSON, bounded so one huge property cannot 413 the
    /// whole drain. JSON-safe values pass through; Dates become ISO-8601 strings;
    /// non-finite numbers become strings (they are not valid JSON); everything else
    /// is stringified rather than dropped — a readable string in the event beats a
    /// field that silently vanished. The depth cap also terminates cycles.
    static func sanitize(_ properties: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        var bytes = 2
        var dropped = false
        for (key, raw) in properties {
            guard !key.isEmpty else { continue }
            guard let value = sanitizeValue(raw, depth: 0) else { continue }
            let cost = key.count + serializedSize(value) + 6
            if bytes + cost > maxDataBytes {
                dropped = true
                continue
            }
            bytes += cost
            out[key] = value
        }
        if dropped {
            print("[arsel] event data exceeded \(maxDataBytes) serialized bytes — oversized properties were dropped")
        }
        return out
    }

    private static func sanitizeValue(_ value: Any, depth: Int) -> Any? {
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool
        case let int as Int: return int
        case let int64 as Int64: return int64
        case let double as Double:
            return double.isFinite ? double : String(double)
        case let float as Float:
            return float.isFinite ? Double(float) : String(float)
        case let date as Date:
            return iso8601(timestampMs: Int64(date.timeIntervalSince1970 * 1000))
        case is NSNull: return NSNull()
        case let array as [Any]:
            guard depth < maxDataDepth else { return nil }
            // nil has no JSON form inside an array; NSNull keeps the indices stable.
            return array.map { sanitizeValue($0, depth: depth + 1) ?? NSNull() }
        case let dict as [String: Any]:
            guard depth < maxDataDepth else { return nil }
            var out: [String: Any] = [:]
            for (key, item) in dict where !key.isEmpty {
                if let clean = sanitizeValue(item, depth: depth + 1) { out[key] = clean }
            }
            return out
        default:
            return String(describing: value)
        }
    }

    private static func serializedSize(_ value: Any) -> Int {
        if JSONSerialization.isValidJSONObject([value]),
           let data = try? JSONSerialization.data(withJSONObject: [value]) {
            return max(0, data.count - 2)
        }
        return String(describing: value).count
    }

    /// Explicit POSIX/UTC formatter rather than the device default — a Hijri or
    /// Buddhist default calendar would otherwise emit a year the backend's
    /// `@IsISO8601` parser rejects, on exactly the handsets this SDK's first
    /// customers ship to.
    static func iso8601(timestampMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestampMs) / 1000))
    }
}

/// Client-side shape checks for `identify()`. A malformed identifier must be
/// rejected *before* it is stored: identifiers ride every later event, so a stored
/// bad value turns each of them into a permanent 400 and drops the user's entire
/// history from that point — unfixable from a shipped app.
enum Identifiers {
    /// E.164, as the backend validates it.
    static func isValidPhone(_ value: String) -> Bool {
        guard value.hasPrefix("+"), value.count >= 8, value.count <= 16 else { return false }
        let digits = value.dropFirst()
        guard let first = digits.first, first != "0" else { return false }
        return digits.allSatisfy(\.isNumber) && digits.allSatisfy(\.isASCII)
    }

    /// Shape only — real validation is the backend's job; this catches "clearly not an email".
    static func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return !value.contains(where: \.isWhitespace)
    }
}

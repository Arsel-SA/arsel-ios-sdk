import Foundation

/// One renderable in-app message, exactly as the catalogue describes it.
struct InAppMessage {
    let campaignId: String
    let messageId: String
    let variantKey: String
    let expiresAtMs: Int64?
    let triggerType: String
    let triggerEventName: String?
    let triggerProperties: [String: String]
    let maxPerSession: Int
    let maxLifetime: Int
    let minSecondsBetween: Int
    let delaySeconds: Int
    let layout: String
    let headline: String
    let body: String
    let imageUrl: String?
    let backgroundColor: String?
    let textColor: String?
    let showCloseButton: Bool
    let buttons: [InAppButton]
    /// Present only on FORM and RATING. Never carries a destination key.
    let fields: [InAppField]
    /// Present only on CUSTOM_HTML.
    let customHtml: InAppCustomHtml?
}

/// Author-supplied markup and the terms it is drawn under.
///
/// `allowJavaScript` is a capability the renderer withholds, not a request the markup can make:
/// it decides whether the web view is given script at all, so a creative authored without script
/// cannot turn script on for itself.
struct InAppCustomHtml {
    let source: String
    let html: String?
    let url: String?
    let allowJavaScript: Bool
    let overlayStyle: String
}

enum InAppHtmlSource {
    static let inline = "INLINE"
    static let url = "URL"
}

enum InAppOverlayStyle {
    static let transparent = "TRANSPARENT"
    static let dark = "DARK"
}

/// A field as the device sees it.
///
/// `fieldKey` — where the answer is stored — is deliberately absent from the wire, so this SDK
/// cannot name a destination. Answers are reported against `fieldId` and the server resolves the
/// rest against the campaign it holds.
struct InAppField {
    let fieldId: String
    let type: String
    let label: String
    let required: Bool
    let placeholder: String?
    let options: [InAppFieldOption]
    let scale: Int?
}

struct InAppFieldOption {
    let label: String
    let value: String
}

struct InAppButton {
    let buttonId: String
    let label: String
    let action: String
    let value: String?
}

/// The catalogue as fetched.
///
/// Server order is preserved and never re-sorted: the backend already emits
/// priority-descending, then earliest expiry, then campaign id — exactly the documented
/// precedence — and a client-side sort could only ever diverge from it invisibly.
struct InAppCatalogue {
    let version: String
    let ttlSeconds: Int
    let fetchedAtMs: Int64
    let messages: [InAppMessage]
}

/// Per-message lifetime counters. Device-scoped, and deliberately survives a logout:
/// it records what this handset has already shown a person.
struct InAppMessageState: Codable {
    var shown: Int
    var lastShownAtMs: Int64
    var lastSeenAtMs: Int64
    var expiredReported: Bool
}

enum InAppTrigger {
    static let appOpen = "APP_OPEN"
    static let screenView = "SCREEN_VIEW"
    static let customEvent = "CUSTOM_EVENT"
}

enum InAppLayout {
    static let modal = "MODAL"
    static let bannerTop = "BANNER_TOP"
    static let bannerBottom = "BANNER_BOTTOM"
    static let fullscreen = "FULLSCREEN"
    static let imageOnly = "IMAGE_ONLY"
    static let halfInterstitial = "HALF_INTERSTITIAL"
    static let alert = "ALERT"
    static let form = "FORM"
    static let rating = "RATING"
    static let customHtml = "CUSTOM_HTML"

    /// Layouts this build can draw.
    ///
    /// The client half of the server's `IN_APP_SUPPORTED_LAYOUTS`; the two have to be extended
    /// together. The server gates on the version this SDK reports, but a build handed a layout
    /// missing from this set drops the message silently — the one failure this channel has no
    /// surface to detect.
    static let all: Set<String> = [
        modal, bannerTop, bannerBottom, fullscreen, imageOnly,
        halfInterstitial, alert, form, rating, customHtml,
    ]

    /// Layouts that collect answers and therefore draw inputs.
    static let inputs: Set<String> = [form, rating]

    /// Layouts that dim the app behind them. Banners deliberately do not.
    static let scrimmed: Set<String> = [
        modal, fullscreen, halfInterstitial, alert, form, rating, customHtml,
    ]
}

enum InAppFieldType {
    static let text = "text"
    static let email = "email"
    static let tel = "tel"
    static let dropdown = "dropdown"
    static let radio = "radio"
    static let checkbox = "checkbox"
    static let rating = "rating"

    static let all: Set<String> = [text, email, tel, dropdown, radio, checkbox, rating]
}

/// Matches DEFAULT_IN_APP_RATING_SCALE on the server.
let inAppDefaultRatingScale = 5

enum InAppAction {
    static let deepLink = "DEEP_LINK"
    static let url = "URL"
    static let dismiss = "DISMISS"
    static let customEvent = "CUSTOM_EVENT"
}

enum InAppBeacon {
    static let impression = "impression"
    static let clicked = "clicked"
    static let dismissed = "dismissed"
    static let expired = "expired"
    static let submitted = "submitted"
}

/// Parses the catalogue.
///
/// Every optional field comes out of a Postgres `jsonb` column and is three-state — absent,
/// explicitly null, or present. `JSONSerialization` gives back `NSNull` for the middle case, which
/// a plain `as? String` silently turns into nil along with "absent"; that is fine here because both
/// mean the same thing to us, but a field whose ABSENCE has a different default from its NULL must
/// be read explicitly. A parser that dropped messages on either would fail silently, and silence is
/// the one failure this channel cannot detect from any surface.
enum InAppParser {
    static let defaultVariant = "default"
    static let defaultTtlSeconds = 900

    static func catalogue(from data: Data?, nowMs: Int64) -> InAppCatalogue? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The envelope is never key-validated: the backend's global success interceptor spreads
        // `message` and `timestamp` alongside the contract fields.
        guard let version = string(root["bundleVersion"]) else { return nil }

        let raw = root["messages"] as? [[String: Any]] ?? []
        let parsed = raw.compactMap { message(from: $0) }

        let ttl = root["ttlSeconds"] as? Int ?? defaultTtlSeconds
        return InAppCatalogue(
            version: version,
            ttlSeconds: ttl > 0 ? ttl : defaultTtlSeconds,
            fetchedAtMs: nowMs,
            messages: parsed)
    }

    static func message(from json: [String: Any]) -> InAppMessage? {
        guard let campaignId = string(json["campaignId"]),
              let messageId = string(json["messageId"]),
              let layout = string(json["layout"]),
              InAppLayout.all.contains(layout),
              let content = json["content"] as? [String: Any],
              let headline = string(content["headline"]) else {
            return nil
        }

        let custom = customHtml(from: json["customHtml"])
        // Dropped whole, not degraded to a bare headline panel: the author designed markup, and a
        // stray text modal in its place is a worse outcome than the message not appearing.
        if layout == InAppLayout.customHtml, custom == nil { return nil }

        let trigger = json["trigger"] as? [String: Any] ?? [:]
        let rules = json["displayRules"] as? [String: Any] ?? [:]

        return InAppMessage(
            campaignId: campaignId,
            messageId: messageId,
            variantKey: string(json["variantKey"]) ?? defaultVariant,
            expiresAtMs: millis(from: string(json["expiresAt"])),
            triggerType: string(trigger["type"]) ?? InAppTrigger.appOpen,
            triggerEventName: string(trigger["eventName"]),
            triggerProperties: properties(from: trigger["properties"]),
            maxPerSession: rules["maxPerSession"] as? Int ?? 1,
            maxLifetime: rules["maxLifetime"] as? Int ?? 3,
            minSecondsBetween: rules["minSecondsBetween"] as? Int ?? 86_400,
            delaySeconds: rules["delaySeconds"] as? Int ?? 0,
            layout: layout,
            headline: headline,
            body: string(content["body"]) ?? "",
            imageUrl: string(content["imageUrl"]),
            backgroundColor: string(content["backgroundColor"]),
            textColor: string(content["textColor"]),
            // Absent means "not suppressed"; only an explicit false hides it.
            showCloseButton: content["showCloseButton"] as? Bool ?? true,
            buttons: buttons(from: json["buttons"]),
            fields: fields(from: json["fields"]),
            customHtml: custom)
    }

    /// Nil when the declared source carries no payload, which drops the whole message: an empty
    /// sandbox still reports a healthy impression, and that is indistinguishable from delivery.
    private static func customHtml(from raw: Any?) -> InAppCustomHtml? {
        guard let json = raw as? [String: Any],
              let source = string(json["source"]),
              source == InAppHtmlSource.inline || source == InAppHtmlSource.url else {
            return nil
        }

        let html = string(json["html"])
        let url = string(json["url"])
        if source == InAppHtmlSource.inline, html == nil { return nil }
        if source == InAppHtmlSource.url, url == nil { return nil }

        return InAppCustomHtml(
            source: source,
            html: html,
            url: url,
            // Absent means OFF. Anything but an explicit true leaves the web view scriptless.
            allowJavaScript: json["allowJavaScript"] as? Bool ?? false,
            overlayStyle: string(json["overlayStyle"]) == InAppOverlayStyle.transparent
                ? InAppOverlayStyle.transparent
                : InAppOverlayStyle.dark)
    }

    /// An unknown field type is dropped rather than guessed at. Rendering one this build does
    /// not understand as a text box would collect an answer the server then refuses, which reads
    /// to the user as the form being broken.
    private static func fields(from raw: Any?) -> [InAppField] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let fieldId = string(item["fieldId"]),
                  let label = string(item["label"]),
                  let type = string(item["type"]),
                  InAppFieldType.all.contains(type) else {
                return nil
            }
            return InAppField(
                fieldId: fieldId,
                type: type,
                label: label,
                required: item["required"] as? Bool ?? false,
                placeholder: string(item["placeholder"]),
                options: fieldOptions(from: item["options"]),
                scale: item["scale"] as? Int)
        }
    }

    private static func fieldOptions(from raw: Any?) -> [InAppFieldOption] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let label = string(item["label"]),
                  let value = string(item["value"]) else {
                return nil
            }
            return InAppFieldOption(label: label, value: value)
        }
    }

    private static func buttons(from raw: Any?) -> [InAppButton] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let buttonId = string(item["buttonId"]),
                  let label = string(item["label"]),
                  let action = string(item["action"]) else {
                return nil
            }
            return InAppButton(
                buttonId: buttonId,
                label: label,
                action: action,
                value: string(item["value"]))
        }
    }

    /// Predicates are compared as strings on both sides. The backend types them
    /// `Record<string, string>` but validates only with `@IsObject()`, so a number or a boolean can
    /// legitimately arrive and must not be dropped.
    private static func properties(from raw: Any?) -> [String: String] {
        guard let object = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in object where !(value is NSNull) {
            if let text = value as? String {
                out[key] = text
            } else {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    /// Non-empty string, treating both `NSNull` and absence as nil.
    private static func string(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Unparseable means open-ended rather than expired: refusing to show a live message is worse
    /// than carrying one whose expiry could not be read.
    static func millis(from iso: String?) -> Int64? {
        guard let iso = iso, !iso.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: iso) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    static func isoTimestamp(_ millis: Int64) -> String {
        isoFormatters[0].string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// With and without milliseconds — both are valid ISO-8601 and both appear in practice.
    /// `en_US_POSIX` is mandatory: any other locale can render or parse a different calendar.
    private static let isoFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"].map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = pattern
            return formatter
        }
    }()
}

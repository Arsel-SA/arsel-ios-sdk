import XCTest
@testable import Arsel

/// The parser's failure mode is silence: a dropped message produces no signal on any surface,
/// server or client. These pin the three-state jsonb reads in particular — absent, explicitly
/// null, or present — because a reader that handled only two of the three would discard perfectly
/// good messages while every dashboard reported the campaign as healthy.
final class InAppParserTests: XCTestCase {
    func testReadsTheEnvelopeTheSuccessInterceptorActuallySends() {
        // The backend spreads `message` and `timestamp` alongside the contract fields; a parser
        // that key-validated the envelope would reject every real response.
        let parsed = InAppParser.catalogue(from: catalogue(message()), nowMs: nowMs)

        XCTAssertEqual(parsed?.version, "v1")
        XCTAssertEqual(parsed?.messages.count, 1)
    }

    func testAcceptsAbsentNullAndPresentForEveryOptionalField() {
        let nulls = message(
            """
            "expiresAt": null, "buttons": null, "variantKey": null,
            "trigger": {"type": "APP_OPEN", "eventName": null, "properties": null}
            """)
        let present = message(
            """
            "expiresAt": "2099-01-01T00:00:00.000Z",
            "buttons": [{"buttonId": "b", "label": "Go", "action": "DISMISS"}]
            """)

        let body = catalogue([message(), nulls, present].joined(separator: ","))
        let parsed = InAppParser.catalogue(from: body, nowMs: nowMs)

        XCTAssertEqual(parsed?.messages.count, 3)
    }

    func testDefaultsANullVariantKeyRatherThanDroppingTheMessage() {
        let parsed = InAppParser.catalogue(from: catalogue(message("\"variantKey\": null")), nowMs: nowMs)

        XCTAssertEqual(parsed?.messages.first?.variantKey, InAppParser.defaultVariant)
    }

    func testTreatsAnAbsentCloseButtonAsShown() {
        let json: [String: Any] = [
            "campaignId": "c", "messageId": "m", "layout": "MODAL",
            "content": ["headline": "H"],
        ]

        // Only an explicit false hides it; absent must never leave a user with no way out.
        XCTAssertEqual(InAppParser.message(from: json)?.showCloseButton, true)
    }

    func testDropsAMessageMissingAFieldItCannotRenderWithout() {
        let json: [String: Any] = [
            "campaignId": "c", "messageId": "m", "layout": "MODAL", "content": [String: Any](),
        ]

        XCTAssertNil(InAppParser.message(from: json))
    }

    func testDropsALayoutThisBuildCannotDraw() {
        let json: [String: Any] = [
            "campaignId": "c", "messageId": "m", "layout": "CAROUSEL",
            "content": ["headline": "H"],
        ]

        XCTAssertNil(InAppParser.message(from: json))
    }

    func testKeepsAMessageWhoseExpiryCannotBeParsed() {
        // Refusing to show a live message is worse than carrying one whose expiry could not be
        // read, so an unparseable date means open-ended rather than expired.
        let parsed = InAppParser.catalogue(from: catalogue(message("\"expiresAt\": \"soon\"")), nowMs: nowMs)

        XCTAssertNotNil(parsed?.messages.first)
        XCTAssertNil(parsed?.messages.first?.expiresAtMs)
    }

    func testParsesAnExpiryWithAndWithoutMilliseconds() {
        let withMillis = catalogue(message("\"expiresAt\": \"2099-01-01T00:00:00.000Z\""))
        let withoutMillis = catalogue(message("\"expiresAt\": \"2099-01-01T00:00:00Z\""))

        let a = InAppParser.catalogue(from: withMillis, nowMs: nowMs)?.messages.first?.expiresAtMs
        let b = InAppParser.catalogue(from: withoutMillis, nowMs: nowMs)?.messages.first?.expiresAtMs

        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testCoercesNonStringTriggerPropertiesToStrings() {
        // The backend validates properties only with @IsObject(), so a number can arrive.
        let json: [String: Any] = [
            "campaignId": "c", "messageId": "m", "layout": "MODAL",
            "content": ["headline": "H"],
            "trigger": ["type": "CUSTOM_EVENT", "eventName": "buy", "properties": ["n": 2]],
        ]

        XCTAssertEqual(InAppParser.message(from: json)?.triggerProperties["n"], "2")
    }

    func testReturnsNilForAnythingThatIsNotAUsableCatalogue() {
        XCTAssertNil(InAppParser.catalogue(from: Data("{\"messages\":[]}".utf8), nowMs: nowMs))
        XCTAssertNil(InAppParser.catalogue(from: Data("not json".utf8), nowMs: nowMs))
        XCTAssertNil(InAppParser.catalogue(from: nil, nowMs: nowMs))
    }

    func testFallsBackToASaneTtlWhenTheServerSendsNone() {
        let body = Data("{\"bundleVersion\":\"v1\",\"messages\":[]}".utf8)

        XCTAssertEqual(InAppParser.catalogue(from: body, nowMs: nowMs)?.ttlSeconds, InAppParser.defaultTtlSeconds)
    }

    func testStampsABeaconTimestampTheBackendAccepts() {
        let stamped = InAppParser.isoTimestamp(nowMs)

        XCTAssertTrue(stamped.hasSuffix("Z"), "expected a UTC instant, got \(stamped)")
        XCTAssertEqual(InAppParser.millis(from: stamped), nowMs)
    }

    func testReadsACustomHtmlMessage() {
        let custom = parseCustom("""
        "source": "INLINE", "html": "<p>hi</p>",
        "allowJavaScript": true, "overlayStyle": "TRANSPARENT"
        """)

        XCTAssertEqual(custom?.source, InAppHtmlSource.inline)
        XCTAssertEqual(custom?.html, "<p>hi</p>")
        XCTAssertEqual(custom?.allowJavaScript, true)
        XCTAssertEqual(custom?.overlayStyle, InAppOverlayStyle.transparent)
    }

    func testLeavesScriptOffUnlessItIsExplicitlyOn() {
        // The capability is withheld by default: a creative authored without script must never
        // acquire it from a missing key, a null, or a non-boolean.
        let absent = parseCustom("\"source\": \"INLINE\", \"html\": \"<p>hi</p>\"")
        let nulled = parseCustom("""
        "source": "INLINE", "html": "<p>hi</p>", "allowJavaScript": null
        """)
        let stringy = parseCustom("""
        "source": "INLINE", "html": "<p>hi</p>", "allowJavaScript": "true"
        """)

        XCTAssertEqual(absent?.allowJavaScript, false)
        XCTAssertEqual(nulled?.allowJavaScript, false)
        XCTAssertEqual(stringy?.allowJavaScript, false)
    }

    func testDropsACustomHtmlMessageWhoseSourceHasNoPayload() {
        // The whole message goes, not just the payload: the author designed markup, and a stray
        // text modal in its place is a worse outcome than the message not appearing.
        XCTAssertNil(parseCustomMessage("\"source\": \"INLINE\", \"url\": \"https://a.test/x\""))
        XCTAssertNil(parseCustomMessage("\"source\": \"URL\", \"html\": \"<p>hi</p>\""))
        XCTAssertNil(parseCustomMessage("\"source\": \"MAGIC\", \"html\": \"<p>hi</p>\""))
    }

    func testCarriesNoCustomHtmlOnAnyOtherLayout() {
        let parsed = InAppParser.catalogue(from: catalogue(message()), nowMs: nowMs)?.messages.first

        XCTAssertNil(parsed?.customHtml)
    }

    // MARK: Helpers

    private func message(_ extra: String = "") -> String {
        let base = """
        "campaignId": "c1", "messageId": "m1", "layout": "MODAL",
        "content": {"headline": "Hi", "body": "There", "showCloseButton": true}
        """
        return "{\(base)\(extra.isEmpty ? "" : ",\(extra)")}"
    }

    private func parseCustom(_ fields: String) -> InAppCustomHtml? {
        parseCustomMessage(fields)?.customHtml
    }

    private func parseCustomMessage(_ fields: String) -> InAppMessage? {
        let json = """
        {"campaignId": "c1", "messageId": "m1", "layout": "CUSTOM_HTML",
         "content": {"headline": "Hi", "showCloseButton": true},
         "customHtml": {\(fields)}}
        """
        return InAppParser.catalogue(from: catalogue(json), nowMs: nowMs)?.messages.first
    }

    private func catalogue(_ messages: String) -> Data {
        Data("""
        {"message": "success", "timestamp": "now", "contractVersion": 1,
         "bundleVersion": "v1", "ttlSeconds": 900, "messages": [\(messages)]}
        """.utf8)
    }

    /// A fixed instant, so nothing here depends on when the suite runs.
    private let nowMs: Int64 = 1_760_000_000_000
}

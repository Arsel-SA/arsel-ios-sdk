import XCTest
@testable import Arsel

/// The four config rules, which are deliberately identical across the web, Android
/// and iOS SDKs so a misconfiguration reads the same on every platform.
///
/// `initialize` declines rather than throwing — an analytics SDK must not take the
/// host down over its own configuration — so the reason has to stay readable, and
/// `diagnostics()` is where it lives.
final class ConfigValidationTests: XCTestCase {
    private func config(key: String = "pub_test", url: String = "https://api.arsel.sa") -> ArselConfig {
        ArselConfig(clientKey: key, baseUrl: url)
    }

    func testAcceptsHttpsAndLoopback() {
        XCTAssertNil(config().validationError())
        XCTAssertNil(config(url: "http://localhost:8076").validationError())
        XCTAssertNil(config(url: "http://127.0.0.1:8076").validationError())
    }

    func testRejectsPlainHttpElsewhere() {
        let error = config(url: "http://api.arsel.sa").validationError()
        XCTAssertTrue(error?.contains("HTTPS") == true, "got \(String(describing: error))")
    }

    /// A prefix match on "http://localhost" exempts this host, which is attacker
    /// controlled and not loopback at all. The check is anchored for that reason.
    func testRejectsLookalikeLoopbackHost() {
        let error = config(url: "http://localhost.evil.com/collect").validationError()
        XCTAssertTrue(error?.contains("HTTPS") == true, "got \(String(describing: error))")
    }

    func testRejectsBlankClientKey() {
        XCTAssertTrue(config(key: "   ").validationError()?.contains("clientKey is required") == true)
    }

    /// The rule that catches a secret API key shipped inside an IPA.
    func testRejectsNonPublishableClientKey() {
        let error = config(key: "sk_live_secret").validationError()
        XCTAssertTrue(error?.contains("never a secret API key") == true, "got \(String(describing: error))")
    }

    func testRefusedInitializeReportsTheReasonInDiagnostics() {
        Arsel.core = nil
        Arsel.configError = nil
        defer { Arsel.configError = nil }

        Arsel.initialize(config: config(url: "http://api.arsel.sa"))

        let diagnostics = Arsel.diagnostics()
        XCTAssertNotNil(diagnostics, "a refused start is exactly when diagnostics is reached for")
        XCTAssertTrue(diagnostics?.configError?.contains("HTTPS") == true)
        XCTAssertNil(Arsel.core, "nothing should have been started")
    }
}

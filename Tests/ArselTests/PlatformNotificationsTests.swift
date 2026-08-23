import XCTest
@testable import Arsel

#if canImport(UserNotifications)
import UserNotifications

/// The `Platform/` layer, which only exists on a real iOS build.
///
/// `swift test` on Linux compiles none of this — `Notifications.swift` sits entirely behind
/// `#if canImport(UserNotifications)`. These run under `make test` on a simulator, which is the
/// only place any of it is executed.
///
/// **Only the pure decisions are testable here.** `UNUserNotificationCenter.current()` traps with
/// `bundleProxyForCurrentProcess is nil` in this bundle: a SwiftPM test target has no host
/// application, so `Bundle.main` is xctest's own agent rather than an app, and the notification
/// centre refuses to vend. That rules out anything that reads settings or delivers a notification,
/// including `refreshPermissionState()` and `handleForegroundNotification(_:)` — the latter also
/// needs a real `UNNotification`, which has no public initialiser and can only be obtained by
/// actually delivering one. Guarding with `XCTSkip` does not help; the trap happens on the
/// `.current()` call itself, before any guard can run.
///
/// Those paths are covered instead by `make push-smoke`, which installs the sample app on a
/// simulator and drives a real notification through `xcrun simctl push` — an app host, which is
/// exactly what they need.
final class PlatformNotificationsTests: XCTestCase {
    private func arselPayload(
        messageId: String = "11111111-2222-4333-8444-555555555555"
    ) -> [AnyHashable: Any] {
        [
            Wire.DataKey.version: "1",
            Wire.DataKey.messageId: messageId,
            Wire.DataKey.signature: "c2lnbmF0dXJl",
            Wire.DataKey.signatureKeyId: "v1",
            Wire.DataKey.title: "Title",
            Wire.DataKey.body: "Body",
        ]
    }

    // MARK: Permission mapping

    /// Every `UNAuthorizationStatus` the OS can report, including the two that are easy to get
    /// wrong: `provisional` is a real subscription, and `ephemeral` (App Clips) is authorised.
    func testEnablementStatusCoversEveryAuthorizationStatus() {
        XCTAssertEqual(Arsel.enablementStatus(from: .authorized), .authorized)
        XCTAssertEqual(Arsel.enablementStatus(from: .denied), .denied)
        XCTAssertEqual(Arsel.enablementStatus(from: .notDetermined), .notDetermined)
        XCTAssertEqual(Arsel.enablementStatus(from: .provisional), .provisional)
        #if !os(macOS)
        XCTAssertEqual(Arsel.enablementStatus(from: .ephemeral), .authorized)
        #endif
    }

    // MARK: Ownership

    /// Hosts multiplex several push sources through one delegate, so claiming a foreign payload
    /// would suppress somebody else's notification.
    func testIsArselNotificationDiscriminatesBySchemaMarker() {
        XCTAssertTrue(Arsel.isArselNotification(userInfo: arselPayload()))
        XCTAssertFalse(Arsel.isArselNotification(userInfo: ["aps": ["alert": "someone else's"]]))
        XCTAssertFalse(Arsel.isArselNotification(userInfo: [:]))
    }
}
#endif

import XCTest

@testable import Arsel

/// Both failure modes are permanent: a duplicate, and the upgrade that bills the installed base.
final class InstallTrackerTests: XCTestCase {
    private var store: StateStore!
    private var captured: [QueuedRequest] = []
    private var events: EventController!
    private let now: Int64 = 1_700_000_000_000

    override func setUp() {
        super.setUp()
        store = StateStore(directory: tempDirectory(), log: quietLog)
        captured = []
        events = EventController(
            store: store, enqueue: { self.captured.append($0) }, log: quietLog,
            clock: { self.now })
    }

    private func makeTracker(appVersion: String? = "4.0.8") -> InstallTracker {
        InstallTracker(
            store: store, events: events, appVersion: { appVersion }, sdkVersion: "1.2.0")
    }

    private func names() -> [String] {
        captured.map {
            (try! JSONSerialization.jsonObject(
                with: $0.body.data(using: .utf8)!) as! [String: Any])["event"] as! String
        }
    }

    private func data(at index: Int) -> [String: Any] {
        let body =
            try! JSONSerialization.jsonObject(
                with: captured[index].body.data(using: .utf8)!) as! [String: Any]
        return body["data"] as! [String: Any]
    }

    func testFirstInstallEmitsAppInstalled() {
        makeTracker().reportIfNew(alreadyInstalled: false)

        XCTAssertEqual(names(), [EventBodies.appInstalled])
    }

    func testAppInstalledCarriesTheAppAndSdkVersions() {
        makeTracker().reportIfNew(alreadyInstalled: false)

        XCTAssertEqual(data(at: 0)["app_version"] as? String, "4.0.8")
        XCTAssertEqual(data(at: 0)["sdk_version"] as? String, "1.2.0")
        XCTAssertEqual(data(at: 0)["platform"] as? String, "ios")
    }

    func testALaterLaunchEmitsNothing() {
        let tracker = makeTracker()
        tracker.reportIfNew(alreadyInstalled: false)
        captured = []

        tracker.reportIfNew(alreadyInstalled: false)

        XCTAssertEqual(names(), [])
    }

    func testADeviceThatPredatesTheSdkIsSeededSilently() {
        makeTracker().reportIfNew(alreadyInstalled: true)

        XCTAssertEqual(names(), [])
        XCTAssertTrue(store.current.installReported)
    }

    func testASeededDeviceStaysSilentOnEveryLaterLaunch() {
        let tracker = makeTracker()

        tracker.reportIfNew(alreadyInstalled: true)
        tracker.reportIfNew(alreadyInstalled: false)

        XCTAssertEqual(names(), [])
    }

    func testAnUnavailableAppVersionStillEmits() {
        makeTracker(appVersion: nil).reportIfNew(alreadyInstalled: false)

        XCTAssertEqual(names(), [EventBodies.appInstalled])
        XCTAssertNil(data(at: 0)["app_version"])
    }
}

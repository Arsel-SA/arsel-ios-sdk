import Foundation

/// Emits `arsel.app_installed` once in the life of an install.
final class InstallTracker {
    private let store: StateStore
    private let events: EventController
    private let appVersion: () -> String?
    private let sdkVersion: String

    init(
        store: StateStore,
        events: EventController,
        appVersion: @escaping () -> String? = { DeviceSnapshot.appVersion },
        sdkVersion: String = Wire.sdkVersion
    ) {
        self.store = store
        self.events = events
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
    }

    /// - Parameter alreadyInstalled: captured by the caller, because `mirrorExtensionContext` mints
    ///   the installation id during `ArselCore.init` whenever an App Group is configured — after
    ///   that a first install and an SDK upgrade look identical.
    func reportIfNew(alreadyInstalled: Bool) {
        guard !store.current.installReported else { return }

        // Before the emit, not after: a crash in between costs one install event, where the other
        // order costs a duplicate on every launch until one lands.
        store.mutate { $0.installReported = true }
        guard !alreadyInstalled else { return }

        var properties: [String: Any] = [
            "sdk_version": sdkVersion,
            "platform": "ios",
        ]
        if let version = appVersion() { properties["app_version"] = version }
        events.trackReserved(EventBodies.appInstalled, properties: properties)
    }
}

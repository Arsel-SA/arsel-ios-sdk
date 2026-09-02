import Foundation

/// Everything the SDK persists apart from the request queue and the device secret.
/// One JSON file, rewritten atomically on every mutation — small, and the write
/// pattern that survives a process kill mid-write.
struct PersistedState: Codable {
    var anonymousId: String?
    var externalId: String?
    var email: String?
    var phoneNumber: String?
    var installationId: String?
    /// The push token the host last passed in, persisted so a relaunch can
    /// re-register without waiting for the host to hand it over again.
    var pushToken: String?
    var pushVendor: String?
    var optedOut: Bool = false
    /// Fingerprint of the last registration a drain confirmed, so an unchanged
    /// device is never re-reported.
    var lastRegisteredFingerprint: String?
    var enablementStatus: String?
    /// Absent in state files written by older SDKs, which decode to `false`.
    var installReported: Bool = false
    var sessionStartedAtMs: Int64 = 0
    var backgroundedAtMs: Int64 = 0
    // Diagnostics only; nothing branches on these.
    var lastResponseCode: Int?
    var lastResponsePath: String?
    var lastResponseAtMs: Int64?
}

final class StateStore {
    private let fileURL: URL
    private var state: PersistedState
    private let log: ArselLog

    init(directory: URL, log: ArselLog) {
        self.fileURL = directory.appendingPathComponent("state.json")
        self.log = log
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedState()
        }
    }

    /// Read the current state. Callers must be on the core's serial queue.
    var current: PersistedState { state }

    func mutate(_ change: (inout PersistedState) -> Void) {
        change(&state)
        persist()
    }

    func anonymousIdOrCreate() -> String {
        if let existing = state.anonymousId { return existing }
        let minted = UUID().uuidString.lowercased()
        mutate { $0.anonymousId = minted }
        return minted
    }

    func installationIdOrCreate() -> String {
        if let existing = state.installationId { return existing }
        let minted = UUID().uuidString.lowercased()
        mutate { $0.installationId = minted }
        return minted
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.e("could not persist SDK state: \(error)")
        }
    }
}

/// Where the device secret lives. A protocol so the Linux tests (no Security
/// framework) and the Keychain-backed production store share the call sites.
protocol SecretStore {
    func read() -> String?
    func write(_ secret: String)
    func removeSecret()
}

#if canImport(Security)
import Security

/// Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by a
/// background drain after reboot-then-unlock, never migrated to a new device —
/// the backend binds the secret to this installation.
final class KeychainSecretStore: SecretStore {
    private let service = "sa.arsel.push"
    private let account = "deviceSecret"
    private let accessGroup: String?

    /// - Parameter accessGroup: a shared keychain access group so a Notification
    ///   Service Extension can read the secret for `delivered` engagements. Both
    ///   targets must carry the matching entitlement.
    init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String) {
        removeSecret()
        var query = baseQuery()
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func removeSecret() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
#endif

/// File-backed fallback for platforms without the Security framework (the Linux
/// test toolchain). Never the store on iOS.
final class FileSecretStore: SecretStore {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("secret")
    }

    func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String) {
        try? Data(secret.utf8).write(to: fileURL, options: .atomic)
    }

    func removeSecret() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

import Foundation
import Combine

/// A bounded, timestamped record of what the harness asked the SDK to do and what visibly
/// changed afterwards.
///
/// The SDK exposes no event callback by design — it must never call back into a host that
/// may be mid-teardown — so "what the SDK did" is observed the same way an integrator
/// observes it in the field: through `Arsel.diagnostics()`. This log is what turns
/// those snapshots into a timeline.
final class SdkEventLog: ObservableObject {
    static let shared = SdkEventLog()

    /// Newest first — the line you want is the one that just happened.
    @Published private(set) var lines: [String] = []

    private let maxLines = 60
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        // Also to stdout, so `simctl launch --console` can assert on the same timeline the
        // on-screen log shows. Without this the harness is only observable by a human looking
        // at the device.
        print("[harness] \(message)")
        if Thread.isMainThread {
            append(line)
        } else {
            DispatchQueue.main.async { self.append(line) }
        }
    }

    func clear() {
        lines = []
    }

    var snapshot: String {
        lines.isEmpty ? "(nothing yet)" : lines.joined(separator: "\n")
    }

    private func append(_ line: String) {
        lines.insert(line, at: 0)
        if lines.count > maxLines {
            lines.removeLast(lines.count - maxLines)
        }
    }
}

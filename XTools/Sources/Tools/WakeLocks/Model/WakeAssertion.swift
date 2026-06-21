import Foundation
import Darwin

/// What a power assertion blocks.
enum WakeAssertionKind {
    case displaySleep   // keeps the DISPLAY on (screen won't turn off)
    case systemSleep    // keeps the Mac awake (display may still sleep)
}

/// One power assertion held by a process (the programmatic equivalent of a line
/// in `pmset -g assertions`).
struct WakeAssertion: Identifiable, Hashable {
    let id: String
    let kind: WakeAssertionKind
    let typeRaw: String     // e.g. "PreventUserIdleDisplaySleep"
    let name: String        // human reason, e.g. "Video Wake Lock"
    let createdAt: Date?
}

/// A process together with all of its sleep-preventing assertions.
struct AssertionHolder: Identifiable {
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let isApp: Bool          // has an NSRunningApplication → can be quit gracefully
    let uid: uid_t?          // nil if the owner couldn't be determined
    let startTime: UInt64?   // per-instance fingerprint, to detect pid reuse
    let assertions: [WakeAssertion]

    var id: pid_t { pid }

    var runsAsRoot: Bool { uid == 0 }

    /// We only offer to end processes owned by the CURRENT user. Root, other
    /// users, and uid-unknown processes are not end-eligible (avoids killing
    /// system processes or guessing ownership).
    var canEnd: Bool { uid != nil && uid == getuid() }

    var preventsDisplaySleep: Bool { assertions.contains { $0.kind == .displaySleep } }
    var preventsSystemSleep: Bool { assertions.contains { $0.kind == .systemSleep } }

    /// Earliest assertion start — how long this process has been holding.
    var since: Date? { assertions.compactMap { $0.createdAt }.min() }

    /// Distinct human reasons, e.g. ["Video Wake Lock"].
    var reasons: [String] {
        var seen = Set<String>()
        return assertions.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }
}

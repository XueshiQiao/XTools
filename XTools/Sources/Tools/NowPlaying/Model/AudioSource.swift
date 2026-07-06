import Foundation
import Darwin

/// One process that currently holds an active audio-OUTPUT lock — i.e. it is
/// playing sound right now (music, a video, a call). Derived from the
/// `com.apple.audio.<device>.context.preventuseridlesleep` assertions that
/// `coreaudiod` holds *on behalf of* each playing client (the "Created for PID"
/// in `pmset -g assertions`).
struct AudioSource: Identifiable {
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let bundlePath: String?     // enclosing .app bundle (for the real app icon/name), if any
    let isApp: Bool             // has an NSRunningApplication → can be quit gracefully
    let uid: uid_t?             // nil if the owner couldn't be determined
    let startTime: UInt64?      // per-instance fingerprint, to detect pid reuse
    let devices: [String]       // friendly output-device name(s), e.g. ["Built-in Speakers"]
    let heldFor: TimeInterval?  // how long it's been playing (from the assertion age)

    var id: pid_t { pid }

    var runsAsRoot: Bool { uid == 0 }

    /// We only offer to quit processes owned by the CURRENT user (never root /
    /// other users / uid-unknown) — same rule as the Wake Locks tool.
    var canEnd: Bool { uid != nil && uid == getuid() }
}

import Foundation
import Darwin

/// Runtime self-calibration of the top pipeline (HR4.2).
///
/// The parser was verified on THIS machine's macOS; older systems' `top` output
/// is explicitly unverified. Rather than trusting it blind, the first usable
/// block of every child is checked against two numbers the app can compute
/// without top:
///
/// 1. top's MEM for OUR OWN pid vs the in-process `phys_footprint` — a process
///    can always read its own rusage, and the two must agree if the MEM column
///    is being parsed correctly AND actually means footprint.
/// 2. top's row count vs the in-process roster count — a gross mismatch means
///    rows are being dropped or the block structure has drifted.
///
/// Tolerances are exact per spec (no interpretation room): memory within
/// max(20%, 5MB) AND count within 10% → pass. Anything else → the caller
/// switches to ps mode, logging both numbers and the delta.
enum SelfCalibration {

    struct Outcome {
        let passed: Bool
        /// Both numbers and the delta, for the log — pass or fail.
        let summary: String
    }

    static func check(sample: TopSample, rosterCount: Int) -> Outcome {
        var problems: [String] = []
        var parts: [String] = []

        // 1. Memory: top's view of us vs our own view of us.
        let ownPid = getpid()
        switch (sample.rows[ownPid]?.memoryBytes, ownFootprint()) {
        case let (.some(top), .some(own)):
            let delta = top > own ? top - own : own - top
            let tolerance = max(UInt64(Double(own) * 0.20), 5 << 20)   // max(20%, 5MB)
            parts.append("top=\(mb(top)) own footprint=\(mb(own)) delta=\(mb(delta)) tolerance=\(mb(tolerance))")
            if delta > tolerance { problems.append("memory delta over tolerance") }
        case (.none, _):
            // top reports every process; not seeing ourselves means the sample
            // cannot be trusted at all.
            parts.append("own pid \(ownPid) missing from top sample")
            problems.append("own pid missing from top sample")
        case (_, .none):
            // Can't read our own rusage (should never happen — self is always
            // readable). That is OUR failure, not evidence against top; the count
            // check below still stands alone.
            parts.append("own footprint unreadable — memory check skipped")
        }

        // 2. Row count vs roster count.
        let topCount = sample.rows.count
        let allowed = Int(Double(rosterCount) * 0.10)
        let diff = abs(topCount - rosterCount)
        parts.append("rows: top=\(topCount) roster=\(rosterCount) diff=\(diff) allowed=\(allowed)")
        if diff > allowed { problems.append("row count diverges from roster") }

        let summary = parts.joined(separator: " · ")
            + (problems.isEmpty ? "" : " → " + problems.joined(separator: "; "))
        return Outcome(passed: problems.isEmpty, summary: summary)
    }

    /// Our own `phys_footprint` — the same number Activity Monitor's "Memory"
    /// column shows for this app. `RUSAGE_INFO_V4` deliberately, NOT v6:
    /// `ri_phys_footprint` has been in V4 since ~10.12, which sidesteps the
    /// unverified question of whether v6 exists on macOS 13.
    static func ownFootprint() -> UInt64? {
        var info = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard ret == 0 else { return nil }
        return info.ri_phys_footprint
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}

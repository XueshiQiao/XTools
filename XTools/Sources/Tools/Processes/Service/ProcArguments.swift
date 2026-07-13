import Foundation
import Darwin

/// A process's command-line arguments.
///
/// Two sources, because one is not enough:
///
/// * `sysctl(KERN_PROCARGS2)` — in-process, free, but **only for processes we
///   own**. For a root-owned pid it fails with **EINVAL (22)**, not EPERM
///   (measured on pid 1 and pid 338) — so an errno check that only looks for
///   EPERM will silently conclude "no arguments" instead of falling back.
/// * `/bin/ps -o args=` — setuid root, so it reads root processes' argv too.
///
/// argv matters more than anything else here: `/usr/libexec/UserEventAgent
/// (System)` and `/usr/libexec/UserEventAgent (Aqua)` are the same binary doing
/// two different jobs, and without the argument a model can only guess.
///
/// It is also where secrets live (`--api-key=…`, `--password …`, a DSN with
/// credentials). NOTHING here redacts — this returns the raw truth, and
/// `ArgvRedactor` + the user's own confirmation stand between it and the network.
enum ProcArguments {

    private static let log = FileLog("Processes")

    struct Argv {
        let values: [String]
        /// False when the vector was reconstructed by splitting `ps` output on
        /// spaces — an argument that itself contained a space cannot be recovered.
        /// The payload passes this through so the model is never told a rebuilt
        /// command line is verbatim.
        let isExact: Bool

        /// Arguments BEYOND argv[0]. Drives the privacy gate: a process with
        /// nothing but its own path has nothing worth confirming, and must not
        /// cost the user a click.
        var hasMeaningfulArguments: Bool { values.count > 1 }
    }

    /// argv for a pid, or nil if it genuinely has none / cannot be read.
    /// One pass — never probe the same pid twice just to learn where it came from.
    static func arguments(pid: pid_t) -> Argv? {
        if let own = viaSysctl(pid: pid) { return Argv(values: own, isExact: true) }
        if let ps = viaPS(pid: pid)      { return Argv(values: ps, isExact: false) }
        return nil
    }

    // MARK: - Same-uid: KERN_PROCARGS2

    private static func viaSysctl(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buf = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Layout: [int32 argc][exec path \0][\0 padding][argv[0] \0]…[argv[n] \0][env…]
        let intSize = MemoryLayout<Int32>.size
        guard size > intSize else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buf.withUnsafeBytes { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[0..<intSize]))
            }
        }
        guard argc > 0 else { return nil }

        var i = intSize
        // Skip the exec path, then the run of NUL padding that follows it.
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }

        var args: [String] = []
        var current: [CChar] = []
        while i < size && args.count < Int(argc) {
            if buf[i] == 0 {
                current.append(0)
                args.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buf[i])
            }
            i += 1
        }
        return args.isEmpty ? nil : args
    }

    // MARK: - Root / other uid: setuid ps

    private static func viaPS(pid: pid_t) -> [String]? {
        guard let out = PSSampler.run("/bin/ps", ["-o", "args=", "-p", String(pid)]) else { return nil }
        let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // `ps` gives one flat string; it cannot round-trip an argument that itself
        // contains a space. Split on whitespace and say so — this is a lossy view of
        // the truth, and the payload marks it as such so the model isn't told a
        // reconstructed command line is verbatim.
        return line.split(separator: " ").map(String.init)
    }
}

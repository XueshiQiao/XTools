import Foundation
import AppKit
import Darwin

/// Finds the processes that are CURRENTLY playing audio to an output device by
/// parsing the audio-output power assertions that `coreaudiod` holds on behalf
/// of each playing client.
///
/// Why parse `pmset -g assertions` text (and not the IOKit assertion API): the
/// audio assertions are OWNED by `coreaudiod`, and only pmset's text output
/// carries the "Created for PID:" (the real playing app) and the
/// "Resources: audio-out <device>" line we key on. `IOPMCopyAssertionsByProcess`
/// groups by the owner (coreaudiod) and doesn't expose the on-behalf-of client,
/// so it can't tell us WHICH app is playing. The clean Core Audio process API
/// (`kAudioProcessPropertyIsRunningOutput`) is macOS 14.4+, but XTools targets
/// 13.0+, so the assertion parse is the one uniform path.
///
/// Keys strictly on `audio-out`, so recording/microphone use (`audio-in`) is
/// excluded. Detects sustained output (music, video, calls); very short system
/// sounds may not raise an assertion, and an app that opened an output stream
/// but is momentarily silent can occasionally still appear.
enum NowPlayingScanner {

    private static let log = FileLog("NowPlayingScanner")
    private static let pmsetPath = "/usr/bin/pmset"

    static func scan() -> [AudioSource] {
        guard let out = run(["-g", "assertions"]) else { return [] }
        let blocks = audioBlocks(in: out)

        // Group by the real (on-behalf-of) pid — one app can play to several
        // devices at once (→ several blocks, same pid). Merge devices; keep the
        // longest age.
        let me = getpid()
        var order: [pid_t] = []
        var byPid: [pid_t: (devices: [String], heldFor: TimeInterval?)] = [:]
        for b in blocks {
            guard b.pid > 0, b.pid != me else { continue }
            if byPid[b.pid] == nil { order.append(b.pid) }
            var entry = byPid[b.pid] ?? ([], nil)
            if let d = b.device, !entry.devices.contains(d) { entry.devices.append(d) }
            if let h = b.heldFor { entry.heldFor = max(entry.heldFor ?? 0, h) }
            byPid[b.pid] = entry
        }

        var sources: [AudioSource] = []
        for pid in order {
            guard let entry = byPid[pid] else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let path = ProcessScanner.currentExecutablePath(pid: pid)
            let bundlePath = path.flatMap(appBundlePath(forExecutable:))
            // The audio "client" is often a helper process deep inside a bundle
            // (e.g. "Google Chrome Helper", a Setapp web-content process) that
            // has no NSRunningApplication. Resolve the OWNING app for a friendly
            // name + a real icon — the user cares which app is playing, not which
            // helper. Fall back to the executable's own name for true CLI tools.
            let name = app?.localizedName
                ?? bundlePath.map(appDisplayName(bundlePath:))
                ?? path.map { ($0 as NSString).lastPathComponent }
                ?? "pid \(pid)"
            // coreaudiod attributes on behalf of the client; if attribution ever
            // resolves back to coreaudiod itself, it isn't a "player" — skip it.
            if name.caseInsensitiveCompare("coreaudiod") == .orderedSame { continue }
            sources.append(AudioSource(
                pid: pid, processName: name, executablePath: path,
                bundlePath: bundlePath,
                isApp: app != nil, uid: uid(of: pid),
                startTime: ProcessScanner.processStartTime(pid: pid),
                devices: entry.devices,
                heldFor: entry.heldFor))
        }
        // Longest-playing first.
        return sources.sorted { ($0.heldFor ?? 0) > ($1.heldFor ?? 0) }
    }

    // MARK: - Parsing

    private struct AudioBlock {
        var pid: pid_t
        var device: String?
        var heldFor: TimeInterval?
    }

    /// One assertion "header" line, e.g.:
    ///   pid 423(coreaudiod): [0x…] 00:03:36 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"
    /// followed by indented continuation lines:
    ///   \tCreated for PID: 70239.
    ///   \tResources: audio-out BuiltInSpeakerDevice
    /// Groups: 1=pid 2=procname (3,4,5)=hh:mm:ss (optional) 6=type 7=name.
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"pid (\d+)\(([^)]*)\):\s*(?:\[[^\]]*\]\s*)?(?:(\d{2}):(\d{2}):(\d{2})\s+)?(\S+)\s+named:\s*"([^"]*)""#)

    private static func audioBlocks(in text: String) -> [AudioBlock] {
        var blocks: [AudioBlock] = []

        // Parse-in-progress block state.
        var ownerHeld: TimeInterval?
        var nameDevice: String?      // device parsed from the assertion name
        var createdForPid: pid_t?
        var resourceDevice: String?
        var isAudioOut = false
        var open = false

        func flush() {
            defer { open = false }
            // Trust only coreaudiod's on-behalf attribution: require "Created for PID".
            guard open, isAudioOut, let pid = createdForPid else { return }
            blocks.append(AudioBlock(pid: pid,
                                     device: friendlyDevice(resourceDevice ?? nameDevice),
                                     heldFor: ownerHeld))
        }

        // Only parse the "Listed by owning process:" section (before "Kernel Assertions:").
        var inSection = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.contains("Listed by owning process:") { inSection = true; continue }
            if rawLine.contains("Kernel Assertions:") { break }
            guard inSection else { continue }

            let ns = rawLine as NSString
            if let m = headerRegex.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length)) {
                flush()   // finalize the previous assertion before starting a new one
                ownerHeld = duration(m, ns)
                let name = m.range(at: 7).location != NSNotFound ? ns.substring(with: m.range(at: 7)) : ""
                nameDevice = deviceFromName(name)
                createdForPid = nil
                resourceDevice = nil
                // Audio-output assertions from coreaudiod look like
                // "com.apple.audio.<device>.context.preventuseridlesleep";
                // the "audio-out" resource line (below) is the strong confirmation.
                isAudioOut = name.hasPrefix("com.apple.audio.") && name.contains("preventuseridle")
                open = true
            } else if open {
                if rawLine.contains("Created for PID:"),
                   let r = rawLine.range(of: "Created for PID:") {
                    createdForPid = firstInt(in: String(rawLine[r.upperBound...]))
                }
                if let r = rawLine.range(of: "audio-out") {
                    isAudioOut = true
                    let tail = rawLine[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let tok = tail.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
                       !tok.isEmpty {
                        resourceDevice = tok
                    }
                }
            }
        }
        flush()
        return blocks
    }

    /// Elapsed time from the header's hh:mm:ss groups, or nil if absent.
    private static func duration(_ m: NSTextCheckingResult, _ ns: NSString) -> TimeInterval? {
        guard m.range(at: 3).location != NSNotFound else { return nil }
        let hh = Double(ns.substring(with: m.range(at: 3))) ?? 0
        let mm = Double(ns.substring(with: m.range(at: 4))) ?? 0
        let ss = Double(ns.substring(with: m.range(at: 5))) ?? 0
        return hh * 3600 + mm * 60 + ss
    }

    /// "com.apple.audio.BuiltInSpeakerDevice.context.…" → "BuiltInSpeakerDevice".
    private static func deviceFromName(_ name: String) -> String? {
        let prefix = "com.apple.audio."
        guard name.hasPrefix(prefix) else { return nil }
        return name.dropFirst(prefix.count).split(separator: ".").first.map(String.init)
    }

    /// Friendly output-device label. Maps the built-ins; strips a trailing
    /// "Device"; omits cryptic UID-ish tokens (rather than show gibberish).
    private static func friendlyDevice(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "BuiltInSpeakerDevice":   return L("nowplaying.device.builtinSpeaker")
        case "BuiltInHeadphoneDevice": return L("nowplaying.device.headphones")
        default: break
        }
        if raw.contains(":") || raw.count > 28 { return nil }
        var s = raw
        if s.hasSuffix("Device") { s = String(s.dropLast("Device".count)) }
        return s.isEmpty ? nil : s
    }

    /// The OUTERMOST enclosing `.app` bundle for an executable path, so a helper
    /// buried inside (…/Google Chrome.app/…/Google Chrome Helper.app/…/MacOS/…)
    /// resolves to its owning app (`/Applications/Google Chrome.app`). Nil for
    /// non-bundled binaries (e.g. `/usr/bin/afplay`).
    private static func appBundlePath(forExecutable path: String) -> String? {
        let comps = path.components(separatedBy: "/")
        guard let idx = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let joined = comps[0...idx].joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }

    /// A friendly app name from a bundle path: "…/Google Chrome.app" → "Google Chrome".
    private static func appDisplayName(bundlePath: String) -> String {
        var last = (bundlePath as NSString).lastPathComponent
        if last.hasSuffix(".app") { last = String(last.dropLast(4)) }
        return last.isEmpty ? bundlePath : last
    }

    /// First run of digits in `s`, as a pid.
    private static func firstInt(in s: String) -> pid_t? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return digits.isEmpty ? nil : pid_t(digits)
    }

    /// Owning uid, or nil if the lookup fails (so callers don't assume ownership).
    private static func uid(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        return info.pbi_uid
    }

    // MARK: - Process

    private static func run(_ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pmsetPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // swallow stderr
        do {
            try proc.run()
        } catch {
            log.error("failed to run pmset \(args): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

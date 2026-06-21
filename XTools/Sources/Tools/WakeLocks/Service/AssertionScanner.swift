import Foundation
import IOKit.pwr_mgt
import AppKit
import Darwin

/// Enumerates the power assertions currently preventing display/system sleep,
/// grouped by the process holding them — the programmatic equivalent of
/// `pmset -g assertions`. Uses `IOPMCopyAssertionsByProcess` (no privilege needed).
enum AssertionScanner {

    private static let log = FileLog("AssertionScanner")

    static func scan() -> [AssertionHolder] {
        var unmanaged: Unmanaged<CFDictionary>?
        let ret = IOPMCopyAssertionsByProcess(&unmanaged)
        guard ret == kIOReturnSuccess, let cf = unmanaged?.takeRetainedValue() else {
            log.warn("IOPMCopyAssertionsByProcess failed: \(ret)")
            return []
        }
        guard let byPid = cf as? [NSNumber: [[String: Any]]] else { return [] }

        let me = getpid()
        var holders: [AssertionHolder] = []

        for (pidNum, list) in byPid {
            let pid = pid_t(pidNum.int32Value)
            if pid == me { continue }   // never list ourselves

            var assertions: [WakeAssertion] = []
            var dictProcName: String?
            for a in list {
                let typeRaw = (a[kIOPMAssertionTypeKey as String] as? String) ?? ""
                guard let kind = kind(forType: typeRaw) else { continue }
                let name = (a[kIOPMAssertionNameKey as String] as? String) ?? typeRaw
                // Actual dict keys (per IOPMCopyAssertionsByProcess): the start time
                // is "AssertStartWhen" and the id is "AssertionId".
                let created = a["AssertStartWhen"] as? Date
                let aid = (a["AssertionId"] as? Int).map(String.init) ?? "\(assertions.count)"
                if dictProcName == nil { dictProcName = a["Process Name"] as? String }
                assertions.append(WakeAssertion(id: "\(pid)-\(aid)", kind: kind,
                                                typeRaw: typeRaw, name: name, createdAt: created))
            }
            guard !assertions.isEmpty else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            let path = ProcessScanner.currentExecutablePath(pid: pid)
            let name = app?.localizedName
                ?? dictProcName
                ?? path.map { ($0 as NSString).lastPathComponent }
                ?? "pid \(pid)"

            holders.append(AssertionHolder(
                pid: pid, processName: name, executablePath: path,
                isApp: app != nil, uid: uid(of: pid),
                startTime: ProcessScanner.processStartTime(pid: pid),
                assertions: assertions))
        }

        // Display-sleep blockers first (what the user usually cares about),
        // then longest-held first.
        return holders.sorted {
            if $0.preventsDisplaySleep != $1.preventsDisplaySleep { return $0.preventsDisplaySleep }
            return ($0.since ?? Date.distantFuture) < ($1.since ?? Date.distantFuture)
        }
    }

    /// Map an assertion type string to the category it blocks. Returns nil for
    /// assertion types that don't prevent sleep (so they're ignored). Matched on
    /// the documented literal type strings (stable, what pmset reports).
    private static func kind(forType type: String) -> WakeAssertionKind? {
        switch type {
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion":
            return .displaySleep
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion":
            return .systemSleep
        default:
            return nil
        }
    }

    /// Owning uid, or nil if the lookup fails (so callers don't assume ownership).
    private static func uid(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        return info.pbi_uid
    }
}

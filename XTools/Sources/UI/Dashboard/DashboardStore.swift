import SwiftUI
import AppKit
import Combine

/// Aggregated, glanceable summaries for the Dashboard overview — one cheap-ish
/// snapshot built by reusing each tool's existing reader (no duplicated logic).
/// Scanned off the main thread, published on main.
struct DashboardData {
    var memory = MemorySnapshot()
    var battery = BatteryInfo()
    var wakeDisplayCount = 0          // processes blocking *display* sleep
    var wakeDisplayList: [WakeGlance] = []   // top few blockers (icon + name + age), for glance
    var audioSources: [AudioSource] = []   // apps currently playing audio (output)
    var portsListening = 0
    var portsConnections = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0

    /// Used physical RAM ≈ total − (total × free%). Mirrors the "X% free" framing.
    var memoryUsed: UInt64 {
        guard let pct = memory.freePercent, memory.totalRAM > 0 else { return 0 }
        let avail = Double(memory.totalRAM) * Double(pct) / 100
        return UInt64(max(0, Double(memory.totalRAM) - avail))
    }
}

/// A single display-sleep blocker, distilled for the Dashboard's Wake card so it
/// can mirror the Now Playing card (icon + name + how long it's been held). Icon
/// resolution is deferred to render time (main thread), exactly like `AudioSource`.
struct WakeGlance: Identifiable {
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let heldFor: TimeInterval?   // captured at scan time (like AudioSource.heldFor)

    var id: pid_t { pid }

    /// Running app's icon, else the executable's icon, else the wake glyph.
    var appIcon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let ic = app.icon { return ic }
        if let p = executablePath { return NSWorkspace.shared.icon(forFile: p) }
        return NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) ?? NSImage()
    }
}

final class DashboardStore: ObservableObject {
    @Published private(set) var data = DashboardData()
    @Published private(set) var isLoading = false

    private let work = DispatchQueue(label: "me.xueshi.xtools.dashboard.scan", qos: .userInitiated)
    private var scanning = false      // coalesce overlapping refreshes

    func refresh() {
        // XTools is a menu-bar app: closing the window only hides it, so this
        // view and its 8s timer stay alive. Skip the (lsof-spawning) scan whenever
        // no window is visible, so we don't drain CPU/battery in the background.
        guard NSApp.windows.contains(where: { $0.isVisible }) else { return }
        guard !scanning else { return }
        scanning = true
        isLoading = true
        work.async { [weak self] in
            var d = DashboardData()
            d.memory = MemoryReader.read()
            d.battery = BatteryReader.read()
            let wakeHolders = AssertionScanner.scan().filter { $0.preventsDisplaySleep }
            d.wakeDisplayCount = wakeHolders.count
            let now = Date()
            d.wakeDisplayList = wakeHolders.prefix(3).map { h in
                WakeGlance(pid: h.pid, processName: h.processName, executablePath: h.executablePath,
                           heldFor: h.since.map { now.timeIntervalSince($0) })
            }
            d.audioSources = NowPlayingScanner.scan()
            let conns = PortScanner.scan()
            d.portsListening = conns.filter { $0.isListening }.count
            d.portsConnections = conns.count - d.portsListening
            let cap = Self.diskCapacity()
            d.diskFree = cap.free
            d.diskTotal = cap.total
            DispatchQueue.main.async {
                self?.data = d
                self?.isLoading = false
                self?.scanning = false
            }
        }
    }

    /// Free / total bytes of the boot volume (read-only, no privilege).
    private static func diskCapacity() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: "/")
        let vals = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        let free = vals?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(vals?.volumeTotalCapacity ?? 0)
        return (free, total)
    }
}

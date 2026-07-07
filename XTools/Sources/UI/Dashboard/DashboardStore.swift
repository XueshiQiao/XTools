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
            d.wakeDisplayCount = AssertionScanner.scan().filter { $0.preventsDisplaySleep }.count
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

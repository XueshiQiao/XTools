import SwiftUI
import AppKit

/// UI model for the Device Tree tool. Scans off the main thread and republishes
/// on main; a scan touches several frameworks and forks `system_profiler`, so it
/// must never run where it can stall the interface.
final class DeviceTreeStore: ObservableObject {

    private static let log = FileLog("DeviceTree")

    @Published private(set) var roots: [DeviceNode] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var hostSummary = ""
    @Published var autoRefresh: Bool {
        didSet {
            UserDefaults.standard.set(autoRefresh, forKey: Self.autoRefreshKey)
            autoRefresh ? watcher.start() : watcher.stop()
        }
    }
    /// Set briefly after a copy so the button can confirm it did something.
    @Published private(set) var didCopy = false

    private static let autoRefreshKey = "deviceTree.autoRefresh"
    private let watcher = DeviceWatcher()
    private let queue = DispatchQueue(label: "me.xueshi.xtools.devicetree", qos: .userInitiated)
    private var scanGeneration = 0

    init() {
        autoRefresh = UserDefaults.standard.object(forKey: Self.autoRefreshKey) as? Bool ?? true
    }

    func start() {
        watcher.onChange = { [weak self] in
            Self.log.info("hardware changed — rescanning")
            self?.scan()
        }
        if autoRefresh { watcher.start() }
        scan()
    }

    func stop() { watcher.stop() }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanGeneration += 1
        let generation = scanGeneration
        queue.async { [weak self] in
            let started = Date()
            let roots = DeviceTreeBuilder.build()
            let host = DeviceTreeBuilder.hostSummary()
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                self.roots = roots
                self.hostSummary = host
                self.lastScan = Date()
                self.isScanning = false
                Self.log.debug("scan finished in \(Int(elapsed * 1000))ms, \(roots.reduce(0) { $0 + $1.descendantCount }) node(s)")
            }
        }
    }

    /// The whole tree as plain text, ready to paste into a message or an issue.
    func copyAsText() {
        let text = DeviceTreeTextRenderer.render(roots, title: hostSummary)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.didCopy = false }
    }
}

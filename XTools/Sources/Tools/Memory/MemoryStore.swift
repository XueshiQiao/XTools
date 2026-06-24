import SwiftUI
import Combine

/// UI model for the Memory tool: reads the memory-pressure signal and core
/// memory metrics (memory_pressure + sysctl, both read-only) off the main
/// thread, and publishes the snapshot on main.
final class MemoryStore: ObservableObject {

    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?

    private let work = DispatchQueue(label: "me.xueshi.xtools.memory", qos: .userInitiated)

    func refresh() {
        // Coalesce overlapping refreshes (the 5s timer + manual taps) so a slow
        // memory_pressure run can't pile up successive scans on the serial queue.
        guard !isScanning else { return }
        isScanning = true
        work.async { [weak self] in
            let snapshot = MemoryReader.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.lastUpdated = Date()
                self.isScanning = false
            }
        }
    }
}

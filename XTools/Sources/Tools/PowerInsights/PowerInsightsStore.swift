import SwiftUI
import Combine

/// UI model for the Power & Battery Insights tool: gathers battery health,
/// the active pmset settings, and recent wake/sleep events — all read-only —
/// off the main thread, and publishes the snapshot on main.
final class PowerInsightsStore: ObservableObject {

    @Published private(set) var battery = BatteryInfo()
    @Published private(set) var settings: [PmsetSetting] = []
    @Published private(set) var wakeEvents: [WakeEvent] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?

    private let work = DispatchQueue(label: "me.xueshi.xtools.powerinsights", qos: .userInitiated)

    func refresh() {
        isScanning = true
        work.async { [weak self] in
            let battery = BatteryReader.read()
            let settings = PmsetReader.readSettings()
            let events = PmsetReader.readWakeEvents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.battery = battery
                self.settings = settings
                self.wakeEvents = events
                self.lastUpdated = Date()
                self.isScanning = false
            }
        }
    }
}

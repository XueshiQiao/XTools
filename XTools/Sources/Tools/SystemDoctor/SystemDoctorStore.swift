import SwiftUI
import AppKit

/// Interval options for background read-only health checks.
enum SystemDoctorInterval: Int, CaseIterable, Identifiable {
    case manual = 0
    case min15 = 900
    case min30 = 1800
    case hour1 = 3600

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .manual: return L("sysdoc.interval.manual")
        case .min15:  return L("sysdoc.interval.15m")
        case .min30:  return L("sysdoc.interval.30m")
        case .hour1:  return L("sysdoc.interval.1h")
        }
    }
}

final class SystemDoctorStore: ObservableObject {

    private static let intervalKey = "systemDoctor.intervalSeconds"
    private static let historyKey = "systemDoctor.history"
    private static let maxHistoryCount = 20

    @Published private(set) var snapshot = SystemDoctorSnapshot()
    @Published private(set) var isScanning = false
    @Published private(set) var history: [SystemDoctorHistoryEntry] = []
    @Published var copiedToast: String?

    @Published var interval: SystemDoctorInterval {
        didSet {
            UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey)
            reschedulePeriodicTimer()
        }
    }

    private let workQueue = DispatchQueue(label: "me.xueshi.xtools.systemdoctor", qos: .utility)
    private var periodicTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let savedRaw = UserDefaults.standard.integer(forKey: Self.intervalKey)
        if UserDefaults.standard.object(forKey: Self.intervalKey) == nil {
            self.interval = .min30
        } else {
            self.interval = SystemDoctorInterval(rawValue: savedRaw) ?? .min30
        }
        loadHistory()
    }

    deinit {
        stopBackgroundSchedule()
    }

    // MARK: - App-lifetime periodic read-only schedule

    func startBackgroundSchedule() {
        reschedulePeriodicTimer()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // Run a read-only check 15s after wake if periodic check is enabled
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    guard let self, self.interval != .manual else { return }
                    self.refresh(recordHistory: true)
                }
            }
        }
    }

    func stopBackgroundSchedule() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    private func reschedulePeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard interval != .manual else { return }
        let seconds = TimeInterval(interval.rawValue)
        periodicTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh(recordHistory: true)
        }
    }

    // MARK: - Read-only Scan

    func refresh(recordHistory: Bool = true) {
        guard !isScanning else { return }
        isScanning = true
        let displays = SystemDoctorScanner.currentDisplays()

        workQueue.async { [weak self] in
            let snap = SystemDoctorScanner.scan(displays: displays)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snap
                self.isScanning = false
                if recordHistory && snap.isValid {
                    self.appendHistory(from: snap)
                }
            }
        }
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    // MARK: - Read-only user helpers (Copy / Reveal in Finder)

    func copyText(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedToast = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.copiedToast == label {
                self?.copiedToast = nil
            }
        }
    }

    func revealInFinder(path: String?) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Persistence

    private func appendHistory(from snap: SystemDoctorSnapshot) {
        let nonWS = snap.topPortHolders.first { $0.name != "WindowServer" }
        let entry = SystemDoctorHistoryEntry(
            id: UUID(),
            timestamp: snap.timestamp,
            windowServerCPU: snap.compositor.cpuPercent,
            windowServerPorts: snap.compositor.machPorts,
            topPortProcessName: nonWS?.name ?? "-",
            topPortCount: nonWS?.ports ?? 0,
            anomalyCount: snap.totalAnomalyCount
        )
        history.insert(entry, at: 0)
        if history.count > Self.maxHistoryCount {
            history.removeLast(history.count - Self.maxHistoryCount)
        }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let decoded = try? JSONDecoder().decode([SystemDoctorHistoryEntry].self, from: data) else {
            return
        }
        self.history = decoded
    }
}

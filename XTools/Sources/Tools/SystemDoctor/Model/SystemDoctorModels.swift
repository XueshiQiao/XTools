import SwiftUI
import AppKit

/// Severity level for a read-only diagnostic check item or metric.
enum DiagnosticSeverity: Int, Comparable, Codable {
    case healthy = 0
    case notice = 1
    case warning = 2
    case critical = 3

    static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .healthy:  return .green
        case .notice:   return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .healthy:  return "checkmark.circle.fill"
        case .notice:   return "info.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .healthy:  return L("sysdoc.severity.healthy")
        case .notice:   return L("sysdoc.severity.notice")
        case .warning:  return L("sysdoc.severity.warning")
        case .critical: return L("sysdoc.severity.critical")
        }
    }
}

/// Summary of connected displays (resolution + refresh rate).
struct DisplaySummary: Identifiable, Equatable {
    let id: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Int
    let pointHeight: Int
    let maxRefreshHz: Int
}

/// Real-time instantaneous metrics for WindowServer and menu bar replicant helpers.
struct CompositorMetrics: Equatable {
    var pid: pid_t = 0
    var cpuPercent: Double = 0
    var machPorts: Int = 0
    var memoryBytes: UInt64 = 0
    var loginwindowCPU: Double = 0
    var menuBarAgentCPU: Double = 0
    var systemIdlePercent: Double = 0
    var displays: [DisplaySummary] = []

    var cpuSeverity: DiagnosticSeverity {
        if cpuPercent >= 65 { return .critical }
        if cpuPercent >= 45 { return .warning }
        return .healthy
    }

    var portSeverity: DiagnosticSeverity {
        if machPorts >= 55_000 { return .critical }
        if machPorts >= 35_000 { return .warning }
        return .healthy
    }

    var overallSeverity: DiagnosticSeverity {
        max(cpuSeverity, portSeverity)
    }
}

/// Category of a process holding a large number of Mach ports.
enum PortHolderRole: String {
    case compositor = "compositor"
    case systemUIDaemon = "systemUIDaemon"
    case userApp = "userApp"
    case systemDaemon = "systemDaemon"

    var badgeText: String {
        switch self {
        case .compositor:     return L("sysdoc.role.compositor")
        case .systemUIDaemon: return L("sysdoc.role.systemUIDaemon")
        case .userApp:        return L("sysdoc.role.userApp")
        case .systemDaemon:   return L("sysdoc.role.systemDaemon")
        }
    }
}

/// A process entry in the Mach port inspection table.
struct PortHolderItem: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let executablePath: String?
    let ports: Int
    let cpuPercent: Double
    let memoryBytes: UInt64
    let role: PortHolderRole
    let severity: DiagnosticSeverity
    let diagnosis: String

    var id: pid_t { pid }

    var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let ic = app.icon { return ic }
        if let path = executablePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Classification of an on-screen high-layer or high-CPU window surface.
enum WindowAnomalyKind: String {
    case fullscreenOverlay = "fullscreenOverlay"
    case highLayerActive = "highLayerActive"
    case floatingPanelRedraw = "floatingPanelRedraw"
    case statusBarRedraw = "statusBarRedraw"
    case normalLayer = "normalLayer"
}

/// An on-screen window entry from `CGWindowListCopyWindowInfo`.
struct WindowSurfaceItem: Identifiable, Equatable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let executablePath: String?
    let layer: Int
    let bounds: CGRect
    let screenCoveragePercent: Int
    let ownerCPU: Double
    let ownerPorts: Int
    let kind: WindowAnomalyKind
    let severity: DiagnosticSeverity
    let diagnosis: String

    var id: UInt32 { windowID }

    var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: ownerPID), let ic = app.icon { return ic }
        if let path = executablePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
    }
}

/// A suspected runaway or high-CPU background process (e.g. PPID=1 orphan CLI process).
struct OrphanProcessItem: Identifiable, Equatable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let executablePath: String?
    let commandLine: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let ports: Int
    let uptimeSeconds: TimeInterval?
    let isOrphanedCLI: Bool
    let severity: DiagnosticSeverity
    let diagnosis: String

    var id: pid_t { pid }

    var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let ic = app.icon { return ic }
        if let path = executablePath { return NSWorkspace.shared.icon(forFile: path) }
        return NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Compact historical record saved after each manual or periodic read-only scan.
struct SystemDoctorHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let windowServerCPU: Double
    let windowServerPorts: Int
    let topPortProcessName: String
    let topPortCount: Int
    let anomalyCount: Int
}

/// Complete read-only inspection snapshot.
struct SystemDoctorSnapshot: Equatable {
    var timestamp = Date()
    var compositor = CompositorMetrics()
    var portAnomalies: [PortHolderItem] = []
    var topPortHolders: [PortHolderItem] = []
    var windowAnomalies: [WindowSurfaceItem] = []
    var elevatedWindows: [WindowSurfaceItem] = []
    var runawayProcesses: [OrphanProcessItem] = []
    var isValid = false

    var totalAnomalyCount: Int {
        portAnomalies.count + windowAnomalies.count + runawayProcesses.count
    }

    var overallSeverity: DiagnosticSeverity {
        let maxPort = portAnomalies.map(\.severity).max() ?? .healthy
        let maxWin = windowAnomalies.map(\.severity).max() ?? .healthy
        let maxProc = runawayProcesses.map(\.severity).max() ?? .healthy
        return max(compositor.overallSeverity, max(maxPort, max(maxWin, maxProc)))
    }
}

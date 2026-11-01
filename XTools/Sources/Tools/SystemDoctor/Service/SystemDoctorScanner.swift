import Foundation
import AppKit
import CoreGraphics

/// Purely read-only system health & compositor scanner.
///
/// Design invariants:
/// - **Strictly read-only**: never signals, pauses, terminates, or restarts any process.
/// - **True instantaneous CPU**: runs `/usr/bin/top -l 2 -s 1 -stats pid,cpu,ports,mem`
///   and parses ONLY the second sample block (sample 1 of `top` is the since-boot average).
/// - **Zero TCC prompts**: uses `sysctl(KERN_PROC_ALL)`, `proc_pidpath`, setuid `top`,
///   and `CGWindowListCopyWindowInfo` (window bounds/layer/owner PID require no Screen
///   Recording permission).
enum SystemDoctorScanner {

    private static let log = FileLog("SystemDoctor")

    private struct TopEntry {
        let pid: pid_t
        let cpu: Double
        let ports: Int
        let memBytes: UInt64
    }

    private struct TopCapture {
        var idlePercent: Double = 0
        var entries: [pid_t: TopEntry] = [:]
    }

    /// Known stateless or system UI daemons whose normal Mach port count is < 1,500.
    private static let systemUIDaemonNames: Set<String> = [
        "ControlCenter", "SystemUIServer", "NotificationCenter", "Dock",
        "WallpaperAgent", "WindowManager", "MenuBarAgent", "loginwindow"
    ]

    /// Known CLI / script runtimes that frequently become runaway orphan processes when a parent agent exits.
    private static let cliRuntimePrefixes: [String] = [
        "python", "node", "bun", "deno", "ruby", "perl", "php",
        "git", "rg", "find", "fd", "claude", "grok", "codex", "sh", "zsh", "bash"
    ]

    static func scan(displays: [DisplaySummary]) -> SystemDoctorSnapshot {
        let start = CFAbsoluteTimeGetCurrent()
        let roster = ProcessScanner.snapshot()
        var byPid: [pid_t: ManagedProcess] = [:]
        byPid.reserveCapacity(roster.count)
        for p in roster {
            byPid[p.pid] = p
        }

        let top = runTwoStepTop()
        var snap = SystemDoctorSnapshot(timestamp: Date())
        snap.compositor.displays = displays
        snap.compositor.systemIdlePercent = top.idlePercent

        // 1. Compositor & menu bar helper metrics
        for p in roster {
            let name = processDisplayName(p)
            guard let m = top.entries[p.pid] else { continue }
            if name == "WindowServer" || p.comm == "WindowServer" {
                snap.compositor.pid = p.pid
                snap.compositor.cpuPercent = m.cpu
                snap.compositor.machPorts = m.ports
                snap.compositor.memoryBytes = m.memBytes
            } else if name == "loginwindow" || p.comm == "loginwindow" {
                snap.compositor.loginwindowCPU += m.cpu
            } else if name == "MenuBarAgent" || p.comm == "MenuBarAgent" {
                snap.compositor.menuBarAgentCPU += m.cpu
            }
        }

        // 2. Mach port analysis across all processes
        var allPortItems: [PortHolderItem] = []
        allPortItems.reserveCapacity(top.entries.count)

        for (pid, m) in top.entries where pid > 0 {
            guard m.ports >= 300 else { continue }
            let proc = byPid[pid]
            let name = proc.map(processDisplayName) ?? "PID \(pid)"
            let path = proc?.executablePath
            let eval = evaluatePortHolder(
                pid: pid, name: name, path: path,
                ports: m.ports, cpu: m.cpu, mem: m.memBytes
            )
            allPortItems.append(eval)
        }

        allPortItems.sort { $0.ports != $1.ports ? $0.ports > $1.ports : $0.cpuPercent > $1.cpuPercent }
        snap.topPortHolders = Array(allPortItems.prefix(10))
        snap.portAnomalies = allPortItems.filter { $0.severity >= .warning }

        // 3. On-screen window layer & surface inspection
        let (winAnomalies, elevatedWins) = scanOnScreenWindows(
            byPid: byPid, top: top.entries, displays: displays,
            menuBarSyncCPU: snap.compositor.loginwindowCPU + snap.compositor.menuBarAgentCPU
        )
        snap.windowAnomalies = winAnomalies
        snap.elevatedWindows = elevatedWins

        // 4. Suspected runaway / orphan high-CPU processes
        snap.runawayProcesses = scanRunawayProcesses(roster: roster, top: top.entries)
        snap.isValid = !top.entries.isEmpty

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let detail = (snap.portAnomalies.map { "port:\($0.name)(\($0.ports))" }
            + snap.windowAnomalies.map { "win:\($0.ownerName)(L\($0.layer),\($0.ownerCPU)%)" }
            + snap.runawayProcesses.map { "proc:\($0.name)(\($0.cpuPercent)%)" }).joined(separator: ", ")
        log.info("scan finished in \(String(format: "%.0f", elapsedMs))ms: WS=\(String(format: "%.1f", snap.compositor.cpuPercent))% (\(snap.compositor.machPorts) ports), anomalies=\(snap.totalAnomalyCount) [\(detail)]")
        return snap
    }

    /// Reads display geometry on the main thread before hopping to the background scan queue.
    static func currentDisplays() -> [DisplaySummary] {
        NSScreen.screens.enumerated().map { idx, screen in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            let pw = Int((frame.width * scale).rounded())
            let ph = Int((frame.height * scale).rounded())
            let hz = screen.maximumFramesPerSecond
            return DisplaySummary(
                id: "\(idx)-\( screen.localizedName )",
                name: screen.localizedName,
                pixelWidth: pw,
                pixelHeight: ph,
                pointWidth: Int(frame.width.rounded()),
                pointHeight: Int(frame.height.rounded()),
                maxRefreshHz: hz
            )
        }
    }

    // MARK: - Step 1: 2-sample `top` (second sample = true 1s instantaneous delta)

    private static func runTwoStepTop() -> TopCapture {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        proc.arguments = ["-l", "2", "-s", "1", "-stats", "pid,cpu,ports,mem"]
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LC_NUMERIC"] = "C"
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            log.error("top launch failed: \(error.localizedDescription)")
            return TopCapture()
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return TopCapture()
        }
        return parseSecondTopBlock(text)
    }

    private static func parseSecondTopBlock(_ text: String) -> TopCapture {
        var capture = TopCapture()
        let lines = text.split(whereSeparator: \.isNewline)
        var pidHeaderSeen = 0
        var inSecondTable = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CPU usage:") {
                // Example: "CPU usage: 6.53% user, 6.87% sys, 86.59% idle"
                if let idleRange = line.range(of: "sys,"),
                   let endRange = line.range(of: "% idle") {
                    let sub = line[idleRange.upperBound..<endRange.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    if let val = Double(sub) {
                        capture.idlePercent = val
                    }
                }
                continue
            }
            if line.hasPrefix("PID") && line.contains("PORTS") {
                pidHeaderSeen += 1
                inSecondTable = (pidHeaderSeen >= 2)
                continue
            }
            guard inSecondTable, !line.isEmpty else { continue }
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 4 else { continue }

            let pidStr = cleanStatToken(cols[0])
            let cpuStr = cleanStatToken(cols[1])
            let portsStr = cleanStatToken(cols[2])
            let memStr = cleanStatToken(cols[3])

            guard let pid = pid_t(pidStr) else { continue }
            let cpu = Double(cpuStr) ?? 0
            let ports = Int(portsStr) ?? 0
            let memBytes = TopParser.parseMemory(memStr) ?? 0

            capture.entries[pid] = TopEntry(pid: pid, cpu: cpu, ports: ports, memBytes: memBytes)
        }
        return capture
    }

    /// Strips trailing `+`, `-`, `*` delta markers that `top` appends to numeric fields.
    private static func cleanStatToken(_ token: Substring) -> String {
        var s = String(token)
        while let last = s.last, last == "+" || last == "-" || last == "*" {
            s.removeLast()
        }
        return s
    }

    // MARK: - Step 2: Port holder classification & diagnosis

    private static func evaluatePortHolder(
        pid: pid_t, name: String, path: String?,
        ports: Int, cpu: Double, mem: UInt64
    ) -> PortHolderItem {
        if name == "WindowServer" {
            let sev: DiagnosticSeverity
            let diag: String
            if ports >= 55_000 {
                sev = .critical
                diag = String(format: L("sysdoc.port.diag.ws.critical"), ports)
            } else if ports >= 35_000 {
                sev = .warning
                diag = String(format: L("sysdoc.port.diag.ws.warning"), ports)
            } else {
                sev = .healthy
                diag = L("sysdoc.port.diag.ws.healthy")
            }
            return PortHolderItem(
                pid: pid, name: name, executablePath: path,
                ports: ports, cpuPercent: cpu, memoryBytes: mem,
                role: .compositor, severity: sev, diagnosis: diag
            )
        }

        if systemUIDaemonNames.contains(name) {
            let sev: DiagnosticSeverity
            let diag: String
            if ports >= 15_000 {
                sev = .critical
                diag = String(format: L("sysdoc.port.diag.uidaemon.critical"), name, ports)
            } else if ports >= 5_000 {
                sev = .warning
                diag = String(format: L("sysdoc.port.diag.uidaemon.warning"), name, ports)
            } else {
                sev = .healthy
                diag = L("sysdoc.port.diag.uidaemon.healthy")
            }
            return PortHolderItem(
                pid: pid, name: name, executablePath: path,
                ports: ports, cpuPercent: cpu, memoryBytes: mem,
                role: .systemUIDaemon, severity: sev, diagnosis: diag
            )
        }

        let isApp = (path?.contains(".app/") == true)
        let role: PortHolderRole = isApp ? .userApp : .systemDaemon
        let sev: DiagnosticSeverity
        let diag: String

        if isApp {
            if ports >= 18_000 {
                sev = .critical
                diag = String(format: L("sysdoc.port.diag.app.critical"), ports)
            } else if ports >= 8_000 {
                sev = .warning
                diag = String(format: L("sysdoc.port.diag.app.warning"), ports)
            } else {
                sev = .healthy
                diag = L("sysdoc.port.diag.app.healthy")
            }
        } else {
            // Non-GUI system daemons (like usbaudiod / coreaudiod / launchd) hold IOKit or XPC
            // ports in their own namespace and do NOT pin WindowServer render ports.
            sev = .healthy
            diag = L("sysdoc.port.diag.daemon.healthy")
        }

        return PortHolderItem(
            pid: pid, name: name, executablePath: path,
            ports: ports, cpuPercent: cpu, memoryBytes: mem,
            role: role, severity: sev, diagnosis: diag
        )
    }

    // MARK: - Step 3: On-screen window surfaces (`CGWindowListCopyWindowInfo`)

    private static func scanOnScreenWindows(
        byPid: [pid_t: ManagedProcess],
        top: [pid_t: TopEntry],
        displays: [DisplaySummary],
        menuBarSyncCPU: Double
    ) -> (anomalies: [WindowSurfaceItem], elevated: [WindowSurfaceItem]) {
        guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ([], [])
        }

        let maxScreenArea = Double(displays.map { $0.pointWidth * $0.pointHeight }.max() ?? (1920 * 1080))
        var anomalies: [WindowSurfaceItem] = []
        var elevated: [WindowSurfaceItem] = []

        for w in rawList {
            guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != getpid(),
                  let windowID = w[kCGWindowNumber as String] as? UInt32 else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            // Only inspect non-standard window layers (layer != 0)
            guard layer != 0 else { continue }

            let ownerName = (w[kCGWindowOwnerName as String] as? String)
                ?? byPid[ownerPID].map(processDisplayName)
                ?? "PID \(ownerPID)"
            let path = byPid[ownerPID]?.executablePath
            let boundsDict = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = boundsDict["X"] as? CGFloat ?? 0
            let y = boundsDict["Y"] as? CGFloat ?? 0
            let width = boundsDict["Width"] as? CGFloat ?? 0
            let height = boundsDict["Height"] as? CGFloat ?? 0
            let bounds = CGRect(x: x, y: y, width: width, height: height)

            let area = Double(width * height)
            let coverage = maxScreenArea > 0 ? Int((area / maxScreenArea * 100).rounded()) : 0
            let windowMemBytes = w[kCGWindowMemoryUsage as String] as? Int ?? 0
            let m = top[ownerPID]
            let cpu = m?.cpu ?? 0
            let ports = m?.ports ?? 0

            // Skip built-in system wallpaper/cursor/desktop surfaces from WindowServer / Dock / loginwindow
            if ownerName == "WindowServer" || ownerName == "Window Server" || ownerName == "Dock" || ownerName == "loginwindow" {
                continue
            }

            var kind: WindowAnomalyKind = .normalLayer
            var sev: DiagnosticSeverity = .healthy
            var diag = String(format: L("sysdoc.win.diag.normal"), layer, Int(width), Int(height))

            // An unbacked placeholder window (kCGWindowMemoryUsage ~ 2.4 KB) has no pixel texture in WindowServer.
            // Only flag a fullscreen high-layer window if it is actively burning significant CPU (>= 12%)
            // or holds a real pixel backing store (> 1 MB) while consuming CPU (>= 5%).
            let hasRealBackingStore = windowMemBytes >= 1_048_576
            if coverage >= 75 && layer >= 100 && (cpu >= 12.0 || (hasRealBackingStore && cpu >= 5.0)) {
                kind = .fullscreenOverlay
                sev = cpu >= 15.0 ? .critical : .warning
                diag = String(format: L("sysdoc.win.diag.fullscreenOverlay"), layer, Int(width), Int(height), cpu)
            } else if layer != 25 && layer >= 15 && cpu >= 12.0 {
                kind = .floatingPanelRedraw
                sev = cpu >= 20.0 ? .critical : .warning
                diag = String(format: L("sysdoc.win.diag.floatingRedraw"), layer, cpu)
            } else if layer == 25 && cpu >= 15.0 && menuBarSyncCPU >= 10.0 {
                kind = .statusBarRedraw
                sev = .warning
                diag = String(format: L("sysdoc.win.diag.statusBarRedraw"), cpu, menuBarSyncCPU)
            } else if layer >= 1000 {
                kind = .highLayerActive
                sev = .healthy
                diag = String(format: L("sysdoc.win.diag.highLayer"), layer, Int(width), Int(height))
            }

            let item = WindowSurfaceItem(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                executablePath: path,
                layer: layer,
                bounds: bounds,
                screenCoveragePercent: min(100, max(0, coverage)),
                ownerCPU: cpu,
                ownerPorts: ports,
                kind: kind,
                severity: sev,
                diagnosis: diag
            )

            elevated.append(item)
            if sev >= .warning, !anomalies.contains(where: { $0.ownerPID == ownerPID && $0.kind == kind }) {
                anomalies.append(item)
            }
        }

        elevated.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.ownerCPU != $1.ownerCPU { return $0.ownerCPU > $1.ownerCPU }
            return $0.screenCoveragePercent > $1.screenCoveragePercent
        }
        return (anomalies, Array(elevated.prefix(25)))
    }

    // MARK: - Step 4: Suspected runaway / orphan processes

    private static func scanRunawayProcesses(
        roster: [ManagedProcess],
        top: [pid_t: TopEntry]
    ) -> [OrphanProcessItem] {
        let nowMicros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        var results: [OrphanProcessItem] = []

        for p in roster where p.pid > 1 {
            // Skip our own XTools process and the short-lived `top` child we spawned
            if p.pid == getpid() || p.ppid == getpid() || p.comm == "top" { continue }
            guard let m = top[p.pid], m.cpu >= 25.0 else { continue }

            let name = processDisplayName(p)
            if name == "WindowServer" || name == "kernel_task" { continue }

            let path = p.executablePath ?? ""
            let lowerName = name.lowercased()
            let isCLIRuntime = cliRuntimePrefixes.contains { lowerName == $0 || lowerName.hasPrefix($0 + "3") || lowerName.hasPrefix($0 + "-") }
            let isInAppBundle = path.contains(".app/")
            let isAppleDaemon = path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
            let isOrphanedCLI = (p.ppid == 1 && !isInAppBundle && !isAppleDaemon) || (p.ppid == 1 && isCLIRuntime)

            // Report if it's an orphaned CLI process burning >= 25% CPU, OR any process burning >= 80% CPU
            guard isOrphanedCLI || m.cpu >= 80.0 else { continue }

            let startMicros = ProcRoster.startTime(pid: p.pid)
            let uptime: TimeInterval? = startMicros.flatMap { start in
                nowMicros > start ? TimeInterval(nowMicros - start) / 1_000_000 : nil
            }

            let argvText: String
            if let argv = ProcArguments.arguments(pid: p.pid), !argv.values.isEmpty {
                argvText = argv.values.joined(separator: " ")
            } else {
                argvText = path.isEmpty ? name : path
            }

            let sev: DiagnosticSeverity = (isOrphanedCLI && m.cpu >= 60.0) || m.cpu >= 90.0 ? .critical : .warning
            let diag: String
            if isOrphanedCLI {
                diag = String(format: L("sysdoc.proc.diag.orphanCLI"), m.cpu)
            } else {
                diag = String(format: L("sysdoc.proc.diag.highCPU"), p.ppid, m.cpu)
            }

            results.append(OrphanProcessItem(
                pid: p.pid,
                ppid: p.ppid,
                name: name,
                executablePath: p.executablePath,
                commandLine: argvText,
                cpuPercent: m.cpu,
                memoryBytes: m.memBytes,
                ports: m.ports,
                uptimeSeconds: uptime,
                isOrphanedCLI: isOrphanedCLI,
                severity: sev,
                diagnosis: diag
            ))
        }

        results.sort { $0.cpuPercent > $1.cpuPercent }
        return results
    }

    private static func processDisplayName(_ p: ManagedProcess) -> String {
        if let app = NSRunningApplication(processIdentifier: p.pid),
           let localName = app.localizedName, !localName.isEmpty {
            return localName
        }
        return p.name
    }
}

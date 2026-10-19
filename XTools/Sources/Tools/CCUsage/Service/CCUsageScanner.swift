import Foundation

/// Runs `ccusage daily --json --by-agent --offline` and decodes its JSON output.
///
/// Because GUI macOS apps launch with a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
/// `CCUsageScanner` automatically locates either:
/// 1. The cached native binary under `~/.npm/_npx/.../node_modules/@ccusage/ccusage-darwin-arm64/bin/ccusage` (fastest, ~0.7s, zero Node startup overhead)
/// 2. Any `ccusage` binary in common user/Homebrew/nvm/fnm/volta/bun bin directories
/// 3. Fallback to `npx ccusage` using a discovered `npx` + `node` directory added to `PATH`.
enum CCUsageScanner {

    struct ScanResult {
        var report: CCUsageReport
        var fetchedAt: Date
        var errorMessage: String?
    }

    private static let cacheLock = NSLock()
    private static var lastCachedResult: ScanResult?

    /// Returns the most recent scan if it is younger than `maxAge` seconds,
    /// otherwise performs a fresh scan. Useful for the Dashboard overview card.
    static func scanCached(maxAge: TimeInterval = 30) -> ScanResult {
        cacheLock.lock()
        if let cached = lastCachedResult, Date().timeIntervalSince(cached.fetchedAt) < maxAge, cached.errorMessage == nil {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        return scan()
    }

    /// Executes `ccusage daily --json --by-agent --offline` synchronously on the calling queue.
    static func scan() -> ScanResult {
        let now = Date()
        let resolved = resolveCommand()
        guard let executable = resolved.executable else {
            let res = ScanResult(
                report: .empty,
                fetchedAt: now,
                errorMessage: "ccusage / npx not found. Install Node.js or ccusage CLI."
            )
            storeCache(res)
            return res
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = resolved.arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolved.augmentedPath
        env["NO_COLOR"] = "1"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            let res = ScanResult(
                report: .empty,
                fetchedAt: now,
                errorMessage: error.localizedDescription
            )
            storeCache(res)
            return res
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, !outData.isEmpty else {
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = errText.isEmpty ? "ccusage exited with code \(proc.terminationStatus)" : errText
            let res = ScanResult(report: .empty, fetchedAt: now, errorMessage: msg)
            storeCache(res)
            return res
        }

        do {
            let report = try parseJSON(outData)
            let res = ScanResult(report: report, fetchedAt: now, errorMessage: nil)
            storeCache(res)
            return res
        } catch {
            let res = ScanResult(
                report: .empty,
                fetchedAt: now,
                errorMessage: "JSON decode error: \(error.localizedDescription)"
            )
            storeCache(res)
            return res
        }
    }

    /// Pure JSON parser exposed internal for unit tests.
    static func parseJSON(_ data: Data) throws -> CCUsageReport {
        let decoder = JSONDecoder()
        return try decoder.decode(CCUsageReport.self, from: data)
    }

    private static func storeCache(_ result: ScanResult) {
        cacheLock.lock()
        if result.errorMessage == nil || lastCachedResult == nil {
            lastCachedResult = result
        }
        cacheLock.unlock()
    }

    // MARK: - Executable Resolution

    private struct ResolvedCommand {
        let executable: String?
        let arguments: [String]
        let augmentedPath: String
    }

    private static func resolveCommand() -> ResolvedCommand {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let extraBinDirs = candidateBinDirectories(home: home, fm: fm)
        let basePath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let augmentedPath = (extraBinDirs + [basePath]).joined(separator: ":")

        let cliArgs = ["daily", "--json", "--by-agent", "--offline"]

        // 1. Prefer cached native arm64/x64 binary inside ~/.npm/_npx if available (avoids npx wrapper overhead).
        if let nativeBin = findNpxCachedNativeBinary(home: home, fm: fm) {
            return ResolvedCommand(executable: nativeBin, arguments: cliArgs, augmentedPath: augmentedPath)
        }

        // 2. Check for global `ccusage` in candidate bin dirs.
        for dir in extraBinDirs {
            let candidate = (dir as NSString).appendingPathComponent("ccusage")
            if fm.isExecutableFile(atPath: candidate) {
                return ResolvedCommand(executable: candidate, arguments: cliArgs, augmentedPath: augmentedPath)
            }
        }

        // 3. Fallback to `npx --yes ccusage ...`
        for dir in extraBinDirs {
            let npxPath = (dir as NSString).appendingPathComponent("npx")
            if fm.isExecutableFile(atPath: npxPath) {
                return ResolvedCommand(
                    executable: npxPath,
                    arguments: ["--yes", "ccusage"] + cliArgs,
                    augmentedPath: augmentedPath
                )
            }
        }

        return ResolvedCommand(executable: nil, arguments: [], augmentedPath: augmentedPath)
    }

    private static func findNpxCachedNativeBinary(home: String, fm: FileManager) -> String? {
        let npxRoot = (home as NSString).appendingPathComponent(".npm/_npx")
        guard let entries = try? fm.contentsOfDirectory(atPath: npxRoot) else { return nil }

        #if arch(arm64)
        let pkgSubpaths = [
            "node_modules/@ccusage/ccusage-darwin-arm64/bin/ccusage",
            "node_modules/.bin/ccusage"
        ]
        #else
        let pkgSubpaths = [
            "node_modules/@ccusage/ccusage-darwin-x64/bin/ccusage",
            "node_modules/.bin/ccusage"
        ]
        #endif

        var bestPath: String?
        var bestMtime: Date = .distantPast

        for entry in entries {
            let base = (npxRoot as NSString).appendingPathComponent(entry)
            for sub in pkgSubpaths {
                let full = (base as NSString).appendingPathComponent(sub)
                if fm.isExecutableFile(atPath: full) {
                    let mtime = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast
                    if mtime >= bestMtime {
                        bestMtime = mtime
                        bestPath = full
                    }
                    break
                }
            }
        }
        return bestPath
    }

    private static func candidateBinDirectories(home: String, fm: FileManager) -> [String] {
        var dirs: [String] = [
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent(".bun/bin"),
            (home as NSString).appendingPathComponent(".volta/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]

        // Discover nvm node versions (newest first)
        let nvmDir = (home as NSString).appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for v in sorted {
                let binPath = ((nvmDir as NSString).appendingPathComponent(v) as NSString).appendingPathComponent("bin")
                if fm.fileExists(atPath: binPath) {
                    dirs.insert(binPath, at: 0)
                }
            }
        }

        // Discover fnm node versions
        let fnmDir = (home as NSString).appendingPathComponent(".local/share/fnm/node-versions")
        if let versions = try? fm.contentsOfDirectory(atPath: fnmDir) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for v in sorted {
                let binPath = (((fnmDir as NSString).appendingPathComponent(v) as NSString)
                    .appendingPathComponent("installation/bin"))
                if fm.fileExists(atPath: binPath) {
                    dirs.append(binPath)
                }
            }
        }

        return dirs
    }
}

import Foundation

/// Runs the managed native `ccusage` binary (`ccusage daily --json --by-agent --offline`)
/// and decodes its JSON output.
enum CCUsageScanner {

    struct ScanResult {
        var report: CCUsageReport
        var fetchedAt: Date
        var errorMessage: String?
    }

    private static let cacheLock = NSLock()
    private static var lastCachedResult: ScanResult?

    /// Returns the most recent scan if it is younger than `maxAge` seconds,
    /// otherwise performs a fresh scan if the managed `ccusage` binary is installed.
    static func scanCached(maxAge: TimeInterval = 30) -> ScanResult {
        cacheLock.lock()
        if let cached = lastCachedResult, Date().timeIntervalSince(cached.fetchedAt) < maxAge, cached.errorMessage == nil {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard CCUsageBinaryManager.isInstalled else {
            return ScanResult(report: .empty, fetchedAt: Date(), errorMessage: nil)
        }
        return scan()
    }

    /// Executes `ccusage daily --json --by-agent --offline` synchronously on the calling queue.
    static func scan() -> ScanResult {
        let now = Date()
        let binaryPath = CCUsageBinaryManager.managedBinaryURL.path
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            let res = ScanResult(
                report: .empty,
                fetchedAt: now,
                errorMessage: L("ccusage.error.notInstalled")
            )
            storeCache(res)
            return res
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["daily", "--json", "--by-agent", "--offline"]

        var env = ProcessInfo.processInfo.environment
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
}

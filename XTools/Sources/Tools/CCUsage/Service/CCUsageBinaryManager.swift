import Foundation
import CryptoKit

/// Manages downloading, verifying, installing, and updating the official native `ccusage` binary
/// inside `~/Library/Application Support/XTools/ccusage/bin/ccusage`.
///
/// Security model:
/// - Reads the official release metadata JSON from `https://registry.npmjs.org/@ccusage/ccusage-darwin-<arch>/latest`
/// - Verifies GitHub Actions OIDC trusted publisher / SLSA v1 provenance attestation metadata
/// - Enforces HTTPS tarball origin under `https://registry.npmjs.org/@ccusage/ccusage-darwin-`
/// - Verifies both SHA-1 (`dist.shasum`) and SHA-512 (`dist.integrity`) using `CryptoKit` before unpacking
/// - Extracts only `package/bin/ccusage`, verifies `ccusage --version` matches the manifest version,
///   and atomically replaces the managed binary.
enum CCUsageBinaryManager {

    #if arch(arm64)
    static let packageName = "@ccusage/ccusage-darwin-arm64"
    static let latestManifestURL = URL(string: "https://registry.npmjs.org/@ccusage/ccusage-darwin-arm64/latest")!
    #else
    static let packageName = "@ccusage/ccusage-darwin-x64"
    static let latestManifestURL = URL(string: "https://registry.npmjs.org/@ccusage/ccusage-darwin-x64/latest")!
    #endif

    struct RegistryManifest: Decodable, Equatable {
        let name: String
        let version: String
        let dist: Dist
        let npmUser: NpmUser?

        enum CodingKeys: String, CodingKey {
            case name, version, dist
            case npmUser = "_npmUser"
        }

        struct Dist: Decodable, Equatable {
            let tarball: String
            let shasum: String
            let integrity: String?
            let attestations: Attestations?
        }

        struct Attestations: Decodable, Equatable {
            let provenance: Provenance?
        }

        struct Provenance: Decodable, Equatable {
            let predicateType: String?
        }

        struct NpmUser: Decodable, Equatable {
            let trustedPublisher: TrustedPublisher?
        }

        struct TrustedPublisher: Decodable, Equatable {
            let id: String?
        }
    }

    enum UpdateOutcome: Equatable {
        case installed(version: String)
        case updated(from: String, to: String)
        case upToDate(version: String)
    }

    enum ManagerError: LocalizedError, Equatable {
        case invalidManifest(String)
        case untrustedProvenance
        case invalidTarballURL(String)
        case hashMismatch(String)
        case extractionFailed(String)
        case binaryVerificationFailed(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest(let msg):
                return "Invalid release manifest: \(msg)"
            case .untrustedProvenance:
                return "Untrusted release package: missing GitHub SLSA provenance."
            case .invalidTarballURL(let url):
                return "Untrusted tarball URL: \(url)"
            case .hashMismatch(let detail):
                return "Package integrity verification failed (\(detail))."
            case .extractionFailed(let detail):
                return "Failed to extract ccusage binary: \(detail)"
            case .binaryVerificationFailed(let detail):
                return "Extracted ccusage binary failed verification: \(detail)"
            case .networkError(let detail):
                return detail
            }
        }
    }

    // MARK: - Paths & Installed State

    /// Directory where XTools stores the managed `ccusage` binary.
    static var installDirectoryURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("XTools", isDirectory: true)
            .appendingPathComponent("ccusage", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Full path to the managed `ccusage` executable.
    static var managedBinaryURL: URL {
        installDirectoryURL.appendingPathComponent("ccusage", isDirectory: false)
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: managedBinaryURL.path)
    }

    /// Queries the currently installed `ccusage` binary version (e.g. `"20.0.36"`), or `nil` if not installed.
    static func installedVersion() -> String? {
        let path = managedBinaryURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return queryBinaryVersion(atPath: path)
    }

    static func queryBinaryVersion(atPath binaryPath: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--version"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        // Never read, so don't use a Pipe: a full pipe buffer would block the child (and `waitUntilExit`).
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        // Output is e.g. "ccusage 20.0.36"
        return text.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    // MARK: - Manifest & Integrity Validation

    static func parseAndValidateManifest(_ data: Data, expectedPackage: String = packageName) throws -> RegistryManifest {
        let manifest: RegistryManifest
        do {
            manifest = try JSONDecoder().decode(RegistryManifest.self, from: data)
        } catch {
            throw ManagerError.invalidManifest(error.localizedDescription)
        }

        guard manifest.name == expectedPackage else {
            throw ManagerError.invalidManifest("unexpected package name '\(manifest.name)'")
        }
        guard !manifest.version.isEmpty else {
            throw ManagerError.invalidManifest("empty version string")
        }

        // Verify provenance / trusted publisher from GitHub Actions
        let hasSLSA = manifest.dist.attestations?.provenance?.predicateType?.contains("slsa.dev/provenance") == true
        let hasGitHubPublisher = manifest.npmUser?.trustedPublisher?.id == "github"
        guard hasSLSA || hasGitHubPublisher else {
            throw ManagerError.untrustedProvenance
        }

        // Verify tarball URL points to the official registry HTTPS endpoint
        guard manifest.dist.tarball.hasPrefix("https://registry.npmjs.org/@ccusage/ccusage-darwin-"),
              manifest.dist.tarball.hasSuffix(".tgz"),
              URL(string: manifest.dist.tarball) != nil else {
            throw ManagerError.invalidTarballURL(manifest.dist.tarball)
        }

        return manifest
    }

    static func verifyTarballIntegrity(_ data: Data, dist: RegistryManifest.Dist) throws {
        // 1. Verify SHA-1 shasum
        let sha1Hex = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sha1Hex.lowercased() == dist.shasum.lowercased() else {
            throw ManagerError.hashMismatch("SHA-1 expected \(dist.shasum), got \(sha1Hex)")
        }

        // 2. Verify SHA-512 integrity if present ("sha512-<base64>")
        if let integrity = dist.integrity, integrity.hasPrefix("sha512-") {
            let expectedBase64 = String(integrity.dropFirst("sha512-".count))
            let sha512Base64 = Data(SHA512.hash(data: data)).base64EncodedString()
            guard sha512Base64 == expectedBase64 else {
                throw ManagerError.hashMismatch("SHA-512 integrity mismatch")
            }
        }
    }

    // MARK: - Download & Update Operations

    /// How often the app checks npm for a newer `ccusage` on its own (ccusage ships every few days).
    static let autoUpdateInterval: TimeInterval = 24 * 60 * 60

    /// Whether an automatic update check is due. A missing last-check date, or one in the
    /// future (the clock was moved back), counts as due.
    static func isUpdateCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = autoUpdateInterval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// Serializes install/update runs: the first-run download, the manual "Check for Update"
    /// button and the background auto-update may otherwise replace the binary at the same time.
    private static let installLock = NSLock()

    /// Fetches the latest official release manifest and installs or updates the binary if needed.
    static func installOrUpdate() throws -> UpdateOutcome {
        installLock.lock()
        defer { installLock.unlock() }

        let currentVersion = installedVersion()
        let manifestData = try fetchData(from: latestManifestURL)
        let manifest = try parseAndValidateManifest(manifestData)

        if let currentVersion, currentVersion == manifest.version, isInstalled {
            return .upToDate(version: currentVersion)
        }

        guard let tarballURL = URL(string: manifest.dist.tarball) else {
            throw ManagerError.invalidTarballURL(manifest.dist.tarball)
        }

        let tarballData = try fetchData(from: tarballURL)
        try verifyTarballIntegrity(tarballData, dist: manifest.dist)
        try extractAndInstall(tarballData: tarballData, expectedVersion: manifest.version)

        if let currentVersion {
            return .updated(from: currentVersion, to: manifest.version)
        } else {
            return .installed(version: manifest.version)
        }
    }

    private static func fetchData(from url: URL) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                resultError = ManagerError.networkError(error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                resultError = ManagerError.networkError("HTTP \(http.statusCode) from \(url.host ?? "registry")")
                return
            }
            resultData = data
        }
        task.resume()
        sem.wait()

        if let err = resultError { throw err }
        guard let data = resultData, !data.isEmpty else {
            throw ManagerError.networkError("Empty response from \(url.absoluteString)")
        }
        return data
    }

    private static func extractAndInstall(tarballData: Data, expectedVersion: String) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("xtools-ccusage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let archiveFile = tempDir.appendingPathComponent("ccusage.tgz")
        try tarballData.write(to: archiveFile, options: .atomic)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archiveFile.path, "-C", tempDir.path, "package/bin/ccusage"]
        let errPipe = Pipe()
        tar.standardOutput = Pipe()
        tar.standardError = errPipe
        try tar.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()

        guard tar.terminationStatus == 0 else {
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tar exit \(tar.terminationStatus)"
            throw ManagerError.extractionFailed(errStr)
        }

        let extractedBinary = tempDir.appendingPathComponent("package/bin/ccusage")
        guard fm.fileExists(atPath: extractedBinary.path) else {
            throw ManagerError.extractionFailed("package/bin/ccusage missing in archive")
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedBinary.path)

        guard let reportedVersion = queryBinaryVersion(atPath: extractedBinary.path) else {
            throw ManagerError.binaryVerificationFailed("binary failed to execute --version")
        }
        guard reportedVersion == expectedVersion else {
            throw ManagerError.binaryVerificationFailed("expected \(expectedVersion), got \(reportedVersion)")
        }

        let destDir = installDirectoryURL
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destBinary = managedBinaryURL

        if fm.fileExists(atPath: destBinary.path) {
            _ = try fm.replaceItemAt(destBinary, withItemAt: extractedBinary)
        } else {
            try fm.moveItem(at: extractedBinary, to: destBinary)
        }
    }
}

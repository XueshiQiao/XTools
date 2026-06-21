import Foundation

/// Reads the current DNS configuration by running `scutil --dns` (read-only, no
/// sudo, no prompt) and parsing its resolver blocks.
///
/// `scutil --dns` output is a series of blocks like:
///
///     DNS configuration
///
///     resolver #1
///       search domain[0] : lan
///       nameserver[0] : 192.168.1.1
///       nameserver[1] : 192.168.1.2
///       flags    : Request A records, Request AAAA records
///       reach    : 0x00020002 (Reachable,Directly Reachable Address)
///
///     resolver #2
///       domain   : local
///       ...
///
/// We surface the PRIMARY resolvers — the ones under the top "DNS configuration"
/// section (before the "DNS configuration (for scoped queries)" section), which
/// are what the system uses for ordinary lookups. Name servers and search
/// domains are de-duplicated while preserving first-seen order.
enum DNSReader {

    private static let log = FileLog("DNSReader")
    private static let scutilPath = "/usr/sbin/scutil"

    static func read() -> DNSConfig {
        guard let out = run(["--dns"]) else { return DNSConfig() }

        var addresses: [String] = []
        var search: [String] = []
        var seenAddr = Set<String>()
        var seenSearch = Set<String>()

        // Only collect from the primary section. scutil prints a second section
        // header "DNS configuration (for scoped queries)" — once we hit that, we
        // stop, because those resolvers are interface-scoped duplicates.
        for rawLine in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped queries)") { break }

            // "nameserver[0] : 192.168.1.1"  → take the value after the colon.
            if line.hasPrefix("nameserver[") {
                if let value = colonValue(line), seenAddr.insert(value).inserted {
                    addresses.append(value)
                }
            } else if line.hasPrefix("search domain[") {
                if let value = colonValue(line), seenSearch.insert(value).inserted {
                    search.append(value)
                }
            }
        }

        log.info("scutil --dns parsed \(addresses.count) resolver(s), \(search.count) search domain(s)")
        return DNSConfig(resolverAddresses: addresses, searchDomains: search)
    }

    /// Returns the trimmed value after the first " : " on a `key : value` line.
    private static func colonValue(_ line: String) -> String? {
        guard let range = line.range(of: " : ") else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func run(_ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scutilPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()   // swallow stderr
        do {
            try proc.run()
        } catch {
            log.error("failed to run scutil \(args): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

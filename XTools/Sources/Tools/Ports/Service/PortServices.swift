import Foundation

/// Maps a port number to a short, recognizable service label (e.g. 5353 → "mDNS")
/// so the UI can show what a port is for at a glance.
///
/// A curated table gives friendly labels for the common/dev ports; everything
/// else falls back to the system's `/etc/services` (the canonical IANA list,
/// ~9800 entries), parsed once and cached.
enum PortServices {

    /// Friendly labels for well-known + developer ports. Takes precedence over
    /// /etc/services (whose names are terse/lowercase, e.g. "mdns").
    private static let curated: [Int: String] = [
        22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
        80: "HTTP", 88: "Kerberos", 110: "POP3", 111: "rpcbind", 123: "NTP",
        137: "NetBIOS", 138: "NetBIOS", 139: "SMB", 143: "IMAP", 161: "SNMP",
        389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS", 548: "AFP",
        587: "SMTP", 631: "IPP", 636: "LDAPS", 993: "IMAPS", 995: "POP3S",
        1900: "SSDP", 3283: "ARD", 5000: "UPnP/AirPlay", 5060: "SIP", 5061: "SIP",
        5353: "mDNS", 5900: "VNC", 7000: "AirPlay", 62078: "iOS-sync",
        // dev servers
        3000: "dev", 3001: "dev", 4000: "dev", 4200: "Angular", 5173: "Vite",
        8000: "dev", 8080: "HTTP-alt", 8443: "HTTPS-alt", 9000: "dev", 9229: "Node-debug",
        // databases / infra
        2375: "Docker", 2376: "Docker", 3306: "MySQL", 5432: "PostgreSQL",
        5672: "AMQP", 6379: "Redis", 6443: "Kubernetes", 9092: "Kafka",
        11211: "memcached", 27017: "MongoDB",
    ]

    private static let etcServices: [Int: String] = loadEtcServices()

    /// A short service label for a port, or nil if unknown. Curated table first
    /// (friendly labels for the ports we intentionally recognize), then the
    /// system `/etc/services` (IANA list) as a fallback for everything else.
    /// Note: some high-port /etc/services names are stale (e.g. 1234 →
    /// "search-agent") — kept anyway, as the list is useful overall.
    static func name(for portString: String) -> String? {
        guard let p = Int(portString) else { return nil }
        if let c = curated[p] { return c }
        return etcServices[p]
    }

    private static func loadEtcServices() -> [Int: String] {
        guard let content = try? String(contentsOfFile: "/etc/services", encoding: .utf8) else { return [:] }
        var map: [Int: String] = [:]
        for line in content.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            // Format: "<name>  <port>/<proto>  [aliases] # comment"
            let cols = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 2 else { continue }
            let portToken = cols[1].split(separator: "/").first.map(String.init) ?? ""
            if let port = Int(portToken), map[port] == nil {
                map[port] = cols[0]
            }
        }
        return map
    }
}

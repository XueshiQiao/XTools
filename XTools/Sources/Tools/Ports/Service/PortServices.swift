import Foundation

/// Maps a port number to a short, recognizable service label (e.g. 5353 → "mDNS")
/// so the UI can show what a port is for at a glance.
///
/// Only this curated table is used — every label is hand-picked and trustworthy.
/// (We intentionally don't fall back to /etc/services, whose high-port registered
/// names are usually stale/wrong for what's actually running.)
enum PortServices {

    /// Friendly labels for well-known + developer ports.
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

    /// A short service label for a port, or nil if we don't recognize it. Only the
    /// curated table is used — every label is hand-picked and trustworthy. (We
    /// deliberately do NOT fall back to /etc/services, whose high-port registered
    /// names are usually stale/wrong, e.g. 1234 → "search-agent".)
    static func name(for portString: String) -> String? {
        guard let p = Int(portString) else { return nil }
        return curated[p]
    }
}

import Foundation

/// The current DNS resolver configuration, parsed from `scutil --dns`.
///
/// `scutil --dns` prints several "resolver #N" blocks. The first few (the
/// primary scoped resolvers, flag `Request A records`) are the ones macOS
/// actually uses for normal lookups — those are the useful ones to surface.
struct DNSConfig: Equatable {
    /// Primary resolver name servers (de-duplicated, in order). These are the
    /// addresses your Mac is querying for DNS right now.
    var resolverAddresses: [String] = []

    /// Search domains appended to unqualified host names (de-duplicated).
    var searchDomains: [String] = []

    var isEmpty: Bool { resolverAddresses.isEmpty && searchDomains.isEmpty }
}

/// One parsed entry from `/etc/hosts`: an IP plus the host names mapped to it.
struct HostEntry: Identifiable, Hashable {
    let ip: String
    let hostnames: [String]

    /// Stable id derived from the entry's content, so SwiftUI reuses rows across
    /// re-parses (entries are parsed fresh on every refresh / save).
    var id: String { "\(ip)\t\(hostnames.joined(separator: " "))" }
}

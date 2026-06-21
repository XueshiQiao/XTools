import SwiftUI

/// The DNS & hosts tool: shows the current DNS resolvers / search domains
/// (`scutil --dns`, read-only), flushes the DNS cache (root, via PrivilegedRunner),
/// and views / edits `/etc/hosts` (read free; saving is root and backs the file
/// up to `/etc/hosts.bak` first).
///
/// Self-contained in `Sources/Tools/DNSTools/`. On-demand reader + user-initiated
/// privileged actions, so no app-lifetime background work (no `activate()`).
final class DNSToolsTool: XToolModule {

    let id = "dns-tools"
    var title: String { L("tool.dns.title") }
    let symbol = "network"
    let color = Color.teal

    private lazy var store = DNSToolsStore()

    func makeRootView() -> AnyView { AnyView(DNSToolsView(store: store)) }
}

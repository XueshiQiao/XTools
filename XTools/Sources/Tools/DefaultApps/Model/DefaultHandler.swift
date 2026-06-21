import Foundation
import AppKit

/// Whether a handled item is a content type (UTI) or a URL scheme. The
/// LaunchServices call to read/set a default differs between the two.
enum HandledItemKind {
    case contentType    // e.g. public.plain-text  → LSCopyDefaultRoleHandlerForContentType
    case urlScheme      // e.g. https              → LSCopyDefaultHandlerForURLScheme
}

/// One installed app that can act as a handler — resolved from a bundle id to a
/// display name + icon so the picker can show it. Resolution happens off-main in
/// the scanner; the icon (`NSImage`) is cached on the value so the view never
/// hits disk while rendering rows.
struct HandlerApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?
    let icon: NSImage?

    var id: String { bundleID }

    static func == (lhs: HandlerApp, rhs: HandlerApp) -> Bool { lhs.bundleID == rhs.bundleID }
    func hash(into hasher: inout Hasher) { hasher.combine(bundleID) }
}

/// One row in the Default Apps page: a file type or URL scheme, its current
/// default handler (if any), and every installed app that could handle it.
struct HandledItem: Identifiable {
    let kind: HandledItemKind

    /// The LaunchServices identifier: a UTI string (for `.contentType`) or a bare
    /// scheme like "https" (for `.urlScheme`). This is what we pass to the LS calls.
    let identifier: String

    /// Localized human label shown to the user, e.g. "Plain text" / "Web (HTTPS)".
    let label: String

    /// SF Symbol used as the row's leading icon tile.
    let symbol: String

    /// Current default handler app, or nil if the system has none assigned.
    let current: HandlerApp?

    /// Every installed app that declares it can handle this item (already resolved
    /// to name + icon, sorted by name). Includes the current handler.
    let candidates: [HandlerApp]

    /// Stable id: kind + identifier (identifiers are unique within a kind).
    var id: String { "\(kind)-\(identifier)" }

    /// True when there's more than one app to choose from (otherwise the picker
    /// would be a no-op and we just show the single handler).
    var hasChoice: Bool { candidates.count > 1 }
}

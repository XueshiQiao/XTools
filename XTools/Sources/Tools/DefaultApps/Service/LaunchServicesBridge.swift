import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Thin wrapper over the LaunchServices "default handler" C APIs, isolating the
/// `Unmanaged<…>` / CFString casting and the Copy/Create memory rule in one place.
///
/// All of these run in the USER domain (no sudo) — setting a default handler for a
/// content type or URL scheme only touches the current user's LaunchServices
/// database. Nil-safe throughout: a type may have no handler, and an OS may not
/// expose every API.
///
/// These functions are deprecated by Apple, but there is no public replacement
/// for programmatically *setting* the default app on macOS 13 — the modern
/// `NSWorkspace.setDefaultApplication(at:toOpen:)` only exists on macOS 14+ and
/// this app deploys to 13. So we keep the LaunchServices calls and accept the
/// deprecation warnings (they don't affect correctness on the supported OSes).
enum LaunchServicesBridge {

    private static let log = FileLog("LaunchServices")

    // MARK: - Content types (UTIs)

    /// Current default handler bundle id for a content type, or nil if none.
    static func defaultHandler(forContentType uti: String) -> String? {
        guard let ref = LSCopyDefaultRoleHandlerForContentType(uti as CFString, .all) else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// Every installed app (bundle id) that can handle a content type in any role.
    static func allHandlers(forContentType uti: String) -> [String] {
        guard let ref = LSCopyAllRoleHandlersForContentType(uti as CFString, .all) else { return [] }
        let array = ref.takeRetainedValue() as? [String]
        return array ?? []
    }

    /// Set the default handler for a content type. Returns the OSStatus (0 == ok).
    @discardableResult
    static func setDefaultHandler(forContentType uti: String, bundleID: String) -> OSStatus {
        let status = LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, bundleID as CFString)
        if status != noErr { log.warn("setDefault contentType \(uti) → \(bundleID) failed: \(status)") }
        return status
    }

    // MARK: - URL schemes

    /// Current default handler bundle id for a URL scheme, or nil if none.
    static func defaultHandler(forURLScheme scheme: String) -> String? {
        guard let ref = LSCopyDefaultHandlerForURLScheme(scheme as CFString) else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// Every installed app (bundle id) that declares it can handle a URL scheme.
    ///
    /// `LSCopyAllHandlersForURLScheme` is the (deprecated) symbol that returns the
    /// full candidate list. It isn't part of every SDK's published headers, so we
    /// resolve it dynamically at runtime; if it's unavailable we fall back to just
    /// the current handler (so the row still shows the right app, only without a
    /// full picker).
    static func allHandlers(forURLScheme scheme: String) -> [String] {
        typealias AllHandlersFn = @convention(c) (CFString) -> Unmanaged<CFArray>?
        let symbol = "LSCopyAllHandlersForURLScheme"
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) {  // RTLD_DEFAULT
            let fn = unsafeBitCast(sym, to: AllHandlersFn.self)
            if let ref = fn(scheme as CFString),
               let array = ref.takeRetainedValue() as? [String] {
                return array
            }
        }
        // Fallback: current handler only.
        if let current = defaultHandler(forURLScheme: scheme) { return [current] }
        return []
    }

    /// Set the default handler for a URL scheme. Returns the OSStatus (0 == ok).
    @discardableResult
    static func setDefaultHandler(forURLScheme scheme: String, bundleID: String) -> OSStatus {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
        if status != noErr { log.warn("setDefault urlScheme \(scheme) → \(bundleID) failed: \(status)") }
        return status
    }

    // MARK: - Bundle id → display name + icon

    /// Resolve a bundle id to a presentable `HandlerApp` (display name + icon),
    /// or nil if the app can't be located on disk. Runs disk I/O — call off main.
    static func resolveApp(bundleID: String) -> HandlerApp? {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleID) else {
            // App not installed (a stale registration) — still surface the id so the
            // user can see what's set, just without an icon.
            return HandlerApp(bundleID: bundleID, name: bundleID, url: nil, icon: nil)
        }
        let name = displayName(for: url) ?? url.deletingPathExtension().lastPathComponent
        let icon = ws.icon(forFile: url.path)
        return HandlerApp(bundleID: bundleID, name: name, url: url, icon: icon)
    }

    /// Prefer CFBundleDisplayName, then CFBundleName, from the app's Info.plist.
    private static func displayName(for url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !display.isEmpty {
            return display
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return nil
    }
}

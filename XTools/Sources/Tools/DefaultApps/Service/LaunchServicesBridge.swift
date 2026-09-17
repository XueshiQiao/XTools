import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Thin wrapper over the LaunchServices "default handler" C APIs, isolating the
/// `Unmanaged<…>` / CFString casting and the Copy/Create memory rule in one place.
///
/// READ-ONLY. All of these run in the USER domain (no sudo) and only look things
/// up. Nil-safe throughout: a type may have no handler, and an OS may not expose
/// every API.
///
/// *Setting* a default is deliberately NOT here — it goes through
/// `NSWorkspace.setDefaultApplication(at:toOpen…:completionHandler:)`, whose
/// callback fires only after the user has answered the system's consent alert.
/// The LaunchServices setter returns before that and is why a changed row used to
/// look stale (see `DefaultAppsStore.setHandler`).
///
/// The readers below stay on LaunchServices because they speak **bundle ids**,
/// which is what `HandlerApp` and the whole tool are keyed on; the NSWorkspace
/// equivalents return app URLs, which would just have to be mapped back. They are
/// deprecated symbols, and the deprecation warnings are accepted knowingly.
enum LaunchServicesBridge {

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

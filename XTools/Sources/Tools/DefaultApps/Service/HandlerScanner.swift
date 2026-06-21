import Foundation

/// Resolves the curated catalog into fully-populated `HandledItem`s: for each
/// file type / URL scheme it reads the current default handler and the full
/// candidate list from LaunchServices, then resolves every bundle id to a
/// display name + icon.
///
/// Pure off-main work (disk I/O for icons + LS lookups). App resolution is cached
/// within a single scan so an app that handles many types is resolved only once.
enum HandlerScanner {

    /// Resolve all file-type entries to `HandledItem`s (current + candidates).
    static func scanFileTypes() -> [HandledItem] {
        var cache: [String: HandlerApp] = [:]
        return HandledCatalog.fileTypes.map { entry in
            let currentID = LaunchServicesBridge.defaultHandler(forContentType: entry.identifier)
            let candidateIDs = LaunchServicesBridge.allHandlers(forContentType: entry.identifier)
            return makeItem(entry: entry, currentID: currentID, candidateIDs: candidateIDs, cache: &cache)
        }
    }

    /// Resolve all URL-scheme entries to `HandledItem`s (current + candidates).
    static func scanURLSchemes() -> [HandledItem] {
        var cache: [String: HandlerApp] = [:]
        return HandledCatalog.urlSchemes.map { entry in
            let currentID = LaunchServicesBridge.defaultHandler(forURLScheme: entry.identifier)
            let candidateIDs = LaunchServicesBridge.allHandlers(forURLScheme: entry.identifier)
            return makeItem(entry: entry, currentID: currentID, candidateIDs: candidateIDs, cache: &cache)
        }
    }

    /// Re-resolve a SINGLE catalog entry — used after a change so a row can update
    /// without rescanning the whole catalog (its disk I/O + LS lookups).
    static func scan(_ entry: CatalogEntry) -> HandledItem {
        var cache: [String: HandlerApp] = [:]
        let currentID: String?
        let candidateIDs: [String]
        switch entry.kind {
        case .contentType:
            currentID = LaunchServicesBridge.defaultHandler(forContentType: entry.identifier)
            candidateIDs = LaunchServicesBridge.allHandlers(forContentType: entry.identifier)
        case .urlScheme:
            currentID = LaunchServicesBridge.defaultHandler(forURLScheme: entry.identifier)
            candidateIDs = LaunchServicesBridge.allHandlers(forURLScheme: entry.identifier)
        }
        return makeItem(entry: entry, currentID: currentID, candidateIDs: candidateIDs, cache: &cache)
    }

    // MARK: - Shared

    private static func makeItem(entry: CatalogEntry,
                                 currentID: String?,
                                 candidateIDs: [String],
                                 cache: inout [String: HandlerApp]) -> HandledItem {
        // Union of every candidate plus the current handler (LS sometimes omits
        // the current one from the "all" list), de-duplicated, preserving order.
        var ids = candidateIDs
        if let currentID, !ids.contains(currentID) { ids.insert(currentID, at: 0) }

        var seen = Set<String>()
        let apps: [HandlerApp] = ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            if let cached = cache[id] { return cached }
            let app = LaunchServicesBridge.resolveApp(bundleID: id)
            if let app { cache[id] = app }
            return app
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let current = currentID.flatMap { id in apps.first { $0.bundleID == id } }

        return HandledItem(kind: entry.kind,
                           identifier: entry.identifier,
                           label: L(entry.labelKey),
                           symbol: entry.symbol,
                           current: current,
                           candidates: apps)
    }
}

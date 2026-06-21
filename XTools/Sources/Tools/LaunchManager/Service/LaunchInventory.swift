import Foundation

/// Scans the three well-known launchd directories and parses each plist into a
/// `LaunchItem`. Reads the files directly (they're world-readable) so root
/// daemons are inventoried too, even though their processes can't be inspected.
enum LaunchInventory {

    private static let log = FileLog("LaunchInventory")

    static func scan() -> [LaunchItem] {
        let domains: [LaunchItem.Domain] = [.userAgent, .systemAgent, .systemDaemon]
        var items: [LaunchItem] = []
        for domain in domains {
            items.append(contentsOf: scan(domain: domain))
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func scan(domain: LaunchItem.Domain) -> [LaunchItem] {
        let dir = domain.directory
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { name -> LaunchItem? in
            guard name.hasSuffix(".plist") else { return nil }
            let path = (dir as NSString).appendingPathComponent(name)
            return parse(path: path, domain: domain)
        }
    }

    private static func parse(path: String, domain: LaunchItem.Domain) -> LaunchItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            log.warn("could not parse plist: \(path)")
            return nil
        }

        let label = (dict["Label"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        let programPath: String?
        if let program = dict["Program"] as? String {
            programPath = program
        } else if let args = dict["ProgramArguments"] as? [String], let first = args.first {
            programPath = first
        } else {
            programPath = nil
        }

        let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
        // KeepAlive can be a Bool or a dictionary of conditions; treat any
        // dictionary form as "keeps itself alive" for display purposes.
        let keepAlive: Bool
        if let b = dict["KeepAlive"] as? Bool { keepAlive = b }
        else if dict["KeepAlive"] is [String: Any] { keepAlive = true }
        else { keepAlive = false }

        let programExists = programPath.map { FileManager.default.fileExists(atPath: $0) } ?? true

        return LaunchItem(label: label, plistPath: path, domain: domain,
                          programPath: programPath, runAtLoad: runAtLoad,
                          keepAlive: keepAlive, programExists: programExists)
    }
}

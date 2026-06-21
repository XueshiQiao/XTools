import Foundation

/// Tool-local persistence for Guardian rules (JSON in UserDefaults). Lives in the
/// Launch Manager folder so the tool owns its own state — `Preferences` only
/// holds app-wide settings.
enum GuardianRuleStore {

    private static let key = "launchManager.guardianRules.v1"
    private static let log = FileLog("GuardianRuleStore")

    static func load() -> [GuardianRule] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([GuardianRule].self, from: data)
        } catch {
            log.error("decode failed: \(error)")
            return []
        }
    }

    static func save(_ rules: [GuardianRule]) {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            log.error("encode failed: \(error)")
        }
    }
}

import Foundation

/// Tool-local persistence for the side-button mapping (JSON in UserDefaults),
/// mirroring GuardianRuleStore. Backward-compatible: unknown fields are ignored,
/// decode failure falls back to defaults (never crashes, never silently wipes).
enum NagaMappingStore {

    private static let key = "naga.mapping.v1"
    private static let log = FileLog("NagaMappingStore")

    static func load() -> [ButtonMapping] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return ButtonMapping.defaults }
        do {
            let decoded = try JSONDecoder().decode([ButtonMapping].self, from: data)
            return decoded.isEmpty ? ButtonMapping.defaults : decoded
        } catch {
            log.error("decode failed: \(error)")
            return ButtonMapping.defaults
        }
    }

    static func save(_ mappings: [ButtonMapping]) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(mappings), forKey: key)
        } catch {
            log.error("encode failed: \(error)")
        }
    }
}

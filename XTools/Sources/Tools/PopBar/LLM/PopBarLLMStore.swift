import SwiftUI
import Foundation

/// Owns PopBar's LLM settings: provider / model / base URL / thinking level in
/// UserDefaults, and the API key in the Keychain (never UserDefaults). Shared by
/// the settings UI (edits) and the controller (reads `currentConfig()` per call).
final class PopBarLLMStore: ObservableObject {

    private static let log = FileLog("PopBar.LLM")
    private static let keychain = KeychainStore(service: "me.xueshi.xtools.popbar")
    private static let keyAccount = "llm-api-key"

    private enum Key {
        static let provider = "popbar.llm.provider"
        static let model = "popbar.llm.model"
        static let apiURL = "popbar.llm.apiURL"
        static let effort = "popbar.llm.reasoningEffort"
    }

    @Published private(set) var provider: String
    @Published private(set) var model: String
    @Published private(set) var apiURL: String
    @Published private(set) var reasoningEffort: String
    @Published private(set) var hasKey: Bool

    init() {
        let d = UserDefaults.standard
        let provider = d.string(forKey: Key.provider) ?? "deepseek"
        let defaults = LLMConfig.providerDefaults(provider)
        self.provider = provider
        self.model = d.string(forKey: Key.model) ?? defaults.model
        self.apiURL = d.string(forKey: Key.apiURL) ?? defaults.apiURL
        self.reasoningEffort = LLMConfig.clampThinking(
            d.string(forKey: Key.effort) ?? "none", for: provider)
        self.hasKey = (Self.keychain.get(Self.keyAccount)?.isEmpty == false)
    }

    var thinkingOptions: [(tag: String, label: String)] {
        LLMConfig.thinkingOptions(for: provider)
    }

    // MARK: - Edits (from settings UI)

    /// Switch provider and reset model / base URL / thinking to that provider's
    /// defaults (thinking defaults to off where the provider supports it).
    func setProvider(_ p: String) {
        provider = p
        let defaults = LLMConfig.providerDefaults(p)
        model = defaults.model
        apiURL = defaults.apiURL
        reasoningEffort = LLMConfig.clampThinking("none", for: p)
        persist()
    }

    func setModel(_ m: String) { model = m; persist() }
    func setAPIURL(_ u: String) { apiURL = u; persist() }
    func setReasoningEffort(_ e: String) { reasoningEffort = LLMConfig.clampThinking(e, for: provider); persist() }

    /// Save the API key to the Keychain. Returns an error string on failure.
    @discardableResult
    func saveKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try Self.keychain.set(trimmed, account: Self.keyAccount)
            hasKey = true
            Self.log.info("API key saved to keychain")
            return nil
        } catch {
            Self.log.error("keychain save failed: \(error)")
            return "\(error)"
        }
    }

    func clearKey() {
        Self.keychain.remove(Self.keyAccount)
        hasKey = false
        Self.log.info("API key cleared")
    }

    // MARK: - Read (from controller, per action)

    /// Whether AI actions will hit a real model. Ollama is local and needs no
    /// key; every other provider requires one.
    var isConfigured: Bool { provider == "ollama" || hasKey }

    /// The config for an actual request, or nil if not configured (callers then
    /// fall back to the placeholder service).
    func currentConfig() -> LLMConfig? {
        let key = Self.keychain.get(Self.keyAccount) ?? ""
        guard provider == "ollama" || !key.isEmpty else { return nil }
        return LLMConfig(provider: provider, apiKey: key, apiURL: apiURL,
                         model: model, reasoningEffort: reasoningEffort)
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(provider, forKey: Key.provider)
        d.set(model, forKey: Key.model)
        d.set(apiURL, forKey: Key.apiURL)
        d.set(reasoningEffort, forKey: Key.effort)
    }
}

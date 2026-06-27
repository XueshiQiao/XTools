import SwiftUI
import Foundation

/// The observable model behind the **AI Models** settings page and the app-wide
/// default LLM configuration. Owns the default provider / model / base URL /
/// thinking level (in `UserDefaults`) and, via `LLMKeyStore`, one API key per
/// provider (in the Keychain). This is the app-level One Source of Truth for LLM
/// config — created once and shared by every tool through `LLMService`.
///
/// Main-thread only by convention (SwiftUI `@Published` + settings UI).
final class LLMSettingsStore: ObservableObject {

    private static let log = FileLog("LLM.Settings")
    private let keys = LLMKeyStore()

    private enum Key {
        static let provider = "xtools.llm.provider"
        static let model    = "xtools.llm.model"
        static let apiURL   = "xtools.llm.apiURL"
        static let effort   = "xtools.llm.reasoningEffort"
    }

    @Published private(set) var provider: String
    @Published private(set) var model: String
    @Published private(set) var apiURL: String
    @Published private(set) var reasoningEffort: String
    /// Providers that currently have a key stored (drives the settings UI).
    @Published private(set) var keyedProviders: Set<String> = []

    init() {
        // Bring forward any keys saved under PopBar's old service BEFORE reading
        // state, so the settings page reflects them on first launch.
        LLMKeyStore.migrateFromPopBarIfNeeded()

        let d = UserDefaults.standard
        // Fall back to PopBar's old default keys so the previously-chosen default
        // provider/model carry over on first launch of the app-level store.
        let provider = d.string(forKey: Key.provider)
            ?? d.string(forKey: "popbar.llm.provider")
            ?? "deepseek"
        let defaults = LLMConfig.providerDefaults(provider)
        self.provider = provider
        self.model = d.string(forKey: Key.model) ?? d.string(forKey: "popbar.llm.model") ?? defaults.model
        self.apiURL = d.string(forKey: Key.apiURL) ?? d.string(forKey: "popbar.llm.apiURL") ?? defaults.apiURL
        self.reasoningEffort = LLMConfig.clampThinking(
            d.string(forKey: Key.effort) ?? d.string(forKey: "popbar.llm.reasoningEffort") ?? "none",
            for: provider)
        refreshKeyedProviders()
    }

    // MARK: - Key state

    func hasKey(for provider: String) -> Bool { keyedProviders.contains(provider) }
    var hasKeyForCurrent: Bool { hasKey(for: provider) }

    /// Whether a resolved provider will reach a real model (has a key, or Ollama
    /// which needs none).
    func isConfigured(forProvider p: String) -> Bool {
        p == "ollama" || hasKey(for: p)
    }

    var thinkingOptions: [(tag: String, label: String)] { LLMConfig.thinkingOptions(for: provider) }

    // MARK: - Edits (settings UI)

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

    @discardableResult
    func saveKey(_ key: String, for provider: String) -> String? {
        let error = keys.save(key, for: provider)
        if error == nil { refreshKeyedProviders() }
        return error
    }

    func clearKey(for provider: String) {
        keys.clear(for: provider)
        refreshKeyedProviders()
    }

    // MARK: - Read (resolve a config for a tool)

    /// The default config (default provider / model / URL / effort), or nil when
    /// the default provider has no key (and isn't Ollama) — the caller surfaces a
    /// "set a key" message instead of silently using another model.
    func defaultConfig() -> LLMConfig? {
        makeConfig(provider: provider, model: model, apiURL: apiURL, effort: reasoningEffort)
    }

    /// A config for an explicit provider/model/effort (e.g. a per-action override).
    /// The base URL is the provider's default. nil when that provider has no key.
    func config(provider p: String, model m: String, effort e: String) -> LLMConfig? {
        let url = LLMConfig.providerDefaults(p).apiURL
        return makeConfig(provider: p, model: m, apiURL: url, effort: e)
    }

    private func makeConfig(provider: String, model: String, apiURL: String, effort: String) -> LLMConfig? {
        let key = keys.key(for: provider)
        guard provider == "ollama" || !key.isEmpty else { return nil }
        return LLMConfig(provider: provider, apiKey: key, apiURL: apiURL, model: model, reasoningEffort: effort)
    }

    // MARK: - Internals

    private func refreshKeyedProviders() {
        keyedProviders = keys.keyedProviders()
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(provider, forKey: Key.provider)
        d.set(model, forKey: Key.model)
        d.set(apiURL, forKey: Key.apiURL)
        d.set(reasoningEffort, forKey: Key.effort)
    }
}

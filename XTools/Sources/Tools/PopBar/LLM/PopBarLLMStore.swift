import SwiftUI
import Foundation

/// Owns PopBar's LLM settings: the default provider / model / base URL / thinking
/// level in UserDefaults, and **one API key per provider** in the Keychain
/// (account `llm-key-<provider>`), so any action can target any provider you've
/// configured. Shared by the settings UI (edits) and the controller (resolves a
/// config per action, honoring an optional per-action model override).
final class PopBarLLMStore: ObservableObject {

    private static let log = FileLog("PopBar.LLM")
    private static let keychain = KeychainStore(service: "me.xueshi.xtools.popbar")
    private static func keyAccount(_ provider: String) -> String { "llm-key-\(provider)" }
    private static let legacyKeyAccount = "llm-api-key"
    private static let migrationFlag = "popbar.llm.keyMigratedV2"

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
    /// Providers that currently have a key stored (drives the settings UI).
    @Published private(set) var keyedProviders: Set<String> = []

    init() {
        let d = UserDefaults.standard
        let provider = d.string(forKey: Key.provider) ?? "deepseek"
        let defaults = LLMConfig.providerDefaults(provider)
        self.provider = provider
        self.model = d.string(forKey: Key.model) ?? defaults.model
        self.apiURL = d.string(forKey: Key.apiURL) ?? defaults.apiURL
        self.reasoningEffort = LLMConfig.clampThinking(d.string(forKey: Key.effort) ?? "none", for: provider)
        migrateLegacyKeyIfNeeded(defaultProvider: provider)
        refreshKeyedProviders()
    }

    // MARK: - Key state

    func hasKey(for provider: String) -> Bool { keyedProviders.contains(provider) }
    var hasKeyForCurrent: Bool { hasKey(for: provider) }

    /// Whether an action (with optional override) will reach a real model.
    func isConfigured(for override: ModelOverride?) -> Bool {
        let p = override?.provider ?? provider
        return p == "ollama" || hasKey(for: p)
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
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try Self.keychain.set(trimmed, account: Self.keyAccount(provider))
            refreshKeyedProviders()
            Self.log.info("API key saved for \(provider)")
            return nil
        } catch {
            Self.log.error("keychain save failed: \(error)")
            return "\(error)"
        }
    }

    func clearKey(for provider: String) {
        Self.keychain.remove(Self.keyAccount(provider))
        refreshKeyedProviders()
        Self.log.info("API key cleared for \(provider)")
    }

    // MARK: - Read (controller, per action)

    /// The config for an action's optional override, or the default. Returns nil
    /// when the resolved provider has no key (and isn't Ollama) — the caller then
    /// surfaces a "set a key" message instead of silently using another model.
    func config(for override: ModelOverride?) -> LLMConfig? {
        if let o = override {
            let url = LLMConfig.providerDefaults(o.provider).apiURL
            return makeConfig(provider: o.provider, model: o.model, apiURL: url, effort: o.reasoningEffort)
        }
        return makeConfig(provider: provider, model: model, apiURL: apiURL, effort: reasoningEffort)
    }

    private func makeConfig(provider: String, model: String, apiURL: String, effort: String) -> LLMConfig? {
        let key = Self.keychain.get(Self.keyAccount(provider)) ?? ""
        guard provider == "ollama" || !key.isEmpty else { return nil }
        return LLMConfig(provider: provider, apiKey: key, apiURL: apiURL, model: model, reasoningEffort: effort)
    }

    // MARK: - Internals

    private func refreshKeyedProviders() {
        var set = Set<String>()
        for p in LLMConfig.providers where (Self.keychain.get(Self.keyAccount(p))?.isEmpty == false) {
            set.insert(p)
        }
        keyedProviders = set
    }

    /// One-shot: move the old single-key entry to the per-provider scheme.
    private func migrateLegacyKeyIfNeeded(defaultProvider: String) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.migrationFlag) else { return }
        if let legacy = Self.keychain.get(Self.legacyKeyAccount), !legacy.isEmpty {
            try? Self.keychain.set(legacy, account: Self.keyAccount(defaultProvider))
            Self.keychain.remove(Self.legacyKeyAccount)
            Self.log.info("migrated legacy LLM key → \(defaultProvider)")
        }
        d.set(true, forKey: Self.migrationFlag)
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(provider, forKey: Key.provider)
        d.set(model, forKey: Key.model)
        d.set(apiURL, forKey: Key.apiURL)
        d.set(reasoningEffort, forKey: Key.effort)
    }
}

import SwiftUI
import Foundation
import Combine

/// The app-level shared LLM facade. ONE instance is created by `AppState` at
/// launch and injected into any tool that needs a model, so the LLM capability is
/// no longer owned by a single tool. Tools call `complete`/`stream` with a resolved
/// `LLMConfig`, or ask the service to resolve one for them via `defaultConfig()` /
/// `config(forProvider:model:effort:)`.
///
/// The configuration (providers, keys, default model, thinking level) lives in the
/// observable `settings` store, which also backs the **AI Models** settings page —
/// so a settings change propagates to every consumer automatically. `LLMService`
/// itself is observable (it republishes `settings`) so SwiftUI views observing the
/// service stay in sync.
///
/// Main-thread only by convention (matches the rest of the SwiftUI/AppKit layer);
/// the actual network calls run off-main inside `LLMClient`.
final class LLMService: ObservableObject {

    /// The observable settings model (default config + per-provider keys). Backs the
    /// AI Models page; tools read it to resolve configs and check key presence.
    let settings: LLMSettingsStore

    private var settingsObserver: AnyCancellable?

    init(settings: LLMSettingsStore = LLMSettingsStore()) {
        self.settings = settings
        // Republish the nested store's changes so views observing `LLMService`
        // (e.g. PopBar's action tags) refresh when keys/default model change.
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Config resolution (for tools)

    /// The app-wide default config, or nil when the default provider has no key.
    func defaultConfig() -> LLMConfig? { settings.defaultConfig() }

    /// A config for an explicit provider/model/effort (per-action override). nil
    /// when that provider has no key (and isn't Ollama).
    func config(forProvider provider: String, model: String, effort: String) -> LLMConfig? {
        settings.config(provider: provider, model: model, effort: effort)
    }

    /// Whether a given provider is configured (has a key, or is Ollama).
    func isConfigured(forProvider provider: String) -> Bool {
        settings.isConfigured(forProvider: provider)
    }

    // MARK: - Inference

    /// One-shot completion: system + user → assistant text.
    func complete(_ config: LLMConfig, system: String, user: String) async throws -> String {
        try await LLMClient(config: config).complete(system: system, user: user)
    }

    /// Streaming completion: deltas (displayed text so far) arrive via `onDelta`;
    /// the final stripped + trimmed text is returned. Honors `Task` cancellation.
    @discardableResult
    func stream(_ config: LLMConfig, system: String, user: String,
                onDelta: @escaping (String) -> Void) async throws -> String {
        try await LLMClient(config: config).stream(system: system, user: user, onDelta: onDelta)
    }
}

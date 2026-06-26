import SwiftUI

/// An AI transform, backed by a real LLM (`ActionRegistry` routes these through
/// `LLMClient` when a key is configured, else `FakeAIService`).
enum AITransform: String, CaseIterable {
    case translate
    case polish
    case explain
}

/// What an action does when tapped.
enum PopBarActionKind {
    /// Real, local, instant: write the selection to the clipboard.
    case copy
    /// AI transform (real model when configured, otherwise placeholder).
    case aiTransform(AITransform)
}

/// One button in the capsule. Data-driven so the set is trivially customizable.
struct PopBarAction: Identifiable {
    let id: String
    /// Localization key for the button label / tooltip.
    let titleKey: String
    /// SF Symbol shown on the button.
    let symbol: String
    let kind: PopBarActionKind

    var title: String { L(titleKey) }

    /// Real (local or deterministic) vs. AI-backed — drives the REAL/DEMO tag in
    /// settings. `copy` and `pinyin` are always real; AI actions are real only
    /// once a model key is configured (decided at run time).
    var isLocal: Bool {
        switch kind {
        case .copy:        return true
        case .aiTransform: return false
        }
    }
}

/// The result of running an action.
enum PopBarActionOutcome {
    /// Close the popup (e.g. after Copy).
    case dismiss
    /// Replace the capsule's buttons with a result panel showing this text.
    case showResult(String)
}

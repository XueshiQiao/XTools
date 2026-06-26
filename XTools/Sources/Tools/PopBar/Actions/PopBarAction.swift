import SwiftUI

/// A fake AI transform. Wired to `FakeAIService` for now; replacing that one
/// service with a real model call is the only change needed to go live.
enum AITransform: String, CaseIterable {
    case translate
    case polish
    case explain
}

/// What an action does when tapped.
enum PopBarActionKind {
    /// Real, no model needed: write the selection to the clipboard.
    case copy
    /// Fake (for now): run an AI transform and show the result in the popup.
    case aiTransform(AITransform)
}

/// One button in the capsule. Data-driven so the set is trivially customizable.
struct PopBarAction: Identifiable {
    let id: String
    /// Localization key for the button's accessibility label / tooltip.
    let titleKey: String
    /// SF Symbol shown on the button.
    let symbol: String
    let kind: PopBarActionKind

    var title: String { L(titleKey) }
}

/// The result of running an action.
enum PopBarActionOutcome {
    /// Close the popup (e.g. after Copy).
    case dismiss
    /// Replace the capsule's buttons with a result panel showing this text.
    case showResult(String)
}

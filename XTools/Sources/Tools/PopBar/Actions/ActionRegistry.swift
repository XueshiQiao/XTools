import AppKit

/// The set of capsule buttons and how each one runs. The default list is the
/// single source of truth for "which buttons exist"; making them user-
/// configurable later means persisting an ordered subset of these ids.
enum ActionRegistry {

    private static let log = FileLog("PopBar.Action")
    private static let ai = FakeAIService()

    /// The built-in actions, in display order. Copy is real; the rest are fake AI.
    static let defaults: [PopBarAction] = [
        PopBarAction(id: "copy",      titleKey: "popbar.action.copy",      symbol: "doc.on.doc",            kind: .copy),
        PopBarAction(id: "translate", titleKey: "popbar.action.translate", symbol: "character.bubble",      kind: .aiTransform(.translate)),
        PopBarAction(id: "polish",    titleKey: "popbar.action.polish",    symbol: "wand.and.stars",        kind: .aiTransform(.polish)),
        PopBarAction(id: "explain",   titleKey: "popbar.action.explain",   symbol: "lightbulb",             kind: .aiTransform(.explain)),
    ]

    /// Run an action against the selected text.
    static func run(_ action: PopBarAction, on text: String) async -> PopBarActionOutcome {
        log.debug("run action \(action.id) on \(text.count) char(s)")
        switch action.kind {
        case .copy:
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return .dismiss
        case .aiTransform(let transform):
            let output = await ai.transform(transform, text: text)
            return .showResult(output)
        }
    }
}

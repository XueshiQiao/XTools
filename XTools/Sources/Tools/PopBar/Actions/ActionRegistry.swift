import AppKit

/// The set of capsule buttons and how each one runs. The default list is the
/// single source of truth for "which buttons exist"; making them user-
/// configurable later means persisting an ordered subset of these ids.
enum ActionRegistry {

    private static let log = FileLog("PopBar.Action")
    private static let fake = FakeAIService()

    /// The built-in actions, in display order. The AI actions come first (real
    /// once a model key is configured, else placeholder); Copy — real & local —
    /// sits at the end.
    static let defaults: [PopBarAction] = [
        PopBarAction(id: "translate", titleKey: "popbar.action.translate", symbol: "character.bubble", kind: .aiTransform(.translate)),
        PopBarAction(id: "polish",    titleKey: "popbar.action.polish",    symbol: "wand.and.stars",   kind: .aiTransform(.polish)),
        PopBarAction(id: "explain",   titleKey: "popbar.action.explain",   symbol: "lightbulb",        kind: .aiTransform(.explain)),
        PopBarAction(id: "copy",      titleKey: "popbar.action.copy",      symbol: "doc.on.doc",       kind: .copy),
    ]

    /// Run an action against the selected text. `llm` is the active model config
    /// (nil when no key is set → AI actions use the placeholder service).
    static func run(_ action: PopBarAction, on text: String, llm: LLMConfig?) async -> PopBarActionOutcome {
        log.debug("run action \(action.id) on \(text.count) char(s)")
        switch action.kind {
        case .copy:
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return .dismiss

        case .aiTransform(let transform):
            guard let llm else {
                return .showResult(await fake.transform(transform, text: text))
            }
            do {
                let output = try await LLMClient(config: llm).complete(
                    system: Prompts.system(for: transform), user: text)
                return .showResult(output.isEmpty ? L("popbar.error.empty") : output)
            } catch {
                log.error("LLM \(action.id) failed: \(error.localizedDescription)")
                return .showResult("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
        }
    }
}

import AppKit

/// Runs a configured action against the selected text. The controller resolves
/// the model config (default or per-action override) and passes it in; a nil
/// `llm` for an AI action means "no API key for that provider" → a clear,
/// actionable message rather than a silent fallback (per the design review).
enum ActionRegistry {

    private static let log = FileLog("PopBar.Action")

    static func run(_ action: PopBarActionConfig, on text: String, llm: LLMConfig?) async -> PopBarActionOutcome {
        log.debug("run action '\(action.title)' (\(action.kind.rawValue)) on \(text.count) char(s)")
        switch action.kind {
        case .copy:
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return .dismiss

        case .ai:
            guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .showResult("⚠️ \(L("popbar.error.noprompt"))")
            }
            guard let llm else {
                return .showResult("⚠️ \(L("popbar.error.nokey"))")
            }
            do {
                let output = try await LLMClient(config: llm).complete(system: action.prompt, user: text)
                return .showResult(output.isEmpty ? L("popbar.error.empty") : output)
            } catch {
                log.error("LLM '\(action.title)' failed: \(error.localizedDescription)")
                return .showResult("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
        }
    }
}

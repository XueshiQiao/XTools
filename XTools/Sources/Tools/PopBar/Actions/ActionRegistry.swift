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

    /// Streaming variant for AI actions: deltas (displayed text so far) arrive via
    /// `onDelta` as they're produced, then the final outcome is returned. Non-AI
    /// and unconfigured cases are identical to `run` (no stream to drive). If the
    /// stream fails to *start* (e.g. provider/proxy doesn't support SSE), this
    /// falls back to the one-shot `complete()` path so behavior never regresses.
    /// `onDelta` is always called on the same actor as the awaiting caller.
    static func runStreaming(
        _ action: PopBarActionConfig,
        on text: String,
        llm: LLMConfig?,
        onDelta: @escaping (String) -> Void
    ) async -> PopBarActionOutcome {
        guard action.kind == .ai else { return await run(action, on: text, llm: llm) }

        log.debug("stream action '\(action.title)' on \(text.count) char(s)")
        guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .showResult("⚠️ \(L("popbar.error.noprompt"))")
        }
        guard let llm else {
            return .showResult("⚠️ \(L("popbar.error.nokey"))")
        }

        let client = LLMClient(config: llm)
        // Track whether any token reached the UI: a failure AFTER content is shown
        // must NOT silently re-run the one-shot path (double charge + lost partial).
        let emitted = StreamProgress()
        do {
            let output = try await client.stream(system: action.prompt, user: text) { displayed in
                if !displayed.isEmpty { emitted.didEmit = true }
                onDelta(displayed)
            }
            return .showResult(output.isEmpty ? L("popbar.error.empty") : output)
        } catch is CancellationError {
            return .dismiss   // re-triggered / panel closed — drop silently
        } catch {
            // `URLSession.bytes` surfaces task cancellation as `URLError.cancelled`,
            // NOT `CancellationError` — treat both as a silent dismiss so a canceled
            // stream never spawns a second (paid) one-shot request.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .dismiss }
            // Fall back to the proven one-shot path ONLY if nothing streamed yet
            // (e.g. a provider/proxy that doesn't support SSE). Once partial output
            // has been shown, surface the error rather than restarting the request.
            guard !emitted.didEmit else {
                log.error("LLM stream '\(action.title)' failed mid-stream: \(error.localizedDescription)")
                return .showResult("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
            log.error("LLM stream '\(action.title)' failed to start: \(error.localizedDescription) — falling back to one-shot")
            do {
                let output = try await client.complete(system: action.prompt, user: text)
                return .showResult(output.isEmpty ? L("popbar.error.empty") : output)
            } catch is CancellationError {
                return .dismiss
            } catch let fallbackError {
                log.error("LLM one-shot fallback '\(action.title)' failed: \(fallbackError.localizedDescription)")
                return .showResult("⚠️ \(L("popbar.error.prefix"))\n\n\(fallbackError.localizedDescription)")
            }
        }
    }

    /// Tiny reference box so the escaping `onDelta` closure can flip a flag the
    /// surrounding async function reads after the stream ends (value-type capture
    /// wouldn't propagate the mutation back).
    private final class StreamProgress { var didEmit = false }
}

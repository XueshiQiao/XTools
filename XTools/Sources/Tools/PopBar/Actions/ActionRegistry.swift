import AppKit

/// Runs a configured action against the selected text and produces a
/// `PopBarPresentation` — the single seam between "what an action does" and "how its
/// output is shown". The session resolves the model config (default or per-action
/// override) via the shared `LLMService` and passes both in; a nil `config` for an
/// AI action means "no API key for that provider" → a clear, actionable message. The
/// actual inference goes through `LLMService`, the app-level facade.
enum ActionRegistry {

    private static let log = FileLog("PopBar.Action")

    static func run(_ action: PopBarActionConfig, on text: String, url: URL?,
                    service: LLMService?, config: LLMConfig?) async -> PopBarPresentation {
        // Written by a newer XTools (see `PopBarActionConfig.unsupportedKindRaw`).
        // Say so plainly — the alternative is running it as the empty AI action it
        // decoded to, which produces a baffling "no prompt" error for something the
        // user never configured as a prompt.
        guard !action.isUnsupported else {
            log.info("action '\(action.title)' needs a newer XTools — not run")
            return .result("⚠️ \(L("popbar.error.unsupported"))")
        }
        log.debug("run action '\(action.title)' (\(action.kind.rawValue)) on \(text.count) char(s)")
        switch action.kind {
        case .copy:
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return .none

        case .webPreview:
            return webPreviewPresentation(url: url, text: text)

        case .quickLook:
            return pathPresentation(text: text, forceFinder: false)

        case .revealInFinder:
            return pathPresentation(text: text, forceFinder: true)

        case .ai:
            guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .result("⚠️ \(L("popbar.error.noprompt"))")
            }
            guard let service, let config else {
                return .result("⚠️ \(L("popbar.error.nokey"))")
            }
            do {
                let output = try await service.complete(config, system: action.prompt, user: text)
                return .result(output.isEmpty ? L("popbar.error.empty") : output)
            } catch {
                log.error("LLM '\(action.title)' failed: \(error.localizedDescription)")
                return .result("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
        }
    }

    /// The web-preview action's presentation: the resolved link if any; otherwise the
    /// opt-in fallback search of the selected text; otherwise a "no link" message.
    private static func webPreviewPresentation(url: URL?, text: String) -> PopBarPresentation {
        if let url { return .webPreview(url) }
        if PopBarPreferences.previewFallbackToSearch, let search = PreviewSearch.searchURL(for: text) {
            log.debug("web preview: no link in selection → fallback web search")
            return .webPreview(search)
        }
        log.debug("web preview: no link in selection and fallback search off → message")
        return .result("⚠️ \(L("popbar.error.nolink"))")
    }

    /// Both path actions resolve the selection the same way and differ only in what
    /// they do with a FILE — Quick Look it, or reveal it in Finder. A FOLDER has no
    /// Quick Look preview at all, so "Preview" on one opens it in Finder: the useful
    /// outcome rather than an error the user can do nothing with.
    ///
    /// Resolution happens here, lazily, when the action is actually tapped. It's a
    /// single `stat` on text we already hold, so unlike link resolution there's
    /// nothing to pre-compute at trigger time and nothing to plumb through the
    /// selection layer.
    private static func pathPresentation(text: String, forceFinder: Bool) -> PopBarPresentation {
        guard let target = PathResolver.resolve(text) else {
            // Privacy: never log the selection itself — it can be anything.
            log.debug("path action: selection (\(text.count) chars) is not an existing local path")
            return .result("⚠️ \(L("popbar.error.nopath"))")
        }
        if forceFinder || target.isDirectory {
            log.debug("path action → Finder (isDirectory=\(target.isDirectory))")
            return .revealInFinder(target.url, isDirectory: target.isDirectory)
        }
        log.debug("path action → Quick Look")
        return .quickLook(target.url)
    }

    /// Streaming variant for AI actions: deltas (displayed text so far) arrive via
    /// `onDelta` as they're produced, then the final presentation is returned. Non-AI
    /// cases are identical to `run` (no stream to drive). If the stream fails to
    /// *start* (e.g. provider/proxy doesn't support SSE), this falls back to the
    /// one-shot `complete()` path so behavior never regresses. `onDelta` is always
    /// called on the same actor as the awaiting caller.
    static func runStreaming(
        _ action: PopBarActionConfig,
        on text: String,
        url: URL?,
        service: LLMService?,
        config: LLMConfig?,
        onDelta: @escaping (String) -> Void
    ) async -> PopBarPresentation {
        guard action.kind == .ai else {
            return await run(action, on: text, url: url, service: service, config: config)
        }

        log.debug("stream action '\(action.title)' on \(text.count) char(s)")
        guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result("⚠️ \(L("popbar.error.noprompt"))")
        }
        guard let service, let config else {
            return .result("⚠️ \(L("popbar.error.nokey"))")
        }

        // Track whether any token reached the UI: a failure AFTER content is shown
        // must NOT silently re-run the one-shot path (double charge + lost partial).
        let emitted = StreamProgress()
        do {
            let output = try await service.stream(config, system: action.prompt, user: text) { displayed in
                if !displayed.isEmpty { emitted.didEmit = true }
                onDelta(displayed)
            }
            return .result(output.isEmpty ? L("popbar.error.empty") : output)
        } catch is CancellationError {
            return .none   // re-triggered / panel closed — drop silently
        } catch {
            // `URLSession.bytes` surfaces task cancellation as `URLError.cancelled`,
            // NOT `CancellationError` — treat both as a silent dismiss so a canceled
            // stream never spawns a second (paid) one-shot request.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .none }
            // Fall back to the proven one-shot path ONLY if nothing streamed yet
            // (e.g. a provider/proxy that doesn't support SSE). Once partial output
            // has been shown, surface the error rather than restarting the request.
            guard !emitted.didEmit else {
                log.error("LLM stream '\(action.title)' failed mid-stream: \(error.localizedDescription)")
                return .result("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
            log.error("LLM stream '\(action.title)' failed to start: \(error.localizedDescription) — falling back to one-shot")
            do {
                let output = try await service.complete(config, system: action.prompt, user: text)
                return .result(output.isEmpty ? L("popbar.error.empty") : output)
            } catch is CancellationError {
                return .none
            } catch let fallbackError {
                log.error("LLM one-shot fallback '\(action.title)' failed: \(fallbackError.localizedDescription)")
                return .result("⚠️ \(L("popbar.error.prefix"))\n\n\(fallbackError.localizedDescription)")
            }
        }
    }

    /// Tiny reference box so the escaping `onDelta` closure can flip a flag the
    /// surrounding async function reads after the stream ends (value-type capture
    /// wouldn't propagate the mutation back).
    private final class StreamProgress { var didEmit = false }
}

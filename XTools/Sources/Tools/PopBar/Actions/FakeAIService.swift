import Foundation

/// Stand-in for a real AI backend. Returns plausible-looking placeholder text so
/// the full select → action → result loop is exercisable end-to-end before any
/// model is wired up. Swap this for a real Claude API call later — the call site
/// (`ActionRegistry.run`) and everything above it stays the same.
struct FakeAIService {

    /// Simulated round-trip latency so the popup's loading state is visible.
    private let latency: TimeInterval = 0.35

    func transform(_ transform: AITransform, text: String) async -> String {
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))

        let snippet = text.count > 60 ? String(text.prefix(60)) + "…" : text
        switch transform {
        case .translate:
            return "🌐 \(L("popbar.fake.translate"))\n\n“\(snippet)”\n\n\(L("popbar.fake.note"))"
        case .polish:
            return "✨ \(L("popbar.fake.polish"))\n\n“\(snippet)”\n\n\(L("popbar.fake.note"))"
        case .explain:
            return "💡 \(L("popbar.fake.explain"))\n\n“\(snippet)”\n\n\(L("popbar.fake.note"))"
        }
    }
}

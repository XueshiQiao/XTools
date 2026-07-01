import Foundation

/// What running an action *presents* — the open-ended output axis. An action's job
/// is to produce one of these; the session's `present(_:)` routes each case to its
/// surface (nothing / the result panel / the web-preview window). Adding a future
/// output type (e.g. `case markdownPreview(String)`, `case image(URL)`) is a new
/// case here + one routing branch — the action-execution and selection layers don't
/// change.
enum PopBarPresentation {
    /// No UI — just dismiss (e.g. Copy).
    case none
    /// A text/Markdown result page in the popup panel (AI output, error messages).
    case result(String)
    /// The selection's associated link, in the floating mini-browser.
    case webPreview(URL)
}

/// Optional per-action model override. The API key is resolved per-provider from
/// the Keychain, so an override only names provider / model / thinking — you set
/// each provider's key once in settings and any action can use it.
struct ModelOverride: Codable, Equatable {
    var provider: String
    var model: String
    var reasoningEffort: String
}

/// A user-configurable capsule action, persisted as JSON. The list is fully
/// editable (add / edit / delete / reorder); the defaults below are just the
/// initial seed.
struct PopBarActionConfig: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case copy         // local: write the selection to the clipboard
        case ai           // send `prompt` + the selection to a model
        case webPreview   // local: open the selection's associated link in the mini-browser
    }

    var schemaVersion: Int
    var id: String
    var title: String
    var iconSymbol: String
    var kind: Kind
    /// System prompt (used when `kind == .ai`).
    var prompt: String
    /// nil = use the global default model.
    var modelOverride: ModelOverride?

    init(id: String = UUID().uuidString, title: String, iconSymbol: String,
         kind: Kind, prompt: String = "", modelOverride: ModelOverride? = nil) {
        self.schemaVersion = 1
        self.id = id
        self.title = title
        self.iconSymbol = iconSymbol
        self.kind = kind
        self.prompt = prompt
        self.modelOverride = modelOverride
    }

    /// Runs entirely on-device (no LLM) — Copy and Web Preview. Drives the "REAL" tag.
    var isLocal: Bool { kind == .copy || kind == .webPreview }
    var isAI: Bool { kind == .ai }
    var isWebPreview: Bool { kind == .webPreview }

    // Forward-compatible decode: tolerate older/newer payloads missing fields.
    enum CodingKeys: String, CodingKey { case schemaVersion, id, title, iconSymbol, kind, prompt, modelOverride }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        iconSymbol = (try? c.decode(String.self, forKey: .iconSymbol)) ?? "sparkles"
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .ai
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        modelOverride = try? c.decodeIfPresent(ModelOverride.self, forKey: .modelOverride)
    }
}

/// Default system prompts + the seed action set (localized titles at seed time;
/// thereafter they are user-editable free text).
enum DefaultActions {

    static let translatePrompt = """
    You are a translation engine. Detect the language of the user's text: if it is \
    Chinese, translate it into natural English; otherwise translate it into natural \
    Simplified Chinese. Output ONLY the translation, with no quotes, labels, or explanation.
    """

    static let polishPrompt = """
    You are a writing editor. Rewrite the user's text to be clearer, more fluent and \
    natural, preserving its original language and meaning. Output ONLY the polished \
    text, with no quotes, labels, or explanation.
    """

    static let explainPrompt = """
    You are a concise explainer. Explain the meaning of the user's selected text (and \
    any notable terms or context) in 2-4 sentences. Respond in the same language as \
    the text. Output ONLY the explanation.
    """

    static func seed() -> [PopBarActionConfig] {
        [
            PopBarActionConfig(title: L("popbar.action.translate"), iconSymbol: "character.bubble",
                               kind: .ai, prompt: translatePrompt),
            PopBarActionConfig(title: L("popbar.action.polish"), iconSymbol: "wand.and.stars",
                               kind: .ai, prompt: polishPrompt),
            PopBarActionConfig(title: L("popbar.action.explain"), iconSymbol: "lightbulb",
                               kind: .ai, prompt: explainPrompt),
            webPreviewAction(),
            PopBarActionConfig(title: L("popbar.action.copy"), iconSymbol: "doc.on.doc",
                               kind: .copy),
        ]
    }

    /// The seed / migration "Web Preview" action.
    static func webPreviewAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("popbar.action.webpreview"), iconSymbol: "safari", kind: .webPreview)
    }
}

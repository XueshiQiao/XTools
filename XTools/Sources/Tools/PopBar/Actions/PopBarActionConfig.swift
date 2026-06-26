import Foundation

/// The result of running an action.
enum PopBarActionOutcome {
    case dismiss
    case showResult(String)
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
        case copy   // local: write the selection to the clipboard
        case ai     // send `prompt` + the selection to a model
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

    var isLocal: Bool { kind == .copy }
    var isAI: Bool { kind == .ai }

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
            PopBarActionConfig(title: L("popbar.action.copy"), iconSymbol: "doc.on.doc",
                               kind: .copy),
        ]
    }
}

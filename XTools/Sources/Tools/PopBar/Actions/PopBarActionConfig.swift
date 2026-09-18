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
    /// A local file, in the floating Quick Look window.
    case quickLook(URL)
    /// A local path, shown in Finder. A folder opens in place; a file is revealed
    /// and selected inside its parent — two different `NSWorkspace` calls, so the
    /// flag is carried here rather than re-checked on disk at present time.
    case revealInFinder(URL, isDirectory: Bool)
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
        case copy           // local: write the selection to the clipboard
        case ai             // send `prompt` + the selection to a model
        case webPreview     // local: open the selection's associated link in the mini-browser
        case quickLook      // local: Quick Look the selected path (folders open in Finder)
        case revealInFinder // local: show the selected path in Finder
        /// A GROUP: runs nothing itself, it only holds `children`. On the wheel it
        /// unfolds a second ring; in the capsule (which has no second row) its
        /// children are shown inline in its place, so nothing becomes unreachable.
        case group
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

    /// Sub-actions, shown on the wheel's second ring when this one is hovered.
    /// Empty = an ordinary action.
    ///
    /// Exactly ONE level deep, by design and by enforcement: a child's own
    /// children are dropped on decode. The wheel can draw two rings and no more, so
    /// a deeper file (hand-edited, or written by some future build) degrades to
    /// something this UI can actually show instead of silently hiding actions.
    var children: [PopBarActionConfig] = []

    /// A group: it holds sub-actions instead of doing anything itself.
    var hasChildren: Bool { !children.isEmpty }

    /// The literal `kind` string from disk when THIS build does not recognise it —
    /// i.e. the action was written by a newer XTools. Nil for every kind this
    /// build understands.
    ///
    /// It exists so an older build cannot destroy a newer one's actions. The
    /// released app and a dev build read the SAME `popbar-actions.json` (it is not
    /// scoped by bundle id), so the older one routinely loads kinds it has never
    /// heard of. Decoding those as `.ai` is fine — there is nothing else it could
    /// do — but the *synthesised* encoder would then write `"kind":"ai"` back on
    /// the very next save, so reordering or editing an unrelated action would
    /// silently and permanently rewrite the newer ones. Round-tripping the
    /// original string means a save leaves them exactly as they were found.
    private var unsupportedKindRaw: String?

    /// Written by a newer XTools than this one, so it cannot be run here.
    var isUnsupported: Bool { unsupportedKindRaw != nil }

    init(id: String = UUID().uuidString, title: String, iconSymbol: String,
         kind: Kind, prompt: String = "", modelOverride: ModelOverride? = nil) {
        self.schemaVersion = 1
        self.id = id
        self.title = title
        self.iconSymbol = iconSymbol
        self.kind = kind
        self.prompt = prompt
        self.modelOverride = modelOverride
        self.unsupportedKindRaw = nil
    }

    /// Runs entirely on-device (no LLM). Drives the "REAL" tag. A group runs
    /// nothing at all, so it is not "local" either.
    var isLocal: Bool { kind != .ai && kind != .group && !isUnsupported }
    /// An unsupported action decodes as `.ai`, but it must not be RUN as one —
    /// it has no prompt and was never meant for the model.
    var isAI: Bool { kind == .ai && !isUnsupported }
    var isWebPreview: Bool { kind == .webPreview }
    /// Acts on a local file/folder named by the selection (`PathResolver`).
    var isPathAction: Bool { kind == .quickLook || kind == .revealInFinder }

    // Forward-compatible decode: tolerate older/newer payloads missing fields.
    enum CodingKeys: String, CodingKey { case schemaVersion, id, title, iconSymbol, kind, prompt, modelOverride, children }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        iconSymbol = (try? c.decode(String.self, forKey: .iconSymbol)) ?? "sparkles"
        let rawKind = try? c.decode(String.self, forKey: .kind)
        let knownKind = rawKind.flatMap(Kind.init(rawValue:))
        kind = knownKind ?? .ai
        // Only a kind that was PRESENT but unreadable came from a newer build. A
        // MISSING one is just an old or partial record, and stays a plain AI
        // action exactly as it always did.
        unsupportedKindRaw = (knownKind == nil) ? rawKind : nil
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        modelOverride = try? c.decodeIfPresent(ModelOverride.self, forKey: .modelOverride)
        // Flatten anything deeper than one level (see `children`). Decoding is
        // deliberately lenient here for the same reason every other field is: a
        // malformed children array must not throw away the whole action list.
        let decodedChildren = (try? c.decode([PopBarActionConfig].self, forKey: .children)) ?? []
        children = decodedChildren.map { child in
            var flat = child
            flat.children = []
            return flat
        }
    }

    /// Hand-written ONLY so `kind` can round-trip a value this build does not
    /// recognise (see `unsupportedKindRaw`). Every other field is encoded exactly
    /// as the synthesised version would.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(iconSymbol, forKey: .iconSymbol)
        try c.encode(unsupportedKindRaw ?? kind.rawValue, forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(modelOverride, forKey: .modelOverride)
        // Only written when there is something to write, so every existing
        // `popbar-actions.json` round-trips byte-for-byte through this build.
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    /// The capsule presentation has a single row and no second level, so a group
    /// is shown as its children, inline, in its own place. Flattening (rather than
    /// hiding the group) is what guarantees an action a user filed into a group
    /// is still reachable in capsule mode.
    static func flattenedForCapsule(_ actions: [PopBarActionConfig]) -> [PopBarActionConfig] {
        actions.flatMap { $0.hasChildren ? $0.children : [$0] }
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
            quickLookAction(),
            revealInFinderAction(),
            PopBarActionConfig(title: L("popbar.action.copy"), iconSymbol: "doc.on.doc",
                               kind: .copy),
        ]
    }

    /// The seed / migration "Web Preview" action.
    static func webPreviewAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("popbar.action.webpreview"), iconSymbol: "safari", kind: .webPreview)
    }

    /// The seed / migration "Preview" action (Quick Look a selected path).
    static func quickLookAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("popbar.action.quicklook"), iconSymbol: "eye", kind: .quickLook)
    }

    /// The seed / migration "Show in Finder" action.
    static func revealInFinderAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("popbar.action.reveal"), iconSymbol: "folder", kind: .revealInFinder)
    }
}

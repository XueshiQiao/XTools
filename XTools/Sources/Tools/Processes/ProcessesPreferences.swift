import Foundation

/// How often the metrics layer samples. The cost is real and measured, so this is
/// a knob the user owns rather than a constant only a developer can change:
/// a long-lived `top -l 0` costs ~7.6% of one core at 2s and ~3.0% at 5s
/// (Activity Monitor itself costs ~1.0%). Default 5s.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case fast = 2
    case normal = 5
    case slow = 10

    var id: Int { rawValue }
    var seconds: Int { rawValue }

    var label: String {
        switch self {
        case .fast:   return L("processes.interval.fast")
        case .normal: return L("processes.interval.normal")
        case .slow:   return L("processes.interval.slow")
        }
    }
}

/// Whether the command-line arguments of a process go to the model.
///
/// argv is what makes an explanation good (`/usr/libexec/UserEventAgent (System)`
/// — without the argument the model is guessing), and it is also where real
/// secrets live (`--api-key=sk-…`, `Bearer …`, a DSN with a password). Redaction
/// runs unconditionally, but redaction is a heuristic and can miss. So the user
/// gets the final say, looking at the actual redacted text.
enum ArgvPolicy: String, CaseIterable, Identifiable {
    /// Show the redacted argv and ask, every time a process HAS arguments.
    case ask = "ask"
    case alwaysInclude = "always"
    case neverInclude = "never"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask:           return L("processes.argv.policy.ask")
        case .alwaysInclude: return L("processes.argv.policy.always")
        case .neverInclude:  return L("processes.argv.policy.never")
        }
    }
}

/// Tool-local persistence. Lives inside the tool folder by project convention —
/// `Core` holds only shared infrastructure.
///
/// Backward compatibility: unknown/removed keys are ignored, never deleted, and a
/// value that no longer parses falls back to the default rather than throwing.
final class ProcessesPreferences: ObservableObject {

    private enum Key {
        static let interval    = "processes.refreshInterval"
        static let hideSystem  = "processes.hideSystemProcesses"
        static let argvPolicy  = "processes.argvPolicy"
        static let aiNoticeAck = "processes.aiNoticeAcknowledged"
    }

    private let defaults: UserDefaults

    @Published var interval: RefreshInterval {
        didSet { defaults.set(interval.rawValue, forKey: Key.interval) }
    }

    @Published var hideSystemProcesses: Bool {
        didSet { defaults.set(hideSystemProcesses, forKey: Key.hideSystem) }
    }

    @Published var argvPolicy: ArgvPolicy {
        didSet { defaults.set(argvPolicy.rawValue, forKey: Key.argvPolicy) }
    }

    /// Whether the user has seen the "what gets sent, and to whom" notice once.
    /// The expandable payload disclosure stays visible forever regardless — this
    /// only suppresses the one-time explanatory text.
    @Published var aiNoticeAcknowledged: Bool {
        didSet { defaults.set(aiNoticeAcknowledged, forKey: Key.aiNoticeAck) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.integer(forKey: Key.interval)
        self.interval = RefreshInterval(rawValue: raw) ?? .normal
        // Default ON: ~400 Apple daemons would otherwise bury the user's own apps.
        self.hideSystemProcesses = defaults.object(forKey: Key.hideSystem) as? Bool ?? true
        self.argvPolicy = ArgvPolicy(rawValue: defaults.string(forKey: Key.argvPolicy) ?? "") ?? .ask
        self.aiNoticeAcknowledged = defaults.bool(forKey: Key.aiNoticeAck)
    }
}

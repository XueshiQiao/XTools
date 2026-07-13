import SwiftUI
import Carbon.HIToolbox

/// UI-facing state for the Naga tool. Owns the input backend + the swallowing
/// event tap, holds the per-button mapping, and drives the remap emit.
final class NagaStore: ObservableObject {

    @Published var mappings: [ButtonMapping] = NagaMappingStore.load()
    @Published private(set) var captures: [CapturedKey] = []
    @Published private(set) var listening = false

    private let backend: InputBackend
    private let log = FileLog("Naga.Store")

    /// Swallows the raw F13–F18 sentinels so they never reach apps (seize is denied
    /// for keyboards, so this CGEventTap does the suppression). The remap emit is
    /// driven by the IOHID listener below, which knows the press came from the Razer.
    private let swallower = KeySwallower(swallow: Set(
        [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18].map { CGKeyCode($0) }
    ))

    init(backend: InputBackend = SeizeBackend(mode: .listen)) {
        self.backend = backend
        backend.onCapture = { [weak self] mods, key in
            DispatchQueue.main.async { self?.handle(modifiers: mods, keyUsage: key) }
        }
    }

    // MARK: Lifecycle

    func start() {
        if AccessibilityAuthorizer.isTrusted {
            log.info("Accessibility trusted")
        } else {
            log.info("Accessibility NOT trusted — prompting")
            AccessibilityAuthorizer.prompt()
        }
        swallower.start()
        backend.start()
        listening = true
    }

    func stop() {
        backend.stop()
        swallower.stop()
        listening = false
    }

    // MARK: Mapping edits

    func setShortcut(_ shortcut: Shortcut?, forButton index: Int) {
        guard let i = mappings.firstIndex(where: { $0.index == index }) else { return }
        mappings[i].target = shortcut
        persist()
    }

    func setEnabled(_ enabled: Bool, forButton index: Int) {
        guard let i = mappings.firstIndex(where: { $0.index == index }) else { return }
        mappings[i].enabled = enabled
        persist()
    }

    func clearCaptures() { captures.removeAll() }

    private func persist() { NagaMappingStore.save(mappings) }

    // MARK: Input

    private func handle(modifiers: [UInt32], keyUsage: UInt32) {
        captures.insert(CapturedKey(modifiers: modifiers, keyUsage: keyUsage, time: Date()), at: 0)
        if captures.count > 100 { captures.removeLast() }

        // Emit the mapped shortcut for this sentinel (raw sentinel is swallowed by the tap).
        guard modifiers.isEmpty,
              let m = mappings.first(where: { $0.sentinelUsage == keyUsage }),
              m.enabled, let target = m.target else { return }
        ShortcutEmitter.emit(keyCode: CGKeyCode(target.keyCode), flags: target.cgFlags)
        log.info("button \(m.index) (\(m.sentinelName)) → \(target.display)")
    }
}

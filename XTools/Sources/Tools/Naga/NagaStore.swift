import SwiftUI
import AppKit
import Carbon.HIToolbox

/// UI-facing state for the Naga tool. Owns the input backend + the swallowing/
/// recording event tap, holds the per-button mapping, and drives the remap emit.
final class NagaStore: ObservableObject {

    @Published var mappings: [ButtonMapping] = NagaMappingStore.load()
    @Published private(set) var captures: [CapturedKey] = []
    @Published private(set) var listening = false
    /// Which button's recorder is currently capturing (nil = none).
    @Published private(set) var recordingButton: Int?

    private let backend: InputBackend
    private let log = FileLog("Naga.Store")
    private var recordTimeout: DispatchWorkItem?

    /// Swallows the raw F13–F18 sentinels so they never reach apps (seize is denied
    /// for keyboards, so this CGEventTap does the suppression) and captures shortcuts
    /// during recording. The remap emit is driven by the IOHID listener below.
    private let swallower = KeySwallower(swallow: Set(
        [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18].map { CGKeyCode($0) }
    ))

    init(backend: InputBackend = SeizeBackend(mode: .listen)) {
        self.backend = backend
        backend.onCapture = { [weak self] mods, key in
            DispatchQueue.main.async { self?.handle(modifiers: mods, keyUsage: key) }
        }
        swallower.onRecordCapture = { [weak self] code, flags in
            DispatchQueue.main.async { self?.finishRecording(keyCode: code, cgFlags: flags) }
        }
        swallower.onRecordCancel = { [weak self] in
            DispatchQueue.main.async { self?.cancelRecording() }
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
        cancelRecording()
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

    // MARK: Recording (via the event tap, so global hotkeys can be captured)

    func toggleRecording(button index: Int) {
        if recordingButton == index { cancelRecording(); return }
        recordingButton = index
        swallower.beginRecording()
        // Safety net: if nothing is pressed (or the tap isn't running), don't leave
        // the recorder stuck — auto-cancel after a few seconds.
        let work = DispatchWorkItem { [weak self] in self?.cancelRecording() }
        recordTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func cancelRecording() {
        recordTimeout?.cancel(); recordTimeout = nil
        swallower.cancelRecording()
        recordingButton = nil
    }

    private func finishRecording(keyCode code: CGKeyCode, cgFlags: CGEventFlags) {
        guard let index = recordingButton else { return }
        recordTimeout?.cancel(); recordTimeout = nil
        // Plain Delete/Backspace clears the mapping; anything else sets it.
        if cgFlags.isEmpty, code == CGKeyCode(kVK_Delete) || code == CGKeyCode(kVK_ForwardDelete) {
            setShortcut(nil, forButton: index)
        } else {
            let mods = Self.modifierFlags(from: cgFlags)
            setShortcut(Shortcut(keyCode: UInt16(code), modifiers: mods.rawValue), forButton: index)
        }
        recordingButton = nil
    }

    private static func modifierFlags(from cg: CGEventFlags) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if cg.contains(.maskCommand)   { f.insert(.command) }
        if cg.contains(.maskAlternate) { f.insert(.option) }
        if cg.contains(.maskControl)   { f.insert(.control) }
        if cg.contains(.maskShift)     { f.insert(.shift) }
        return f
    }

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

import CoreGraphics
import Carbon.HIToolbox
import Foundation

/// Installs an active `CGEventTap` that (a) swallows key-down/up for a fixed set of
/// virtual keycodes — the sentinel keys (F13–F18) the Razer side buttons emit — and
/// (b) doubles as the **shortcut recorder** while `recording` is on.
///
/// Seizing the HID device is denied by macOS for keyboards (kIOReturnNotPrivileged),
/// so this tap is how the raw sentinel is stopped from reaching apps. The same tap
/// captures a shortcut being recorded: because it sits at the head of the session
/// event stream, it sees (and consumes) a key combo *before* any registered global
/// hotkey fires — so you can record combos that are already system/app hotkeys.
/// Needs Accessibility.
final class KeySwallower {

    private let swallow: Set<CGKeyCode>
    private let log = FileLog("Naga.Tap")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// While true, the next real key-down is captured as a shortcut (and swallowed),
    /// instead of the normal sentinel filtering. Set/read on the main thread.
    private var recording = false
    /// Called (on the tap's main-loop thread) with a captured combo.
    var onRecordCapture: ((CGKeyCode, CGEventFlags) -> Void)?
    /// Called when recording is cancelled by Escape.
    var onRecordCancel: (() -> Void)?

    init(swallow: Set<CGKeyCode>) { self.swallow = swallow }

    var isRunning: Bool { tap != nil }

    func beginRecording() { recording = true }
    func cancelRecording() { recording = false }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // active — may return nil to consume
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeySwallower>.fromOpaque(ctx).takeUnretainedValue().handle(type, event)
            },
            userInfo: ctx
        ) else {
            log.error("tapCreate failed — is Accessibility granted?")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let n = swallow.count
        log.info("key swallower started (\(n) sentinel keycodes)")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that is slow or on certain input; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Recording: capture the first real key-down as a shortcut and swallow it, so
        // an already-registered global hotkey neither fires nor eats the combo.
        if recording {
            if type == .keyDown {
                let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                recording = false // stop before the callback to avoid a double capture
                if code == CGKeyCode(kVK_Escape) {
                    onRecordCancel?()
                } else {
                    let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                    onRecordCapture?(code, flags)
                }
            }
            return nil // swallow keys while recording
        }

        // Never swallow our own synthesized output.
        if event.getIntegerValueField(.eventSourceUserData) == ShortcutEmitter.syntheticUserData {
            return Unmanaged.passUnretained(event)
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if swallow.contains(code) {
            return nil // consume — the raw sentinel never reaches any app
        }
        return Unmanaged.passUnretained(event)
    }

    func stop() {
        recording = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

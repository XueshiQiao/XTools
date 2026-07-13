import CoreGraphics
import Foundation

/// Installs an active `CGEventTap` that swallows key-down/up for a fixed set of
/// virtual keycodes — the sentinel keys (F13–F18) the Razer side buttons emit.
///
/// Seizing the HID device is denied by macOS for keyboards (kIOReturnNotPrivileged),
/// so this is how the raw sentinel is stopped from reaching apps. Because the
/// sentinels are keys no real keyboard sends, swallowing them unconditionally is
/// safe; the *actual* remap (emit) is driven separately by the IOHID listener,
/// which knows the press came from the Razer. Needs Accessibility.
final class KeySwallower {

    private let swallow: Set<CGKeyCode>
    private let log = FileLog("Naga.Tap")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(swallow: Set<CGKeyCode>) { self.swallow = swallow }

    var isRunning: Bool { tap != nil }

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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

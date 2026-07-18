import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` wrapper: registers a **consuming**, system-wide
/// hotkey. Unlike an `NSEvent` global monitor, this swallows the combo so the
/// front app never sees it — the right primitive for a global trigger like
/// Screenshot OCR (⌘⇧S).
///
/// Main-thread by convention (callers create/invalidate on main). A single
/// process-wide Carbon event handler is installed once and routes every hotkey
/// press through an id → closure table, because the C callback cannot capture
/// `self`.
final class GlobalHotKey {

    private static let log = FileLog("PopBar.OCR")

    /// Shared four-char signature for every hotkey we register ('XTHK').
    private static let signature = OSType(0x5854_484B)   // 'X','T','H','K'

    /// id → closure routing table, read by the shared C callback (main thread).
    fileprivate static var handlers: [UInt32: () -> Void] = [:]
    /// Monotonic id source; each registration claims the next value.
    private static var nextID: UInt32 = 1
    /// Guards the install-once of the shared Carbon event handler.
    private static var handlerInstalled = false

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Registers a consuming system-wide hotkey. Returns `nil` if registration
    /// fails (e.g. the combo is already claimed by another app or the system).
    init?(combo: KeyCombo, onPressed: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1
        self.id = id

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Self.log.warn("RegisterEventHotKey failed for \(combo.display) (status \(status))")
            return nil
        }
        self.ref = ref
        Self.handlers[id] = onPressed
        Self.log.info("registered hotkey \(combo.display) (id \(id))")
    }

    /// Unregisters the hotkey and drops it from the routing table. Idempotent.
    func invalidate() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.handlers[id] = nil
        Self.log.info("unregistered hotkey (id \(self.id))")
    }

    deinit { invalidate() }

    // MARK: - Shared Carbon handler

    /// Installs the one process-wide `kEventHotKeyPressed` handler on first use.
    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // `hotKeyEventHandler` is a top-level, context-free function, so it
        // converts to the C function pointer `InstallEventHandler` requires.
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }

    /// Routes a fired hotkey id to its closure, invoked on the main thread.
    fileprivate static func fire(id: UInt32) {
        guard let handler = handlers[id] else { return }
        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async(execute: handler)
        }
    }
}

/// Top-level C callback for `kEventClassKeyboard` / `kEventHotKeyPressed`. Reads
/// the fired `EventHotKeyID.id` and routes it through the shared table. Captures
/// no context so it is a valid `@convention(c)` function pointer.
private func hotKeyEventHandler(_ callRef: EventHandlerCallRef?,
                               _ event: EventRef?,
                               _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    GlobalHotKey.fire(id: hotKeyID.id)
    return noErr
}

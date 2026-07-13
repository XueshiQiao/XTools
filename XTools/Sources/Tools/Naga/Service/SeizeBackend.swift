import IOKit.hid
import Foundation

/// Observes the Razer Naga's HID input and reports each side-button press as a
/// settled key combo. Read-only in `.listen` (never blocks input).
///
/// `.seize` (an exclusive grab, which would suppress the keys itself) is denied by
/// macOS for keyboard-type HID devices — `IOHIDManagerOpen` returns
/// `kIOReturnNotPrivileged` — so the tool runs in `.listen` and suppresses the raw
/// sentinel keys with a `CGEventTap` instead (see `KeySwallower`). This listener
/// reliably knows a press came from the Razer (matched by vendor id), so it drives
/// the remap emit.
///
/// A side button can emit a modifier+key combo whose elements arrive in either
/// order, so we accumulate the held keyboard usages and report the settled combo
/// ~30 ms after a key-down burst.
final class SeizeBackend: InputBackend {

    enum Mode { case listen, seize }

    var onCapture: ((_ modifiers: [UInt32], _ keyUsage: UInt32) -> Void)?

    private let mode: Mode
    private let log = FileLog("Naga.HID")
    private var manager: IOHIDManager?
    private var downKeys = Set<UInt32>()      // held keyboard usages (mods + keys)
    private var pendingReport: DispatchWorkItem?

    init(mode: Mode = .listen) { self.mode = mode }

    func start() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) // prompts for Input Monitoring
        }

        let options: IOOptionBits = (mode == .seize)
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, options)

        // Match all Razer interfaces by vendor id; the callback keeps only keyboard usages.
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: NagaDevice.razerVendorID],
            [kIOHIDVendorIDKey: NagaDevice.btVendorID],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<SeizeBackend>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(mgr, options)
        if r != kIOReturnSuccess { log.error("IOHIDManagerOpen failed: \(r)") }
        manager = mgr
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let v = IOHIDValueGetIntegerValue(value)

        // Only keyboard-page usages carry the side-button keystrokes (this also drops
        // pointer movement / wheel, which arrive on the Generic Desktop page).
        guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        guard usage >= 4, usage < 0xFFFF else { return } // skip reserved / array artifacts

        if v != 0 { downKeys.insert(usage) } else { downKeys.remove(usage) }
        guard v != 0 else { return }

        // Debounce so key + modifiers (either order) coalesce into one combo.
        pendingReport?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reportCombo() }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func reportCombo() {
        let mods = downKeys.filter { $0 >= 0xE0 && $0 <= 0xE7 }.sorted()
        let keys = downKeys.filter { !($0 >= 0xE0 && $0 <= 0xE7) }.sorted()
        guard let mainKey = keys.first else { return }
        onCapture?(mods, mainKey)
    }

    func stop() {
        pendingReport?.cancel()
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let opt: IOOptionBits = (mode == .seize) ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
            IOHIDManagerClose(mgr, opt)
        }
        manager = nil
    }
}

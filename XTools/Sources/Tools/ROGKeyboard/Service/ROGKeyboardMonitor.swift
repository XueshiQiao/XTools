import Foundation
import IOKit
import IOKit.hid

/// Watches for the keyboard arriving on and leaving the USB link.
///
/// The Falcata's mode switch is physical: flipping it to 2.4 GHz makes the
/// keyboard drop off USB entirely (the cable stays plugged in, but the device
/// de-enumerates), and flipping back to USB makes it reappear. That reappearance
/// is the signal the tool acts on — it is the moment the keyboard "comes back to
/// the Mac". There is no corresponding chance to act on the way out: by the time
/// the removal callback fires, the keyboard is already listening to the other
/// computer and cannot be reached.
final class ROGKeyboardMonitor {

    private static let log = FileLog("ROGKeyboardMonitor")

    /// A genuine arrival — the keyboard was not here, and now it is.
    var onAttached: (() -> Void)?
    /// The keyboard was already attached when monitoring began. Reported
    /// separately because it is *not* an arrival: switching profiles here would
    /// mean every app launch quietly reassigns the user's keys.
    var onAlreadyPresent: (() -> Void)?
    var onDetached: (() -> Void)?

    private var manager: IOHIDManager?
    /// Devices reported during this window are pre-existing, not new arrivals.
    /// IOKit replays the current device set into the matching callback as soon as
    /// the manager is scheduled, with nothing to distinguish those from a real
    /// plug-in.
    private var primingDeadline = Date.distantPast
    private var coalesceTimer: Timer?
    private var attachedProductIDs = Set<Int>()

    /// The mode switch produces several HID collections in quick succession, and
    /// the keyboard needs a moment before it answers commands reliably.
    private let settleDelay: TimeInterval = 0.8

    func start() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [[
            kIOHIDVendorIDKey: ROGHIDDevice.vendorID,
            kIOHIDPrimaryUsagePageKey: ROGHIDDevice.controlUsagePage,
            kIOHIDPrimaryUsageKey: ROGHIDDevice.controlUsage,
        ]] as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<ROGKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<ROGKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)

        primingDeadline = Date().addingTimeInterval(1.0)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        Self.log.info("monitoring started")
    }

    func stop() {
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        attachedProductIDs.removeAll()
        Self.log.info("monitoring stopped")
    }

    // MARK: - IOKit callbacks (main run loop)

    private func deviceMatched(_ device: IOHIDDevice) {
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard ROGModel.allProductIDs.contains(pid) else { return }
        let wasEmpty = attachedProductIDs.isEmpty
        attachedProductIDs.insert(pid)
        guard wasEmpty else { return }   // second collection of the same keyboard

        let isPreexisting = Date() < primingDeadline
        Self.log.info("keyboard present (pid 0x\(String(format: "%04X", pid)))\(isPreexisting ? " — already there at startup" : " — just arrived")")

        // One notification per arrival, after the device has settled.
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.coalesceTimer = nil
            if isPreexisting { self.onAlreadyPresent?() } else { self.onAttached?() }
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard ROGModel.allProductIDs.contains(pid) else { return }
        attachedProductIDs.remove(pid)
        guard attachedProductIDs.isEmpty else { return }
        Self.log.info("keyboard gone (pid 0x\(String(format: "%04X", pid))) — switched to 2.4G/Bluetooth or unplugged")
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        onDetached?()
    }
}

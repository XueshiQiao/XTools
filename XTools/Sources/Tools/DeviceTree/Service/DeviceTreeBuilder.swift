import Foundation
import IOKit
import CoreGraphics

/// Assembles one tree out of every scanner.
///
/// Sections that come back empty are kept and marked "not detected" rather than
/// hidden — on a machine with no Bluetooth accessories that is the honest
/// answer, and it distinguishes "nothing there" from "we never looked".
enum DeviceTreeBuilder {

    static func build() -> [DeviceNode] {
        // One `system_profiler` process serves Thunderbolt, Bluetooth and cameras.
        let profiler = SystemProfilerSource.fetch()
        return [
            group(id: "g-thunderbolt", name: L("devtree.section.thunderbolt"),
                  category: .thunderbolt, children: SystemProfilerSource.thunderbolt(profiler)),
            group(id: "g-usb", name: L("devtree.section.usb"),
                  category: .usb, children: IORegistryScanner.usbGroups()),
            group(id: "g-pci", name: L("devtree.section.pci"),
                  category: .pci, children: IORegistryScanner.pciDevices()),
            group(id: "g-display", name: L("devtree.section.displays"),
                  category: .display, children: DisplayScanner.scan()),
            group(id: "g-bluetooth", name: L("devtree.section.bluetooth"),
                  category: .bluetooth, children: SystemProfilerSource.bluetooth(profiler)),
            group(id: "g-audio", name: L("devtree.section.audio"),
                  category: .audio, children: AudioScanner.scan()),
            group(id: "g-camera", name: L("devtree.section.cameras"),
                  category: .camera, children: SystemProfilerSource.cameras(profiler)),
            group(id: "g-network", name: L("devtree.section.network"),
                  category: .network, children: NetworkScanner.scan()),
        ]
    }

    private static func group(id: String, name: String, category: DeviceCategory,
                              children: [DeviceNode]) -> DeviceNode {
        DeviceNode(id: id,
                   name: name,
                   detail: children.isEmpty
                       ? L("devtree.notDetected")
                       : String(format: L("devtree.count.devices"), children.reduce(children.count) { $0 + $1.descendantCount }),
                   category: category,
                   children: children)
    }

    /// A one-line description of the machine itself, used as the export header.
    static func hostSummary() -> String {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return "\(hardwareModel()) · macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        let model = String(cString: chars)
        return model.isEmpty ? "Mac" : model
    }
}

/// Fires when hardware comes or goes, so the tree does not go stale while it is
/// on screen.
///
/// Watches USB and PCI arrival/departure (which covers docks, peripherals and
/// anything tunnelled behind them) plus display reconfiguration. Several events
/// usually arrive together when one accessory is plugged in, so they are
/// coalesced into a single rescan.
final class DeviceWatcher {

    private static let log = FileLog("DeviceTree")

    var onChange: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var displayCallbackInstalled = false
    private var coalesceTimer: Timer?

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        for className in ["IOUSBDevice", "IOPCIDevice"] {
            for notificationType in [kIOMatchedNotification, kIOTerminatedNotification] {
                guard let matching = IOServiceMatching(className) else { continue }
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    port, notificationType, matching,
                    { context, iterator in
                        // The iterator MUST be drained or the notification never fires again.
                        while case let next = IOIteratorNext(iterator), next != 0 { IOObjectRelease(next) }
                        guard let context else { return }
                        Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue().scheduleRescan()
                    },
                    context, &iterator)
                guard status == KERN_SUCCESS else { continue }
                // Arm the notification by consuming the devices that already exist.
                while case let existing = IOIteratorNext(iterator), existing != 0 { IOObjectRelease(existing) }
                iterators.append(iterator)
            }
        }

        CGDisplayRegisterReconfigurationCallback(deviceWatcherDisplayCallback, context)
        displayCallbackInstalled = true

        let count = iterators.count
        Self.log.info("watching \(count) IOKit notification(s) + display reconfiguration")
    }

    func stop() {
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        if displayCallbackInstalled {
            // Must be the SAME function pointer that was registered, so this uses
            // the shared top-level callback rather than a fresh closure literal.
            CGDisplayRemoveReconfigurationCallback(deviceWatcherDisplayCallback,
                                                   Unmanaged.passUnretained(self).toOpaque())
            displayCallbackInstalled = false
        }
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    /// Plugging in one dock produces a burst of events; rescanning per event
    /// would run the whole sweep dozens of times for a single action.
    fileprivate func scheduleRescan() {
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.coalesceTimer = nil
            self?.onChange?()
        }
    }
}

/// Registered with CoreGraphics as a plain C function so that unregistering can
/// pass the identical pointer — two closure literals with the same body are not
/// guaranteed to compare equal.
private func deviceWatcherDisplayCallback(_ display: CGDirectDisplayID,
                                          _ flags: CGDisplayChangeSummaryFlags,
                                          _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue().scheduleRescan()
}

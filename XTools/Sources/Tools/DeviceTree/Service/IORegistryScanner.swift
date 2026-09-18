import Foundation
import IOKit

/// Reads the physical device tree straight out of the IOKit registry.
///
/// The registry *is* macOS's own device model, so the shape of the tree comes
/// from the system rather than from anything written here. Nothing in this file
/// names a specific Mac, chip, vendor or accessory: devices are found by their
/// generic IOKit class (`IOUSBDevice`, `IOPCIDevice`) and their nesting is
/// recovered from each node's real parent chain. A Mac with nothing plugged in
/// produces a small tree through exactly the same code path as one behind a dock.
enum IORegistryScanner {

    // MARK: - Raw registry access

    private struct RawEntry {
        let entryID: UInt64
        /// Registry ids of every ancestor, nearest first.
        let ancestorIDs: [UInt64]
        let registryName: String
        let properties: [String: Any]
    }

    private static func entries(matchingClass className: String) -> [RawEntry] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [RawEntry] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            IORegistryEntryGetName(service, &nameBuffer)

            var propsRef: Unmanaged<CFMutableDictionary>?
            IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
            let properties = propsRef?.takeRetainedValue() as? [String: Any] ?? [:]

            result.append(RawEntry(entryID: entryID,
                                   ancestorIDs: ancestorIDs(of: service),
                                   registryName: String(cString: nameBuffer),
                                   properties: properties))
        }
        return result
    }

    private static func ancestorIDs(of service: io_registry_entry_t) -> [UInt64] {
        var ids: [UInt64] = []
        var current = service
        IOObjectRetain(current)
        while true {
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard status == KERN_SUCCESS, parent != 0 else { break }
            var parentID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(parent, &parentID) == KERN_SUCCESS {
                ids.append(parentID)
            }
            current = parent
        }
        return ids
    }

    /// Name of the nearest ancestor that is NOT one of the matched devices —
    /// for a USB device that is its host controller, which is how devices get
    /// grouped by the port they hang off.
    private static func controllerName(for entry: RawEntry, known: Set<UInt64>) -> String? {
        guard let service = firstAncestorService(of: entry, notIn: known) else { return nil }
        defer { IOObjectRelease(service) }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        IORegistryEntryGetName(service, &nameBuffer)
        return String(cString: nameBuffer)
    }

    private static func firstAncestorService(of entry: RawEntry, notIn known: Set<UInt64>) -> io_registry_entry_t? {
        for id in entry.ancestorIDs where !known.contains(id) {
            var matching = IORegistryEntryIDMatching(id)
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            matching = nil
            if service != 0 { return service }
        }
        return nil
    }

    // MARK: - USB

    /// USB devices, nested exactly as they are physically chained, grouped by the
    /// host controller they ultimately hang off.
    static func usbGroups() -> [DeviceNode] {
        // `IOUSBDevice` is the class name that resolves on both Apple silicon and
        // Intel Macs; `IOUSBHostDevice` is its modern alias and returns the same set.
        let all = entries(matchingClass: "IOUSBDevice")
        guard !all.isEmpty else { return [] }

        let byID = Dictionary(all.map { ($0.entryID, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(byID.keys)

        var childrenOf: [UInt64: [UInt64]] = [:]
        var roots: [RawEntry] = []
        for entry in all {
            if let parentID = entry.ancestorIDs.first(where: { known.contains($0) }) {
                childrenOf[parentID, default: []].append(entry.entryID)
            } else {
                roots.append(entry)
            }
        }

        func build(_ entry: RawEntry) -> DeviceNode {
            var node = usbNode(entry)
            node.children = (childrenOf[entry.entryID] ?? [])
                .compactMap { byID[$0] }
                .map(build)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return node
        }

        // Group the roots by controller so several ports don't read as one bus.
        var groups: [String: [DeviceNode]] = [:]
        for root in roots {
            let controller = controllerName(for: root, known: known) ?? L("devtree.usb.unknownController")
            groups[controller, default: []].append(build(root))
        }
        return groups.keys.sorted().map { controller in
            var group = DeviceNode(id: "usb-controller-\(controller)",
                                   name: controller,
                                   detail: nil,
                                   category: .usb)
            group.children = groups[controller]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            group.detail = String(format: L("devtree.count.devices"), group.descendantCount)
            return group
        }
    }

    private static func usbNode(_ entry: RawEntry) -> DeviceNode {
        let props = entry.properties
        let name = (props["USB Product Name"] as? String)
            ?? (props["kUSBProductString"] as? String)
            ?? entry.registryName
        let vendor = (props["USB Vendor Name"] as? String) ?? (props["kUSBVendorString"] as? String)
        let vid = props["idVendor"] as? Int
        let pid = props["idProduct"] as? Int
        let speed = props["Device Speed"] as? Int

        var details: [String] = []
        if let vendor, !vendor.isEmpty { details.append(vendor) }
        if let vid, let pid { details.append(String(format: "%04X:%04X", vid, pid)) }
        if let speed, let label = usbSpeedLabel(speed) { details.append(label) }

        var properties: [DeviceProperty] = []
        if let vendor { properties.append(DeviceProperty(label: L("devtree.prop.vendor"), value: vendor)) }
        if let vid { properties.append(DeviceProperty(label: "Vendor ID", value: String(format: "0x%04X", vid))) }
        if let pid { properties.append(DeviceProperty(label: "Product ID", value: String(format: "0x%04X", pid))) }
        if let serial = props["kUSBSerialNumberString"] as? String, !serial.isEmpty {
            properties.append(DeviceProperty(label: L("devtree.prop.serial"), value: serial))
        }
        if let speed, let label = usbSpeedLabel(speed) {
            properties.append(DeviceProperty(label: L("devtree.prop.speed"), value: label))
        }

        return DeviceNode(id: "usb-\(entry.entryID)",
                          name: name,
                          detail: details.isEmpty ? nil : details.joined(separator: " · "),
                          category: .usb,
                          properties: properties)
    }

    /// USB's own speed enumeration, not anything Mac-specific.
    private static func usbSpeedLabel(_ raw: Int) -> String? {
        switch raw {
        case 0: return "USB 1.0 (1.5 Mb/s)"
        case 1: return "USB 1.1 (12 Mb/s)"
        case 2: return "USB 2.0 (480 Mb/s)"
        case 3: return "USB 3.0 (5 Gb/s)"
        case 4: return "USB 3.1 (10 Gb/s)"
        case 5: return "USB 3.2 (20 Gb/s)"
        default: return nil
        }
    }

    // MARK: - PCI

    /// Non-bridge PCI devices, flat. Bridges are dropped: on a modern Mac they
    /// outnumber real devices several to one and carry no information a person
    /// wants. Each device is labelled from its PCI class code — an industry
    /// standard, so this reads correctly on any machine.
    static func pciDevices() -> [DeviceNode] {
        entries(matchingClass: "IOPCIDevice")
            .compactMap { entry -> DeviceNode? in
                let props = entry.properties
                let classCode = pciClassCode(props["class-code"])
                guard let classCode, (classCode >> 16) != 0x06 else { return nil }   // 0x06 = bridge

                let vendorID = pciID(props["vendor-id"])
                let deviceID = pciID(props["device-id"])
                let tunnelled = (props["IOPCITunnelled"] as? Bool) ?? false

                var details: [String] = [pciClassLabel(classCode)]
                if let vendorID, let deviceID {
                    details.append(String(format: "%04X:%04X", vendorID, deviceID))
                }

                var properties: [DeviceProperty] = [
                    DeviceProperty(label: L("devtree.prop.pciClass"), value: String(format: "0x%06X", classCode)),
                ]
                if let vendorID { properties.append(DeviceProperty(label: "Vendor ID", value: String(format: "0x%04X", vendorID))) }
                if let deviceID { properties.append(DeviceProperty(label: "Device ID", value: String(format: "0x%04X", deviceID))) }

                var node = DeviceNode(id: "pci-\(entry.entryID)",
                                      name: (props["IOName"] as? String) ?? entry.registryName,
                                      detail: details.joined(separator: " · "),
                                      category: .pci,
                                      properties: properties)
                if tunnelled { node.badges.append(L("devtree.badge.tunnelled")) }
                return node
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func pciClassCode(_ value: Any?) -> Int? {
        guard let data = value as? Data, data.count >= 3 else { return nil }
        // Stored little-endian: byte 0 = interface, 1 = subclass, 2 = base class.
        return (Int(data[2]) << 16) | (Int(data[1]) << 8) | Int(data[0])
    }

    private static func pciID(_ value: Any?) -> Int? {
        guard let data = value as? Data, data.count >= 2 else { return nil }
        return Int(data[0]) | (Int(data[1]) << 8)
    }

    /// PCI base-class names from the PCI-SIG assignment, covering what actually
    /// turns up in a Mac. Anything unlisted falls back to its raw code.
    private static func pciClassLabel(_ classCode: Int) -> String {
        switch classCode >> 16 {
        case 0x01: return L("devtree.pci.storage")
        case 0x02: return L("devtree.pci.network")
        case 0x03: return L("devtree.pci.display")
        case 0x04: return L("devtree.pci.multimedia")
        case 0x08: return L("devtree.pci.systemPeripheral")
        case 0x0C: return L("devtree.pci.serialBus")
        case 0x0D: return L("devtree.pci.wireless")
        default:   return String(format: "PCI 0x%02X", classCode >> 16)
        }
    }
}

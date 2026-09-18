import Foundation

/// The domains read through `system_profiler` instead of a framework.
///
/// Two different reasons land here, and both matter for portability:
///
/// 1. **Thunderbolt** — its IOKit classes are private and carry a
///    controller-specific suffix (`IOThunderboltSwitchType7`,
///    `IOThunderboltSwitchIntelJHL8440`), so matching them by name would quietly
///    stop working on a Mac with a different controller.
///
/// 2. **Bluetooth and cameras** — the frameworks that own them (IOBluetooth,
///    AVFoundation) are privacy-gated. Calling them without the matching
///    `Info.plist` usage-description key does not fail gracefully: macOS
///    **hard-crashes the app** through TCC. Adding those keys would make XTools
///    demand Bluetooth and camera permission merely to list device names, which
///    is far too high a price for a read-only inventory. `system_profiler` is a
///    separate Apple-signed process carrying its own entitlements, so it reports
///    the same information without XTools ever touching a protected API.
///
/// One process serves all three data types, so a scan forks once.
enum SystemProfilerSource {

    private static let log = FileLog("DeviceTree")

    struct Payload {
        let json: [String: Any]
        static let empty = Payload(json: [:])
    }

    static func fetch() -> Payload {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPThunderboltDataType", "SPBluetoothDataType", "SPCameraDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("system_profiler failed to launch: \(error.localizedDescription)")
            return .empty
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }
        return Payload(json: json)
    }

    // MARK: - Thunderbolt / USB4

    static func thunderbolt(_ payload: Payload) -> [DeviceNode] {
        guard let buses = payload.json["SPThunderboltDataType"] as? [[String: Any]] else { return [] }
        return buses.enumerated().map { index, bus in
            let rawName = (bus["_name"] as? String) ?? "bus"
            var node = DeviceNode(id: "tb-bus-\(rawName)-\(index)",
                                  name: busDisplayName(rawName),
                                  category: .thunderbolt)
            let devices = (bus["_items"] as? [[String: Any]]) ?? []
            node.children = devices.enumerated().map { childIndex, item in
                thunderboltDevice(item, path: "\(rawName)-\(childIndex)")
            }
            node.detail = devices.isEmpty
                ? L("devtree.tb.nothingAttached")
                : String(format: L("devtree.count.devices"), node.descendantCount)
            return node
        }
    }

    private static func thunderboltDevice(_ item: [String: Any], path: String) -> DeviceNode {
        let name = (item["device_name_key"] as? String) ?? (item["_name"] as? String) ?? "?"
        let vendor = item["vendor_name_key"] as? String

        var details: [String] = []
        if let vendor { details.append(vendor) }
        if let speed = upstreamSpeed(item) { details.append(speed) }

        var properties: [DeviceProperty] = []
        if let vendor { properties.append(DeviceProperty(label: L("devtree.prop.vendor"), value: vendor)) }
        if let firmware = item["switch_version_key"] as? String {
            properties.append(DeviceProperty(label: L("devtree.prop.firmware"), value: firmware))
        }
        if let mode = item["mode_key"] as? String {
            properties.append(DeviceProperty(label: L("devtree.prop.linkMode"), value: modeLabel(mode)))
        }
        if let uid = item["switch_uid_key"] as? String {
            properties.append(DeviceProperty(label: "UID", value: uid))
        }

        var node = DeviceNode(id: "tb-\(path)",
                              name: name,
                              detail: details.isEmpty ? nil : details.joined(separator: " · "),
                              category: .thunderbolt,
                              properties: properties)
        node.children = ((item["_items"] as? [[String: Any]]) ?? []).enumerated().map {
            thunderboltDevice($1, path: "\(path)-\($0)")
        }
        return node
    }

    /// The upstream receptacle is the link back toward the Mac, so its speed is
    /// the one worth showing. Fall back to any receptacle that reports one.
    private static func upstreamSpeed(_ item: [String: Any]) -> String? {
        let receptacles = item.filter { $0.key.hasPrefix("receptacle_") }
        if let upstream = receptacles.first(where: { $0.key.contains("upstream") })?.value as? [String: Any],
           let speed = upstream["current_speed_key"] as? String {
            return speed
        }
        for (_, value) in receptacles {
            if let dict = value as? [String: Any], let speed = dict["current_speed_key"] as? String {
                return speed
            }
        }
        return nil
    }

    /// `thunderboltusb4_bus_0` is a lookup key, not a label. Turn it into
    /// something readable without assuming how many buses a Mac has.
    private static func busDisplayName(_ raw: String) -> String {
        if let number = raw.split(separator: "_").last, Int(number) != nil {
            return String(format: L("devtree.tb.bus"), String(number))
        }
        return raw
    }

    private static func modeLabel(_ raw: String) -> String {
        switch raw {
        case "usb_four":    return "USB4"
        case "thunderbolt": return "Thunderbolt"
        default:            return raw
        }
    }

    // MARK: - Bluetooth

    static func bluetooth(_ payload: Payload) -> [DeviceNode] {
        guard let sections = payload.json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var nodes: [DeviceNode] = []
        for section in sections {
            nodes += devices(in: section["device_connected"], connected: true)
            nodes += devices(in: section["device_not_connected"], connected: false)
        }
        return nodes.sorted { a, b in
            if a.badges.isEmpty != b.badges.isEmpty { return !a.badges.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Each entry is a single-key dictionary whose key is the device's name.
    private static func devices(in value: Any?, connected: Bool) -> [DeviceNode] {
        let entries: [[String: Any]]
        if let list = value as? [[String: Any]] {
            entries = list
        } else if let dict = value as? [String: Any] {
            entries = [dict]
        } else {
            return []
        }

        return entries.flatMap { entry -> [DeviceNode] in
            entry.compactMap { name, raw in
                let props = raw as? [String: Any] ?? [:]
                var properties: [DeviceProperty] = []
                if let address = props["device_address"] as? String {
                    properties.append(DeviceProperty(label: L("devtree.prop.address"), value: address))
                }
                if let firmware = props["device_firmwareVersion"] as? String {
                    properties.append(DeviceProperty(label: L("devtree.prop.firmware"), value: firmware))
                }
                if let serial = props["device_serialNumber"] as? String {
                    properties.append(DeviceProperty(label: L("devtree.prop.serial"), value: serial))
                }
                let kind = props["device_minorType"] as? String
                let identity = (props["device_address"] as? String) ?? name
                return DeviceNode(id: "bt-\(identity)",
                                  name: name,
                                  detail: [kind, connected ? L("devtree.bt.connected") : L("devtree.bt.paired")]
                                      .compactMap { $0 }.joined(separator: " · "),
                                  badges: connected ? [L("devtree.bt.connected")] : [],
                                  category: .bluetooth,
                                  properties: properties)
            }
        }
    }

    // MARK: - Cameras

    static func cameras(_ payload: Payload) -> [DeviceNode] {
        guard let items = payload.json["SPCameraDataType"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["_name"] as? String else { return nil }
            let model = item["spcamera_model-id"] as? String
            let unique = item["spcamera_unique-id"] as? String
            var properties: [DeviceProperty] = []
            if let model { properties.append(DeviceProperty(label: L("devtree.prop.model"), value: model)) }
            if let unique { properties.append(DeviceProperty(label: "Unique ID", value: unique)) }
            return DeviceNode(id: "camera-\(unique ?? name)",
                              name: name,
                              detail: model,
                              category: .camera,
                              properties: properties)
        }
    }
}

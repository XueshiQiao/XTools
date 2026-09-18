import Foundation
import AppKit
import CoreGraphics
import CoreAudio
import SystemConfiguration

// Each scanner below asks the framework that owns its domain, rather than
// reading a private IOKit node or parsing a command's output. That is what keeps
// this working on a Mac with a different chip, a different macOS, or nothing
// plugged in: an empty result is a normal answer, not a failure.
//
// Bluetooth and cameras deliberately do NOT live here: their frameworks are
// privacy-gated and hard-crash an app that lacks the matching Info.plist usage
// key. They are read through `SystemProfilerSource` instead, which costs the
// user no permission at all.

// MARK: - Displays

enum DisplayScanner {

    static func scan() -> [DeviceNode] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        // NSScreen carries the human-readable name; CoreGraphics carries the
        // hardware facts. They are joined on the display id.
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }

        return ids.prefix(Int(count)).map { id in
            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            var details = ["\(width) × \(height)"]
            if let mode = CGDisplayCopyDisplayMode(id) {
                let refresh = mode.refreshRate
                // A built-in panel reports 0; only quote a rate we actually got.
                if refresh > 0 { details.append(String(format: "%.0f Hz", refresh)) }
                if mode.pixelWidth != mode.width {
                    details.append(String(format: L("devtree.display.native"), mode.pixelWidth, mode.pixelHeight))
                }
            }

            var badges: [String] = []
            if CGDisplayIsBuiltin(id) != 0 { badges.append(L("devtree.badge.builtIn")) }
            if CGDisplayIsMain(id) != 0 { badges.append(L("devtree.badge.mainDisplay")) }
            if CGDisplayIsAsleep(id) != 0 { badges.append(L("devtree.badge.asleep")) }

            var properties: [DeviceProperty] = [
                DeviceProperty(label: L("devtree.prop.resolution"), value: "\(width) × \(height)"),
                DeviceProperty(label: "Vendor ID", value: String(format: "0x%04X", CGDisplayVendorNumber(id))),
                DeviceProperty(label: "Model ID", value: String(format: "0x%04X", CGDisplayModelNumber(id))),
            ]
            let serial = CGDisplaySerialNumber(id)
            if serial != 0 {
                properties.append(DeviceProperty(label: L("devtree.prop.serial"), value: String(serial)))
            }

            return DeviceNode(id: "display-\(id)",
                              name: names[id] ?? L("devtree.display.unnamed"),
                              detail: details.joined(separator: " · "),
                              badges: badges,
                              category: .display,
                              properties: properties)
        }
    }
}

// MARK: - Audio

enum AudioScanner {

    static func scan() -> [DeviceNode] {
        let defaultOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInput = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)

        return deviceIDs().compactMap { id -> DeviceNode? in
            guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let inputs = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outputs = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard inputs > 0 || outputs > 0 else { return nil }

            var details: [String] = []
            if outputs > 0 { details.append(String(format: L("devtree.audio.out"), outputs)) }
            if inputs > 0 { details.append(String(format: L("devtree.audio.in"), inputs)) }

            var badges: [String] = []
            if id == defaultOutput { badges.append(L("devtree.audio.defaultOut")) }
            if id == defaultInput { badges.append(L("devtree.audio.defaultIn")) }

            var properties: [DeviceProperty] = []
            if let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) {
                properties.append(DeviceProperty(label: "UID", value: uid))
            }
            return DeviceNode(id: "audio-\(id)",
                              name: name,
                              detail: details.joined(separator: " · "),
                              badges: badges,
                              category: .audio,
                              properties: properties)
        }
        .sorted { a, b in
            if a.badges.isEmpty != b.badges.isEmpty { return !a.badges.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Network interfaces

enum NetworkScanner {

    static func scan() -> [DeviceNode] {
        let addresses = ipv4Addresses()
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }

        return interfaces.compactMap { interface -> DeviceNode? in
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { return nil }
            let displayName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? bsdName
            let address = addresses[bsdName]

            var properties: [DeviceProperty] = [DeviceProperty(label: L("devtree.prop.bsdName"), value: bsdName)]
            if let mac = SCNetworkInterfaceGetHardwareAddressString(interface) as String? {
                properties.append(DeviceProperty(label: "MAC", value: mac))
            }
            var badges: [String] = []
            if address != nil { badges.append(L("devtree.net.active")) }

            return DeviceNode(id: "net-\(bsdName)",
                              name: displayName,
                              detail: address ?? L("devtree.net.noAddress"),
                              badges: badges,
                              category: .network,
                              properties: properties)
        }
        .sorted { a, b in
            if a.badges.isEmpty != b.badges.isEmpty { return !a.badges.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func ipv4Addresses() -> [String: String] {
        var result: [String: String] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                if text != "127.0.0.1" { result[name] = text }
            }
        }
        return result
    }
}

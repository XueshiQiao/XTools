import Foundation

// ASUS ROG peripherals speak a small framed protocol over a vendor-defined HID
// collection (usage page 0xFF00, usage 1) that sits alongside the ordinary
// typing interfaces. A request is
//
//     [command, subcommand, index low byte, index high byte, payload…]
//
// zero-padded to the collection's report size — 64 bytes over USB, 20 over the
// 2.4 GHz dongle. The keyboard answers on the same collection and echoes the
// first four bytes back, which is how a reply gets paired with its request.
//
// Derived from ASUS's own browser configurator (Gear Link / 奥创极速网页版),
// which drives the identical protocol through WebHID.

/// One request frame.
struct ROGCommand {
    let command: UInt8
    let subcommand: UInt8
    let index: UInt16
    let payload: [UInt8]

    init(_ command: UInt8, _ subcommand: UInt8 = 0, index: UInt16 = 0, payload: [UInt8] = []) {
        self.command = command
        self.subcommand = subcommand
        self.index = index
        self.payload = payload
    }

    /// The four bytes the keyboard echoes back. A reply is ours when these match.
    var header: [UInt8] {
        [command, subcommand, UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)]
    }

    func frame(size: Int) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: size)
        for (i, byte) in (header + payload).enumerated() where i < size {
            frame[i] = byte
        }
        return frame
    }

    var hexDescription: String {
        (header + payload).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension ROGCommand {
    /// Firmware version, on-board profile count and the currently active profile.
    static let deviceInfo = ROGCommand(0x12, 0x00)

    /// Which physical link the keyboard is using right now.
    static let connectionType = ROGCommand(0x12, 0x03)

    /// Switch the active on-board profile. Profiles are numbered from 1; see
    /// `ROGProfile.isValid`.
    static func changeProfile(_ number: Int) -> ROGCommand {
        ROGCommand(0x51, 0x00, payload: [UInt8(clamping: number)])
    }
}

/// Profile numbering rules, measured against a real ROG Falcata rather than
/// assumed: the keyboard numbers its on-board profiles from **1**, and sending
/// **0 silently selects the LAST profile** instead of failing. An uninitialised
/// variable reaching the wire would therefore move the user to a profile they
/// never chose, with no error to notice — so every profile number is validated
/// here before it can be sent.
enum ROGProfile {
    static let first = 1

    static func isValid(_ number: Int, count: Int) -> Bool {
        number >= first && number <= max(count, first)
    }

    static func clamp(_ number: Int, count: Int) -> Int {
        min(max(number, first), max(count, first))
    }
}

/// Turns the wire-level profile slot into the name ASUS's own configurator shows.
///
/// The protocol identifies profiles by a bare number; Gear Link never shows that
/// number, it lists "Default Profile" followed by "Profile 1…N-1". A profile has
/// to mean the same thing in both places or the two tools would disagree about
/// which one the user picked, so the raw number stays internal and only these
/// names reach the interface.
enum ROGProfileNaming {

    /// The slot Gear Link calls "Default Profile". It sorts first in its list but
    /// is the LAST slot on the wire — which is also why sending 0 lands there
    /// rather than failing.
    static func defaultSlot(count: Int) -> Int { max(count, ROGProfile.first) }

    /// Wire slots in the order Gear Link lists them: default first, then 1…N-1.
    static func orderedSlots(count: Int) -> [Int] {
        let total = max(count, ROGProfile.first)
        guard total > 1 else { return [total] }
        return [defaultSlot(count: total)] + Array(ROGProfile.first..<total)
    }

    static func label(wire: Int, count: Int) -> String {
        wire == defaultSlot(count: count)
            ? L("rog.profile.default")
            : String(format: L("rog.profile.named"), wire)
    }
}

/// Which cable or radio the keyboard is using right now. The keyboard reports
/// this itself, so it is authoritative — unlike inferring it from which USB
/// product id happened to enumerate.
enum ROGLink: UInt8 {
    case wired = 0
    case wireless24G = 1
    case bluetooth = 2

    var localizedName: String {
        switch self {
        case .wired:       return L("rog.link.wired")
        case .wireless24G: return L("rog.link.wireless")
        case .bluetooth:   return L("rog.link.bluetooth")
        }
    }
}

/// What `ROGCommand.deviceInfo` reports back.
struct ROGDeviceInfo: Equatable {
    let firmwareVersion: String
    let profileCount: Int
    /// The active profile, numbered from 1 the way the keyboard numbers them.
    let currentProfile: Int
    /// Which lighting effect the active profile carries. Not unique per profile,
    /// but it does change when the profile changes, which makes it a useful
    /// second signal that a switch really landed.
    let effectMode: Int

    /// Parses the reply to `0x12 0x00`. Over a dongle the keyboard's own version
    /// sits at bytes 11…14 and the dongle's at 4…7; wired, only the first pair is
    /// meaningful.
    init?(reply: [UInt8], link: ROGLink) {
        guard reply.count >= 15 else { return nil }
        let versionOffset = (link == .wired) ? 4 : 11
        // Little-endian, matching the firmware's own packing.
        let raw = UInt32(reply[versionOffset])
            | (UInt32(reply[versionOffset + 1]) << 8)
            | (UInt32(reply[versionOffset + 2]) << 16)
            | (UInt32(reply[versionOffset + 3]) << 24)
        if raw == 0 {
            firmwareVersion = "—"
        } else {
            // ASUS renders each byte as hex, not decimal: 0x00080023 → "8.00.23".
            firmwareVersion = String(format: "%X.%02X.%02X",
                                     (raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
        }
        profileCount = Int(reply[8])
        effectMode = Int(reply[9])
        currentProfile = Int(reply[10])
    }
}

/// The models this tool knows how to talk to. Every ROG peripheral shares the
/// framing above, but the profile semantics were only verified on the Falcata,
/// so the tool deliberately does not offer itself for arbitrary ASUS hardware.
enum ROGModel: CaseIterable {
    case falcata

    var displayName: String {
        switch self {
        case .falcata: return "ROG Falcata"
        }
    }

    /// Wired and 2.4 GHz product ids report as different USB devices.
    var productIDs: Set<Int> {
        switch self {
        case .falcata: return [0x1C2F, 0x1C31]
        }
    }

    static func model(forProductID pid: Int) -> ROGModel? {
        allCases.first { $0.productIDs.contains(pid) }
    }

    static var allProductIDs: Set<Int> {
        allCases.reduce(into: Set<Int>()) { $0.formUnion($1.productIDs) }
    }
}

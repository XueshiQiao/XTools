import SwiftUI

/// What kind of thing a node is. Drives the icon and colour only — the tree's
/// shape never depends on this.
enum DeviceCategory: String {
    case host, thunderbolt, usb, pci, display, bluetooth, audio, camera, network, storage, group

    var symbol: String {
        switch self {
        case .host:        return "laptopcomputer"
        case .thunderbolt: return "bolt.fill"
        case .usb:         return "cable.connector"
        case .pci:         return "square.stack.3d.up"
        case .display:     return "display"
        case .bluetooth:   return "wave.3.right"
        case .audio:       return "speaker.wave.2.fill"
        case .camera:      return "camera.fill"
        case .network:     return "network"
        case .storage:     return "externaldrive"
        case .group:       return "folder"
        }
    }

    var color: Color {
        switch self {
        case .host:        return .gray
        case .thunderbolt: return .purple
        case .usb:         return .blue
        case .pci:         return .orange
        case .display:     return .indigo
        case .bluetooth:   return .cyan
        case .audio:       return .pink
        case .camera:      return .red
        case .network:     return .green
        case .storage:     return .brown
        case .group:       return .secondary
        }
    }
}

/// One entry in the device tree.
///
/// Deliberately generic: nothing here knows about any particular vendor, dock or
/// Mac model. Every field is filled in from whatever the system reported, and a
/// scanner that finds nothing simply contributes no children.
struct DeviceNode: Identifiable, Hashable {
    /// Stable across a rescan when the underlying identity is stable (registry
    /// entry id, display id, MAC address…), so SwiftUI keeps expansion state.
    let id: String
    var name: String
    /// One line shown next to the name — speed, address, resolution, whatever
    /// is the single most useful fact about this device.
    var detail: String?
    /// Short tags: "默认输出", "经雷雳隧道", "内置"…
    var badges: [String] = []
    var category: DeviceCategory
    /// Everything else worth showing, in display order. Also what the text
    /// export writes out.
    var properties: [DeviceProperty] = []
    var children: [DeviceNode] = []

    var hasChildren: Bool { !children.isEmpty }

    /// Total nodes underneath, for the "N 个设备" summaries.
    var descendantCount: Int {
        children.reduce(children.count) { $0 + $1.descendantCount }
    }

    static func == (a: DeviceNode, b: DeviceNode) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct DeviceProperty: Hashable {
    let label: String
    let value: String
}

// MARK: - Text export

enum DeviceTreeTextRenderer {

    /// Renders the tree the way it reads in a terminal — box-drawing characters,
    /// one device per line — so it can be pasted into a message, an issue, or
    /// handed to another agent.
    static func render(_ roots: [DeviceNode], title: String) -> String {
        var lines: [String] = [title]
        for root in roots {
            lines.append("")   // one blank line between top-level sections
            append(root, prefix: "", isLast: true, into: &lines, isRoot: true)
        }
        return lines.joined(separator: "\n")
    }

    private static func append(_ node: DeviceNode, prefix: String, isLast: Bool,
                               into lines: inout [String], isRoot: Bool = false) {
        let connector = isRoot ? "" : (isLast ? "└─ " : "├─ ")
        var line = prefix + connector + node.name
        if let detail = node.detail, !detail.isEmpty { line += "  —  \(detail)" }
        if !node.badges.isEmpty { line += "  [\(node.badges.joined(separator: ", "))]" }
        lines.append(line)

        let childPrefix = isRoot ? "" : prefix + (isLast ? "   " : "│  ")
        for (index, child) in node.children.enumerated() {
            append(child, prefix: childPrefix, isLast: index == node.children.count - 1, into: &lines)
        }
    }
}

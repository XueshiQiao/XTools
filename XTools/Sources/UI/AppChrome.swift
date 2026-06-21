import SwiftUI
import AppKit

// App "chrome": the shared visual language (aurora background, colored icon
// tiles, sidebar icons, status dot) reused by every tool's settings-style page.
// Lifted verbatim from AnyDrag's SettingsChrome so the two apps read as one
// family — only the page-specific enum was dropped (XTools builds its sidebar
// from the tool registry instead of a fixed enum).

/// Short alias for the bundle-localized string lookup. Flows through
/// `NSLocalizedString` (and therefore the `LocalizationOverride` bundle swap).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

// MARK: - Aurora background

extension View {
    /// The signature soft aurora wash, composited over an OPAQUE window base.
    /// Opaque matters for performance: paired with `.scrollContentBackground(.hidden)`
    /// a translucent wash would let window vibrancy re-sample the desktop every frame.
    func auroraBackground() -> some View {
        background(
            Color(nsColor: .windowBackgroundColor)
                .overlay(
                    LinearGradient(colors: [Color(.sRGB, red: 0.40, green: 0.55, blue: 1.00, opacity: 0.10),
                                            Color(.sRGB, red: 1.00, green: 0.55, blue: 0.85, opacity: 0.07),
                                            Color(.sRGB, red: 0.35, green: 0.85, blue: 0.70, opacity: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                .ignoresSafeArea()
        )
    }
}

// MARK: - Colored icon tiles

/// 26pt rounded gradient tile in `color`, with a hairline white edge.
private struct ColorTile: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(
                LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}
extension View { func colorTile(_ color: Color) -> some View { modifier(ColorTile(color: color)) } }

/// White SF Symbol on a colored tile.
struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .colorTile(color)
    }
}

/// A white template-rendered asset (e.g. a brand logo) on a colored tile.
struct AssetIconTile: View {
    let asset: String
    let color: Color
    var glyph: CGFloat = 15
    var body: some View {
        Image(asset).renderingMode(.template).resizable().scaledToFit()
            .frame(width: glyph, height: glyph)
            .foregroundStyle(.white)
            .colorTile(color)
    }
}

/// Leading "icon tile + text" label used in almost every settings row.
func iconLabel(_ symbol: String, _ color: Color, _ text: String) -> some View {
    HStack(spacing: 10) { IconTile(symbol: symbol, color: color); Text(text) }
}

/// A feature row's leading label: icon tile + title over a wrapping subtitle.
func featureLabel(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String) -> some View {
    HStack(spacing: 10) {
        IconTile(symbol: symbol, color: color)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sidebar row icon

/// A System-Settings-style sidebar row icon: a white SF Symbol on a colored
/// rounded square. Rasterized so row-selection vibrancy can't tint it.
struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                LinearGradient(colors: [color.opacity(0.98), color.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)))
            .drawingGroup()
    }
}

// MARK: - Status dot

/// Solid green when active, orange when off / blocked.
struct StatusDot: View {
    let active: Bool
    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .frame(width: 12, height: 12)
    }
}

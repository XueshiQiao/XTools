import SwiftUI
import AppKit
import Foundation

/// Geometry for the radial "wheel" presentation. The v1 defaults were locked with
/// the user against the HTML mockup (`docs/popbar-radial-mockup.html`): full ring,
/// icon+label per slice, outer 114 / inner 54 / gap 0 (seamless, hairline divider).
///
/// Kept as a value type so the wheel can later size itself to the action count
/// (more actions → larger radii) WITHOUT touching the view — the user explicitly
/// asked to keep these three knobs (inner/outer/gap) parameterized for that.
struct WheelLayout: Equatable {
    var outerRadius: CGFloat = 114
    var innerRadius: CGFloat = 54
    /// Gap between adjacent slices, in degrees. 0 = seamless ring (slices touch,
    /// separated only by the hairline divider).
    var gapDegrees: Double = 0
    /// Transparent breathing room around the ring so the window's drop shadow and a
    /// hovered slice's glow aren't clipped by the content edge.
    var pad: CGFloat = 10
    /// Max width for a slice's caption. Titles are user-editable free text, so the
    /// label MUST be bounded + truncated or a long title would render across
    /// adjacent slices / outside the ring (`lineLimit(1)` alone doesn't truncate
    /// without a width). Mirrors the capsule's fixed-tile caption width.
    var labelWidth: CGFloat = 64

    /// The square content side the wheel needs.
    var diameter: CGFloat { (outerRadius + pad) * 2 }
    /// Radius at which a slice's icon/label sits (the band's midline).
    var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
}

/// Which visual skin the wheel uses. Geometry + interaction are identical for both;
/// only the rendering differs. `.classic` = flat frosted sectors + accent fill.
/// `.liquid` = the locked bright "Liquid Glass" look (`docs/popbar-wheel-liquid.html`):
/// a translucent frosted ring (no borders), soft volumetric depth, and a clear-bright
/// liquid glow on the hovered compartment.
enum WheelSkin { case classic, liquid }

/// One equal slice of the ring as an annular sector. Used BOTH to fill the wedge
/// and (critically) as its `.contentShape`, so the WHOLE wedge hit-tests — never
/// just the icon (the user's standing rule about clickable areas).
struct RingSector: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        p.addArc(center: c, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// A flat ring (outer disc minus inner disc), used to mask layers to the ring band so
/// only the ring shows and the centre stays clear (the cursor/selection shows through
/// the hole). Even-odd filled so the inner circle punches a hole.
private struct Annulus: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outerRadius, y: c.y - outerRadius,
                                width: outerRadius * 2, height: outerRadius * 2))
        p.addEllipse(in: CGRect(x: c.x - innerRadius, y: c.y - innerRadius,
                                width: innerRadius * 2, height: innerRadius * 2))
        return p
    }
}

/// A full annular ring as a single path with a genuine hole — the outer circle and
/// inner circle wind in OPPOSITE directions, so the default (nonzero) fill leaves the
/// centre empty. Used as the clip shape for the system `.glassEffect(in:)` (which
/// uses nonzero winding), so the Liquid Glass renders as a ring with a clear centre.
struct RingShape: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        // Two SEPARATE closed circles (opposite winding) — no connecting line between
        // them, so there's no radial seam artifact along the ring.
        p.addArc(center: c, radius: outerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        p.closeSubpath()
        p.move(to: CGPoint(x: c.x + innerRadius, y: c.y))
        p.addArc(center: c, radius: innerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The radial "wheel" action presentation: the ring itself is sliced into N equal
/// sectors, one per action. Push the cursor outward onto a slice → the whole wedge
/// highlights; click it → the SAME `onAction` the capsule uses fires (the trigger/
/// LLM core is shared, only this UI differs).
struct WheelActionsView: View {

    let actions: [PopBarActionConfig]
    var layout = WheelLayout()
    var skin: WheelSkin = .classic
    let onAction: (PopBarActionConfig) -> Void

    /// id of the hovered slice (nil = none).
    @State private var hovered: String?

    var body: some View {
        let d = layout.diameter
        ZStack {
            // Decorative ring — strictly non-interactive. A wedge `Shape` fills the
            // whole square frame (it only DRAWS its sector), so if it hit-tested, the
            // topmost wedge would swallow every hover (the "stuck on 复制" bug). All
            // interaction lives on the dedicated clear layer below, never here.
            ringVisuals
                .allowsHitTesting(false)

            // The single interactive surface. The ring is ONE control: the slice is
            // resolved from the pointer's angle+radius (`sliceIndex`), so hover and tap
            // always agree with what's drawn and the highlight tracks the cursor across
            // slices. The eoFill annulus `contentShape` keeps the hollow centre +
            // outside click-through; a tap fires the SAME `onAction` the capsule uses.
            Color.clear
                .contentShape(Annulus(innerRadius: layout.innerRadius, outerRadius: layout.outerRadius),
                              eoFill: true)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let loc): hovered = sliceIndex(at: loc).map { actions[$0].id }
                    case .ended:           hovered = nil
                    }
                }
                .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { ev in
                    if let i = sliceIndex(at: ev.location) { onAction(actions[i]) }
                })
        }
        .frame(width: d, height: d)
    }

    // MARK: - Visuals (skin-specific; geometry shared)

    @ViewBuilder
    private var ringVisuals: some View {
        switch skin {
        case .classic: classicVisuals
        case .liquid:  liquidVisuals
        }
    }

    /// CLASSIC: frosted annulus backdrop + per-wedge accent fill + light icons.
    private var classicVisuals: some View {
        let d = layout.diameter
        return ZStack {
            VisualEffectBlur(cornerRadius: 0, bordered: false)
                .frame(width: layout.outerRadius * 2, height: layout.outerRadius * 2)
                .mask(Annulus(innerRadius: layout.innerRadius, outerRadius: layout.outerRadius)
                    .fill(style: FillStyle(eoFill: true)))

            ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                let a = angles(idx)
                let sector = RingSector(startAngle: a.start, endAngle: a.end,
                                        innerRadius: layout.innerRadius, outerRadius: layout.outerRadius)
                let hot = hovered == action.id
                sector
                    .fill(hot ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)))
                    .overlay(sector.stroke(Color.primary.opacity(0.12), lineWidth: 0.75))
            }

            ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                let a = angles(idx)
                let mid = a.mid.radians
                let hot = hovered == action.id
                VStack(spacing: 2) {
                    Image(systemName: action.iconSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(height: 18)   // fixed slot — same baseline fix as the capsule
                    Text(action.title)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: layout.labelWidth)
                }
                .foregroundStyle(hot ? Color.white : Color.primary)
                .position(x: d / 2 + cos(mid) * layout.midRadius,
                          y: d / 2 + sin(mid) * layout.midRadius)
            }
        }
        .frame(width: d, height: d)
    }

    /// LIQUID GLASS: on macOS 26+ this is the REAL system Liquid Glass material
    /// (`.glassEffect`) — genuinely translucent/refractive, clipped to a ring. On older
    /// systems it falls back to a hand-rolled translucent frost. Both keep dark icons
    /// and a gentle glow on the hovered compartment. Matches the locked mockup
    /// `docs/popbar-wheel-liquid.html` (which previewed the intended look).
    private var liquidVisuals: some View {
        let d = layout.diameter
        return ZStack {
            // NO drop shadow: a blurred ellipse behind a circular ring peeked out
            // unevenly and read as an irregular dark outline around the wheel.
            liquidMaterial

            // selected compartment indicator — a small dot (paired with bold label)
            if let i = hoveredIndex { selectionDot(i) }

            liquidIcons
        }
        .frame(width: d, height: d)
    }

    /// The ring material: the real macOS 26 Liquid Glass where available, the frost
    /// fallback otherwise.
    @ViewBuilder
    private var liquidMaterial: some View {
        let o = layout.outerRadius, ir = layout.innerRadius
        // `.glassEffect` only EXISTS in the macOS 26 SDK (Xcode 26 / Swift 6.2). A
        // runtime `#available` doesn't help the compiler resolve the symbol on older
        // SDKs, so gate it at compile time too — older toolchains build the fallback.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Plain system Liquid Glass clipped to the ring — NO mask hacks (those
            // created the inner/outer lines + fuzzy edge). Whatever edge remains here
            // is the material's own.
            Color.clear
                .frame(width: o * 2, height: o * 2)
                .glassEffect(.regular, in: RingShape(innerRadius: ir, outerRadius: o))
        } else {
            liquidFrostFallback
        }
        #else
        liquidFrostFallback
        #endif
    }

    /// Pre-macOS-26 fallback: a translucent frosted ring with soft gradient depth +
    /// sheen + a masked specular hotspot (no borders).
    private var liquidFrostFallback: some View {
        let o = layout.outerRadius, ir = layout.innerRadius, tube = o - ir, mid = layout.midRadius
        return ZStack {
            LiquidGlassBlur()
                .frame(width: o * 2, height: o * 2)
                .overlay(Color.white.opacity(0.10))
                .mask(Annulus(innerRadius: ir, outerRadius: o).fill(style: FillStyle(eoFill: true)))
            Circle().fill(depthGradient).frame(width: o * 2, height: o * 2)
            Circle().fill(sheenGradient).frame(width: o * 2, height: o * 2)
                .mask(Annulus(innerRadius: ir, outerRadius: o).fill(style: FillStyle(eoFill: true)))
                .blendMode(.overlay)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.95), .clear],
                                         center: .center, startRadius: 0, endRadius: tube * 0.85))
                .frame(width: tube * 1.7, height: tube * 1.7).blur(radius: 3).opacity(0.85)
                .offset(x: CGFloat(cos(-Double.pi * 0.62)) * mid,
                        y: CGFloat(sin(-Double.pi * 0.62)) * mid)
                .frame(width: o * 2, height: o * 2)
                .mask(Annulus(innerRadius: ir, outerRadius: o).fill(style: FillStyle(eoFill: true)))
        }
    }

    /// Icons + labels (dark, with a soft white halo for legibility on the light glass).
    private var liquidIcons: some View {
        let d = layout.diameter, mid = layout.midRadius
        return ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
            let a = angles(idx)
            let m = a.mid.radians
            let hot = hovered == action.id
            VStack(spacing: 2) {
                Image(systemName: action.iconSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(action.title)
                    // selected = BOLD label (the only text change; non-selected stays medium)
                    .font(.system(size: 9, weight: hot ? .bold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: layout.labelWidth)
            }
            .foregroundStyle(hot ? Color(red: 0.05, green: 0.09, blue: 0.16)
                                 : Color(red: 0.17, green: 0.21, blue: 0.27))
            .shadow(color: .white.opacity(0.6), radius: 2)
            // NO scaleEffect — selecting a slice must NOT enlarge it (per the user).
            .position(x: d / 2 + cos(m) * mid, y: d / 2 + sin(m) * mid)
        }
    }

    private var hoveredIndex: Int? {
        guard let id = hovered else { return nil }
        return actions.firstIndex { $0.id == id }
    }

    /// Selected-compartment highlight. Deliberately SIMPLE + neutral (no colour, no
    /// "water-drop" blob, per the user): a soft, even brightening of the hovered
    /// wedge, soft-edged and masked to the ring. (The hovered icon also scales up — see
    /// `liquidIcons` — which carries most of the selection feedback.)
    /// Selected-compartment indicator: a small neutral dot near the hovered slice's
    /// outer edge. Paired with the slice's label going bold (see `liquidIcons`). No
    /// size change / glow / colour, per the user.
    @ViewBuilder
    private func selectionDot(_ i: Int) -> some View {
        let d = layout.diameter, o = layout.outerRadius
        let a = angles(i), m = a.mid.radians
        Circle()
            .fill(Color(red: 0.10, green: 0.13, blue: 0.20))
            .frame(width: 5, height: 5)
            .position(x: d / 2 + cos(m) * (o - 11), y: d / 2 + sin(m) * (o - 11))
    }

    private var depthGradient: RadialGradient {
        let o = layout.outerRadius, ir = layout.innerRadius, tube = o - ir, mid = layout.midRadius
        return RadialGradient(gradient: Gradient(stops: [
            .init(color: .clear, location: max(0, (ir - 1) / o)),
            .init(color: Color(red: 0.35, green: 0.45, blue: 0.63).opacity(0.30), location: (ir + 1.5) / o),
            .init(color: .clear, location: (ir + tube * 0.34) / o),
            .init(color: .white.opacity(0.34), location: mid / o),
            .init(color: .clear, location: (o - tube * 0.32) / o),
            .init(color: Color(red: 0.31, green: 0.39, blue: 0.59).opacity(0.34), location: (o - 1) / o),
            .init(color: .clear, location: 1),
        ]), center: .center, startRadius: 0, endRadius: o)
    }

    private var sheenGradient: RadialGradient {
        let o = layout.outerRadius
        return RadialGradient(gradient: Gradient(stops: [
            .init(color: .white.opacity(0.70), location: 0),
            .init(color: .white.opacity(0.10), location: 0.42),
            .init(color: .clear, location: 0.70),
        ]), center: UnitPoint(x: 0.5, y: 0.06), startRadius: 0, endRadius: o * 1.25)
    }

    // MARK: - Geometry (shared by both skins)

    /// Which slice the point `p` (in the view's local space) falls in, or nil when
    /// it's in the hollow centre / outside the ring. Drives both hover and tap, so
    /// they can never disagree with what's drawn.
    private func sliceIndex(at p: CGPoint) -> Int? {
        let n = actions.count
        guard n > 0 else { return nil }
        let c = layout.diameter / 2
        let dx = p.x - c, dy = p.y - c
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist >= layout.innerRadius, dist <= layout.outerRadius else { return nil }
        let step = 360.0 / Double(n)
        // atan2 here matches the wedge drawing: 0° = +x (right), +clockwise (y-down).
        // Slices start at the top (−90°), so shift the angle by +90 before bucketing.
        var rel = atan2(dy, dx) * 180 / .pi + 90
        rel.formTruncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        return min(Int(rel / step), n - 1)
    }

    /// Angular span of slice `i`: equal divisions starting at the top (−90°), going
    /// clockwise (SwiftUI's y-down space). `mid` is where its icon/label sits.
    private func angles(_ i: Int) -> (start: Angle, end: Angle, mid: Angle) {
        let n = max(actions.count, 1)
        let step = 360.0 / Double(n)
        let base = -90.0 + Double(i) * step
        let g = gapDegrees(step)
        return (.degrees(base + g / 2), .degrees(base + step - g / 2), .degrees(base + step / 2))
    }

    /// Clamp the gap so it can never exceed the slice itself (avoids inverted wedges
    /// at large gap + many slices).
    private func gapDegrees(_ step: Double) -> Double {
        min(layout.gapDegrees, step * 0.8)
    }
}

/// A forced-light frosted material for the liquid-glass ring. Pins the appearance to
/// `.aqua` so the ring reads bright/translucent (the locked look) regardless of the
/// system's dark mode, while still blurring whatever is behind the popup.
private struct LiquidGlassBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .aqua)
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.appearance = NSAppearance(named: .aqua)
    }
}

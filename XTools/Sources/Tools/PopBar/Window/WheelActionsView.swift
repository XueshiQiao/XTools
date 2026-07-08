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
    /// Whether each slice shows its SF Symbol icon (user setting).
    var showIcons: Bool = true
    /// Whether each slice shows its text label (user setting).
    var showLabels: Bool = true

    /// The square content side the wheel needs.
    var diameter: CGFloat { (outerRadius + pad) * 2 }
    /// Radius at which a slice's icon/label sits (the band's midline).
    var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
}

/// Which visual skin the wheel uses. Geometry + interaction are identical for both;
/// only the rendering differs. `.classic` = flat frosted sectors + accent fill.
/// `.liquid` = the locked "Liquid Glass" look (`docs/popbar-wheel-liquid.html`): a
/// translucent frosted ring (no borders) with soft volumetric depth that adapts to the
/// popup's appearance — bright ring + dark glyphs in light mode, dark ring + light
/// glyphs in dark mode.
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
    /// Hide the ring when the pointer moves outside it (user setting; wheel styles only).
    var autoHideOnExit: Bool = false
    /// Called when the pointer leaves the ring and `autoHideOnExit` is on.
    var onExitRing: () -> Void = {}
    let onAction: (PopBarActionConfig) -> Void

    /// Whether the popup is in dark mode. The locked mockup
    /// (`docs/popbar-wheel-liquid.html`) defined BOTH a light and a dark variant, but
    /// the first implementation only baked in the light palette — so in dark mode the
    /// dark-navy glyphs vanished against the dark ring.
    ///
    /// IMPORTANT: this reads the SYSTEM dark-mode setting directly, NOT SwiftUI's
    /// `@Environment(\.colorScheme)` nor the window/app `effectiveAppearance`. On
    /// macOS 26 the Liquid Glass material promotes the popup WINDOW to a light "glass"
    /// appearance, which flips BOTH the SwiftUI colorScheme AND the effective
    /// appearance of the popup's content to light even while the system is in dark
    /// mode (verified: dark-branch glyph tint + ring scrim never applied when keyed off
    /// either). The global `AppleInterfaceStyle` default is the raw OS setting, immune
    /// to that per-window promotion, so it's the reliable dark signal. The popup is
    /// transient (rebuilt on every show), so not auto-reacting to a live switch is
    /// fine — the next popup picks up the new value.
    private var isDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// id of the hovered slice (nil = none).
    @State private var hovered: String?
    /// Becomes true once the pointer has been within the ring at least once, so we only
    /// auto-hide on EXIT — not immediately when the wheel is clamped near a screen edge
    /// and the cursor starts outside the ring. Reset each time the wheel appears.
    @State private var enteredRing = false
    /// Last hover location (view-`.local`), used by the `.ended` handler to tell a
    /// genuine outward exit from a spurious one: only a pointer that was actually
    /// at/past the ring's outer edge when the hover ended counts as leaving.
    @State private var lastHover: CGPoint?

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
            //
            // The ring is PAINTED here (a near-invisible fill) rather than `Color.clear`
            // so the NSWindow has real, non-transparent backing pixels across the band.
            // Without that, the window server passes a mouse-DOWN straight THROUGH to the
            // app behind before our `hitTest` ever runs — which is exactly why the Liquid
            // Glass skin's clicks fell through (its `.glassEffect` is composited server-
            // side and leaves the app backing clear; hover still worked because tracking
            // areas aren't subject to click-through). The classic skin only worked by
            // accident, via its opaque `VisualEffectBlur`/sector fills. Painting the
            // interactive layer itself makes click capture identical for EVERY skin (UI
            // differs, the click path is one and the same). Masked to the annulus so the
            // hollow centre + corners stay click-through.
            Annulus(innerRadius: layout.innerRadius, outerRadius: layout.outerRadius)
                .fill(Color.white.opacity(0.02), style: FillStyle(eoFill: true))
                // Tracked (hit-tested + hover) as a FULL disc out to outerRadius —
                // deliberately NOT the same hollow shape the fill paints. If the tracked
                // shape had the same hole, sliding from the ring back toward the centre
                // would cross a shape boundary and SwiftUI would report the hover as
                // "ended" — indistinguishable from actually exiting past the outer edge
                // (this was the bug: centre → ring → centre falsely auto-hid the wheel).
                // Making the hole part of the SAME tracked region means `.ended` only
                // ever fires on a genuine outward exit. `innerRadius: 0` makes `Annulus`
                // act as a plain disc; taps that land in the hole still no-op below
                // (`sliceIndex` returns nil there), and real clicks never reach here
                // anyway — AppKit's own ring-only hit-test (`FirstMouseHostingView`)
                // already excludes the hole so they pass through to the app behind.
                .contentShape(Annulus(innerRadius: 0, outerRadius: layout.outerRadius), eoFill: true)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let loc):
                        hovered = sliceIndex(at: loc).map { actions[$0].id }
                        // Anywhere within outerRadius (band OR hole) counts as "on the
                        // wheel". Arm only once the pointer has actually been here, so a
                        // wheel clamped near a screen edge — where the cursor can start
                        // outside it — doesn't vanish on appear.
                        enteredRing = true
                        lastHover = loc
                    case .ended:
                        hovered = nil
                        // Only auto-hide on a GENUINE outward exit: the pointer's last
                        // tracked position must be at/past the ring's OUTER edge.
                        // `onContinuousHover` tracks the whole square frame and ALSO fires
                        // `.ended` spuriously while the pointer is still well inside the
                        // wheel — notably when the ring is recycled/rebuilt for a new
                        // selection with the cursor near its centre (a view/tracking-area
                        // teardown, not a real exit). Logging the exit distance proved the
                        // split: false exits sit at dist ≪ outer (often dead centre), real
                        // exits at dist ≥ outer. Gating on the distance drops the spurious
                        // ones — the "centre→ring→centre / recycled-ring vanish" bug.
                        let c = d / 2
                        let exitDist = lastHover.map { hypot($0.x - c, $0.y - c) } ?? 0
                        let genuineExit = exitDist >= layout.outerRadius
                        if autoHideOnExit && enteredRing && genuineExit { onExitRing() }
                    }
                }
                .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { ev in
                    if let i = sliceIndex(at: ev.location) { onAction(actions[i]) }
                })
        }
        .frame(width: d, height: d)
        .onAppear { enteredRing = false }   // re-arm the auto-hide for each fresh wheel
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
                    if layout.showIcons {
                        Image(systemName: action.iconSymbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(height: 18)   // fixed slot — same baseline fix as the capsule
                    }
                    if layout.showLabels {
                        Text(action.title)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: layout.labelWidth)
                    }
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
    /// systems it falls back to a hand-rolled translucent frost. Both adapt to the
    /// popup's appearance: dark-navy glyphs on the bright ring in light mode, near-white
    /// glyphs on the dark ring in dark mode. Matches the locked mockup
    /// `docs/popbar-wheel-liquid.html` (which previewed both variants).
    private var liquidVisuals: some View {
        let d = layout.diameter
        let o = layout.outerRadius, ir = layout.innerRadius
        return ZStack {
            // NO drop shadow: a blurred ellipse behind a circular ring peeked out
            // unevenly and read as an irregular dark outline around the wheel.
            liquidMaterial

            // Dark mode: the macOS 26 Liquid Glass samples whatever sits behind the
            // popup, so over dark content the ring goes near-black and the glyphs lose
            // all contrast (the reported bug). A controlled dark scrim on the band
            // pins the ring to a predictable dark glass — light glyphs then read on ANY
            // backdrop, not just the one the glass happened to sample. Light mode keeps
            // the bright glass untouched. Masked to the annulus so the hollow centre
            // stays clear.
            if isDark {
                Annulus(innerRadius: ir, outerRadius: o)
                    .fill(Color.black.opacity(0.34), style: FillStyle(eoFill: true))
                    .frame(width: o * 2, height: o * 2)
            }

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
        let dark = isDark
        return ZStack {
            LiquidGlassBlur(dark: dark)
                .frame(width: o * 2, height: o * 2)
                .overlay(Color.white.opacity(dark ? 0.08 : 0.10))
                .mask(Annulus(innerRadius: ir, outerRadius: o).fill(style: FillStyle(eoFill: true)))
            Circle().fill(depthGradient).frame(width: o * 2, height: o * 2)
            Circle().fill(sheenGradient).frame(width: o * 2, height: o * 2)
                .mask(Annulus(innerRadius: ir, outerRadius: o).fill(style: FillStyle(eoFill: true)))
                // Overlay pops highlights on the bright glass; soft-light keeps the
                // dark ring from blowing out (mirrors the mockup's per-theme blend).
                .blendMode(dark ? .softLight : .overlay)
            Circle().fill(RadialGradient(colors: [.white.opacity(dark ? 0.55 : 0.95), .clear],
                                         center: .center, startRadius: 0, endRadius: tube * 0.85))
                .frame(width: tube * 1.7, height: tube * 1.7).blur(radius: 3).opacity(0.85)
                .offset(x: CGFloat(cos(-Double.pi * 0.62)) * mid,
                        y: CGFloat(sin(-Double.pi * 0.62)) * mid)
                .frame(width: o * 2, height: o * 2)
                .mask(Annulus(innerRadius: ir, outerRadius: o).fill(style: FillStyle(eoFill: true)))
        }
    }

    /// Icons + labels. Light mode: dark-navy ink with a soft white halo on the bright
    /// glass. Dark mode: near-white glyphs with a soft dark halo — the mockup's dark
    /// variant — so they stay legible on the system's dark Liquid Glass.
    private var liquidIcons: some View {
        let d = layout.diameter, mid = layout.midRadius
        let dark = isDark
        return ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
            let a = angles(idx)
            let m = a.mid.radians
            let hot = hovered == action.id
            VStack(spacing: 2) {
                if layout.showIcons {
                    Image(systemName: action.iconSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(height: 18)
                }
                if layout.showLabels {
                    Text(action.title)
                        // selected = BOLD label (the only text change; non-selected stays medium)
                        .font(.system(size: 9, weight: hot ? .bold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: layout.labelWidth)
                }
            }
            .foregroundStyle(glyphColor(hot: hot, dark: dark))
            // Halo lifts the glyphs off the glass: a white glow on the bright ring,
            // a soft dark glow on the dark ring (mirrors the mockup's per-theme
            // text-shadow — light: white .6, dark: black .55).
            .shadow(color: dark ? .black.opacity(0.55) : .white.opacity(0.6),
                    radius: dark ? 1.5 : 2)
            // NO scaleEffect — selecting a slice must NOT enlarge it (per the user).
            .position(x: d / 2 + cos(m) * mid, y: d / 2 + sin(m) * mid)
        }
    }

    /// Glyph tint for the liquid ring, per appearance (`docs/popbar-wheel-liquid.html`
    /// tokens). Light: locked dark-navy ink (`--glyph`/`--glyphHot`). Dark: near-white
    /// glyphs (`rgba(255,255,255,.92)` → white when hot) so nothing washes out on the
    /// dark Liquid Glass.
    private func glyphColor(hot: Bool, dark: Bool) -> Color {
        if dark {
            return hot ? .white : Color.white.opacity(0.92)
        }
        return hot ? Color(red: 0.05, green: 0.09, blue: 0.16)
                   : Color(red: 0.17, green: 0.21, blue: 0.27)
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
            .fill(isDark ? Color.white.opacity(0.9) : Color(red: 0.10, green: 0.13, blue: 0.20))
            .frame(width: 5, height: 5)
            .position(x: d / 2 + cos(m) * (o - 11), y: d / 2 + sin(m) * (o - 11))
    }

    private var depthGradient: RadialGradient {
        let o = layout.outerRadius, ir = layout.innerRadius, tube = o - ir, mid = layout.midRadius
        // Cross-section edges + mid highlight, per appearance (mockup `edge`/`edge2`/
        // `midGlow`). Light: cool blue-grey rims. Dark: near-black rims so the tube
        // reads as recessed glass, with a fainter white mid-line.
        let edge  = isDark ? Color(red: 0.03, green: 0.05, blue: 0.09).opacity(0.66)
                           : Color(red: 0.35, green: 0.45, blue: 0.63).opacity(0.30)
        let edge2 = isDark ? Color(red: 0.02, green: 0.04, blue: 0.07).opacity(0.70)
                           : Color(red: 0.31, green: 0.39, blue: 0.59).opacity(0.34)
        let midGlow = Color.white.opacity(isDark ? 0.14 : 0.34)
        return RadialGradient(gradient: Gradient(stops: [
            .init(color: .clear, location: max(0, (ir - 1) / o)),
            .init(color: edge, location: (ir + 1.5) / o),
            .init(color: .clear, location: (ir + tube * 0.34) / o),
            .init(color: midGlow, location: mid / o),
            .init(color: .clear, location: (o - tube * 0.32) / o),
            .init(color: edge2, location: (o - 1) / o),
            .init(color: .clear, location: 1),
        ]), center: .center, startRadius: 0, endRadius: o)
    }

    private var sheenGradient: RadialGradient {
        let o = layout.outerRadius
        // Top-down specular sheen, dimmer in dark mode (mockup: top white .75 → .5).
        return RadialGradient(gradient: Gradient(stops: [
            .init(color: .white.opacity(isDark ? 0.50 : 0.70), location: 0),
            .init(color: .white.opacity(isDark ? 0.06 : 0.10), location: 0.42),
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

/// The frosted material for the liquid-glass ring (pre-macOS-26 fallback). Pins the
/// appearance to `.aqua` in light mode / `.darkAqua` in dark mode so the frost matches
/// the popup's appearance — the locked mockup defines both — while still blurring
/// whatever is behind the popup.
private struct LiquidGlassBlur: NSViewRepresentable {
    var dark: Bool = false
    private var pinned: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = pinned
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.appearance = pinned
    }
}

import SwiftUI

/// Geometry for the wheel's SECOND ring — the submenu that unfolds outside the
/// main ring when the pointer rests on an action that owns children.
///
/// The rule was locked with the user against `docs/popbar-wheel-submenu-mockup.html`:
///
///  - every child occupies the SAME fixed angle (`stepDegrees`, 40° by default);
///  - the whole run is centred on the parent slice's angle bisector, so the
///    submenu always reads as "hanging off" that one slice;
///  - once the run would wrap past a full turn it closes up into a COMPLETE outer
///    ring, re-divided evenly among the children (there is nowhere else to put
///    them, and a >360° arc would overlap itself).
///
/// Angles are plain degrees in the same frame the rest of the wheel uses:
/// `-90` is twelve o'clock and the values grow clockwise (SwiftUI's y-down space).
struct SubmenuPlan: Equatable {
    /// How many children the parent has.
    let count: Int
    /// The parent slice's bisector — the run's axis of symmetry.
    let midDegrees: Double
    /// Angular width of one child.
    let step: Double
    /// Angular width of the whole run (≤ 360).
    let span: Double
    /// True once the run filled a whole turn and closed up into a ring.
    let isFullRing: Bool
    /// Leading edge of the first child.
    let start: Double

    init(count: Int, midDegrees: Double, stepDegrees: Double) {
        self.count = count
        self.midDegrees = midDegrees
        var step = max(stepDegrees, 1)
        var span = Double(count) * step
        let full = count > 0 && span >= 360
        if full {
            step = 360 / Double(count)
            span = 360
        }
        self.step = step
        self.span = span
        self.isFullRing = full
        self.start = midDegrees - span / 2
    }

    func angles(_ i: Int) -> (start: Double, end: Double, mid: Double) {
        let s = start + Double(i) * step
        return (s, s + step, s + step / 2)
    }

    /// Which child a point at `degrees` falls in, or nil when the angle is outside
    /// the run. Mirrors `angles(_:)` exactly so hover, tap and drawing can never
    /// disagree.
    func index(atDegrees degrees: Double) -> Int? {
        guard count > 0 else { return nil }
        var rel = (degrees - start).truncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        guard rel <= span else { return nil }
        return min(Int(rel / step), count - 1)
    }

    /// Interior boundaries between children — where the hairline dividers go. A
    /// full ring has one more than an arc (its two ends meet).
    var dividerCount: Int {
        guard count > 1 else { return 0 }
        return isFullRing ? count : count - 1
    }
}

/// An annular sector whose four corners are rounded — the shape the user picked
/// for the submenu ("一整条", rounded ends rather than a flat cut).
///
/// Each corner is a true tangent arc: it meets the outer arc, the inner arc and
/// the two radial edges without a crease, so the outline stays clean at any size
/// (this is real geometry, not a blurred/stroked fake). The radius is clamped down
/// automatically when the band is thin or the sector is narrow, so a two-child
/// submenu can never fold in on itself.
///
/// `animatableData` carries the two angles AND the two radii, which is what makes
/// the unfold animation silky: SwiftUI interpolates the path itself, so the ring
/// grows out of the main ring and slides around it rather than popping in.
struct RoundedRingSector: Shape {
    /// Degrees, same frame as the wheel (`-90` = twelve o'clock, clockwise).
    var startAngle: Double
    var endAngle: Double
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(startAngle, endAngle), .init(innerRadius, outerRadius)) }
        set {
            startAngle = newValue.first.first
            endAngle = newValue.first.second
            innerRadius = newValue.second.first
            outerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r0 = innerRadius, r1 = outerRadius
        var p = Path()
        guard r1 > r0 + 1 else { return p }

        let a0 = startAngle * .pi / 180
        let a1 = endAngle * .pi / 180
        let span = a1 - a0
        guard span > 0.0005 else { return p }

        func pt(_ r: CGFloat, _ a: Double) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        }

        // A closed ring: two circles wound in OPPOSITE directions, so the default
        // non-zero fill leaves the centre empty. No corners to round.
        if span >= 2 * .pi - 0.002 {
            p.addArc(center: c, radius: r1, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            p.closeSubpath()
            p.move(to: CGPoint(x: c.x + r0, y: c.y))
            p.addArc(center: c, radius: r0, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
            p.closeSubpath()
            return p
        }

        // Shrink the corner until it genuinely fits: never more than half the band,
        // and never so wide that the two ends would cross in the middle of a narrow
        // sector (which is what would produce a folded-over path).
        var cr = min(cornerRadius, (r1 - r0) / 2 - 0.5)
        var e0 = 0.0, e1 = 0.0
        var fits = false
        for _ in 0..<40 {
            guard cr > 0.6 else { break }
            e1 = asin(min(max(Double(cr / (r1 - cr)), -1), 1))
            e0 = asin(min(max(Double(cr / (r0 + cr)), -1), 1))
            if span > 2 * max(e0, e1) + 0.02 { fits = true; break }
            cr *= 0.82
        }

        guard fits, cr > 0.6 else {
            // Square-cut fallback (degenerate sizes only).
            p.addArc(center: c, radius: r1, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            p.addArc(center: c, radius: r0, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
            p.closeSubpath()
            return p
        }

        // Corner-arc centres sit one radius in from the edge they round, which is
        // what makes every join tangent.
        let cOuterEnd   = pt(r1 - cr, a1 - e1)
        let cInnerEnd   = pt(r0 + cr, a1 - e0)
        let cInnerStart = pt(r0 + cr, a0 + e0)
        let cOuterStart = pt(r1 - cr, a0 + e1)
        // Where each corner meets a radial edge: the foot of the perpendicular.
        let dOuter = CGFloat((Double(r1 - cr) * Double(r1 - cr) - Double(cr) * Double(cr)).squareRoot())
        let dInner = CGFloat((Double(r0 + cr) * Double(r0 + cr) - Double(cr) * Double(cr)).squareRoot())

        let half = Double.pi / 2
        p.move(to: pt(r1, a0 + e1))
        // Outer arc, then round down onto the trailing radial edge.
        p.addArc(center: c, radius: r1, startAngle: .radians(a0 + e1), endAngle: .radians(a1 - e1), clockwise: false)
        p.addArc(center: cOuterEnd, radius: cr,
                 startAngle: .radians(a1 - e1), endAngle: .radians(a1 + half), clockwise: false)
        p.addLine(to: pt(dInner, a1))
        p.addArc(center: cInnerEnd, radius: cr,
                 startAngle: .radians(a1 + half), endAngle: .radians(a1 + .pi - e0), clockwise: false)
        // Inner arc back the other way, then round up onto the leading radial edge.
        p.addArc(center: c, radius: r0, startAngle: .radians(a1 - e0), endAngle: .radians(a0 + e0), clockwise: true)
        p.addArc(center: cInnerStart, radius: cr,
                 startAngle: .radians(a0 + .pi + e0), endAngle: .radians(a0 + 1.5 * .pi), clockwise: false)
        p.addLine(to: pt(dOuter, a0))
        p.addArc(center: cOuterStart, radius: cr,
                 startAngle: .radians(a0 + 1.5 * .pi), endAngle: .radians(a0 + 2 * .pi + e1), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The hairline dividers between neighbouring children, as one path. `start` and
/// `step` animate, so the dividers travel with the ring instead of snapping to the
/// new position a frame early.
struct SubmenuDividers: Shape {
    var start: Double
    var step: Double
    var count: Int
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { .init(start, step) }
        set { start = newValue.first; step = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        guard count > 0, outerRadius > innerRadius else { return p }
        for i in 1...count {
            let a = (start + Double(i) * step) * .pi / 180
            p.move(to: CGPoint(x: c.x + (innerRadius + 1) * CGFloat(cos(a)),
                               y: c.y + (innerRadius + 1) * CGFloat(sin(a))))
            p.addLine(to: CGPoint(x: c.x + (outerRadius - 1) * CGFloat(cos(a)),
                                  y: c.y + (outerRadius - 1) * CGFloat(sin(a))))
        }
        return p
    }
}

/// Live bridge from the SwiftUI wheel to the AppKit hit-test in `PopBarPanel`.
///
/// The panel is a square window whose hit-test is scoped to the ring band, so the
/// transparent area around it stays click-through. When a submenu unfolds, the
/// wheel genuinely occupies more of that square — this box tells AppKit how much,
/// so a click on a child lands on us, and the area outside goes back to being
/// click-through the moment the submenu closes.
///
/// A plain reference box, not observable: it is written by the wheel during hover
/// and read by `hitTest` on the same (main) thread; nothing re-renders off it.
final class WheelHitRegion {
    /// Radius the wheel currently occupies, or 0 for "just the main ring".
    var outerRadius: CGFloat = 0
}

/// One item on the second ring. Deliberately a plain value (not a
/// `PopBarActionConfig`) so `SubmenuRing` below depends on nothing but SwiftUI and
/// can be rendered — and checked frame by frame — outside the app.
struct SubmenuItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
}

/// How the hovered child is marked. The two skins mark it differently: the classic
/// ring fills the wedge with the accent colour, the liquid ring uses a small
/// neutral dot (a coloured fill was explicitly rejected for that skin).
enum SubmenuHighlight: Equatable {
    case fill(Color)
    case dot(Color)
}

/// The ENTIRE second ring, as one animatable unit.
///
/// `unfold` (0 = folded away under the main ring, 1 = fully out) and `span` are the
/// view's `animatableData`, so SwiftUI re-runs `body` with interpolated values on
/// every frame and every element — the glass arc, the dividers, the hover mark and
/// the labels — is derived from those same two numbers.
///
/// That single-source-of-truth is the whole point. The first version animated each
/// element separately, which went wrong in two different ways at once: the divider
/// lines had no animatable path of their own, so they snapped to their final
/// positions on frame one while the arc was still growing; and the labels each
/// carried a staggered delay, so they arrived after the arc had stopped. Together
/// they read as the ring unfolding twice. Nothing here can drift out of step,
/// because nothing here animates on its own.
struct SubmenuRing<Material: View>: View, Animatable {

    /// 0 = folded under the main ring · 1 = fully out.
    var unfold: Double
    /// Angular width of the whole run at this instant (0 while folded).
    var span: Double

    /// Axis the run is centred on: the parent slice's bisector, in degrees with
    /// −90 at twelve o'clock.
    ///
    /// Animated, so moving from one group to the next is ONE movement (the ring
    /// travels and resizes together) rather than a jump followed by a resize. The
    /// caller hands this in "unwrapped" — it may run past ±180 — because the
    /// interpolation is a plain lerp between two numbers, and a wrapped angle would
    /// make the ring take the long way round the wheel.
    var mid: Double
    var items: [SubmenuItem]
    /// True when the run filled a whole turn: the two ends meet, so there is one
    /// more divider than there are gaps in an arc. Passed in rather than derived
    /// from `span`, which is mid-animation for most frames.
    var isFullRing: Bool

    /// Square the wheel draws into.
    var canvas: CGFloat
    /// Outer edge of the MAIN ring — where the second ring folds back to.
    var ringOuterRadius: CGFloat
    var seam: CGFloat
    var thickness: CGFloat
    var corner: CGFloat

    var showIcons: Bool
    var showLabels: Bool
    var labelWidth: CGFloat
    var hoveredIndex: Int?
    var highlight: SubmenuHighlight
    var dividerColor: Color
    var glyphColor: (Bool) -> Color
    var glyphShadow: Color?

    var material: (RoundedRingSector) -> Material

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { .init(unfold, .init(span, mid)) }
        set {
            unfold = newValue.first
            span = newValue.second.first
            mid = newValue.second.second
        }
    }

    /// While folded the band sits exactly where the main ring is, so it reads as
    /// sliding out from UNDER it rather than growing out of thin air.
    private var radii: (inner: CGFloat, outer: CGFloat) {
        let tuck = CGFloat(1 - unfold) * (seam + thickness)
        let inner = ringOuterRadius + seam - tuck
        return (inner, inner + thickness)
    }

    private var shape: RoundedRingSector {
        let r = radii
        return RoundedRingSector(startAngle: mid - span / 2, endAngle: mid + span / 2,
                                 innerRadius: r.inner, outerRadius: r.outer,
                                 cornerRadius: corner)
    }

    private var step: Double { items.isEmpty ? 0 : span / Double(items.count) }

    var body: some View {
        let r = radii
        let arc = shape
        ZStack {
            material(arc)
            hoverMark(arc, radii: r)
            dividers(radii: r)
            glyphs(radii: r)
        }
        .frame(width: canvas, height: canvas)
        .opacity(unfold)
        // NOTHING in here animates on its own, and that is the whole design.
        //
        // Every frame is drawn from the interpolated numbers above, so no element
        // can run on its own schedule. Two real bugs came from letting them:
        // the divider lines had no animatable path and snapped to their final
        // angles on frame one, and — because a `.position` change inside an
        // animated transaction animates itself — the labels of the group you just
        // left kept drifting and fading toward the new one after the arc had
        // already arrived. Clearing the transaction kills both, and also the
        // default insert/remove fade on the labels when the item list is swapped.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func hoverMark(_ arc: RoundedRingSector, radii r: (inner: CGFloat, outer: CGFloat)) -> some View {
        // Held back until the ring is most of the way out — a hover mark drawn on a
        // half-unfolded arc lands next to a label that isn't there yet — and FADED
        // in rather than switched on, so it can't read as a second movement.
        if let i = hoveredIndex, items.indices.contains(i), unfold > 0.5 {
            let a0 = mid - span / 2 + Double(i) * step
            let fade = min(1, (unfold - 0.5) / 0.3)
            switch highlight {
            case .fill(let color):
                RoundedRingSector(startAngle: a0, endAngle: a0 + step,
                                  innerRadius: r.inner, outerRadius: r.outer, cornerRadius: 0)
                    .fill(color)
                    .clipShape(arc)
                    .frame(width: canvas, height: canvas)
                    .opacity(fade)
            case .dot(let color):
                let m = (a0 + step / 2) * .pi / 180
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .position(x: canvas / 2 + cos(m) * (r.outer - 10),
                              y: canvas / 2 + sin(m) * (r.outer - 10))
                    .opacity(fade)
            }
        }
    }

    @ViewBuilder
    private func dividers(radii r: (inner: CGFloat, outer: CGFloat)) -> some View {
        let count = items.count > 1 ? (isFullRing ? items.count : items.count - 1) : 0
        if count > 0 {
            SubmenuDividers(start: mid - span / 2, step: step, count: count,
                            innerRadius: r.inner, outerRadius: r.outer)
                .stroke(dividerColor, lineWidth: 0.75)
                .frame(width: canvas, height: canvas)
        }
    }

    private func glyphs(radii r: (inner: CGFloat, outer: CGFloat)) -> some View {
        let midR = (r.inner + r.outer) / 2
        return ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
            let a = (mid - span / 2 + (Double(i) + 0.5) * step) * .pi / 180
            let hot = i == hoveredIndex
            VStack(spacing: 2) {
                if showIcons {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(height: 16)   // fixed slot — same baseline fix as the capsule
                }
                if showLabels {
                    Text(item.title)
                        .font(.system(size: 9, weight: hot ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: labelWidth)
                }
            }
            .foregroundStyle(glyphColor(hot))
            .shadow(color: glyphShadow ?? .clear, radius: glyphShadow == nil ? 0 : 2)
            // A touch of scale, continuous in `unfold` — it settles WITH the ring
            // rather than as a second, separate movement.
            .scaleEffect(0.92 + 0.08 * unfold)
            .position(x: canvas / 2 + cos(a) * midR, y: canvas / 2 + sin(a) * midR)
        }
    }
}

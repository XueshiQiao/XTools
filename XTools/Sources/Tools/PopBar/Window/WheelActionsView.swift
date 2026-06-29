import SwiftUI
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

/// A flat ring (outer disc minus inner disc), used to mask the frosted backdrop so
/// only the ring is blurred and the centre stays clear (the cursor/selection shows
/// through the hole). Even-odd filled so the inner circle punches a hole.
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

/// The radial "wheel" action presentation: the ring itself is sliced into N equal
/// sectors, one per action. Push the cursor outward onto a slice → the whole wedge
/// highlights; click it → the SAME `onAction` the capsule uses fires (the trigger/
/// LLM core is shared, only this UI differs).
struct WheelActionsView: View {

    let actions: [PopBarActionConfig]
    var layout = WheelLayout()
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

    /// The decorative ring: frosted annulus backdrop + filled wedges + centroid
    /// icon/label per slice. No interaction lives here (see `body`).
    private var ringVisuals: some View {
        let d = layout.diameter
        return ZStack {
            // Frosted ring backdrop, masked to the annulus so the hollow centre is clear.
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

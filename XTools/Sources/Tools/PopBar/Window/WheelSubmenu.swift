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

    /// Whether `degrees` falls inside the run, with `tolerance` degrees of slack at
    /// each end.
    ///
    /// The slack is what makes it useful for deciding "is the pointer heading for
    /// this ring": someone cutting the corner toward the first child passes just
    /// outside the run's edge, and a strict test would call that a miss.
    func contains(degrees: Double, tolerance: Double = 0) -> Bool {
        guard count > 0 else { return false }
        if isFullRing { return true }
        var rel = (degrees - start).truncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        // Also accept the slack BEFORE the start, which wraps to just under 360.
        if rel > 360 - tolerance { rel -= 360 }
        return rel >= -tolerance && rel <= span + tolerance
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

/// Is the pointer travelling OUT to the second ring, or just going around the
/// first one?
///
/// On a ring the two are easy to tell apart, and telling them apart is the whole
/// job: heading for a child is movement ALONG the radius, while browsing the
/// first level is movement AROUND it — tangential, at a roughly constant
/// distance from the centre. Asking only "did the distance grow?" cannot separate
/// them, because a hand sweeping round the wheel pivots at the wrist, not at the
/// wheel's centre, so the distance drifts in and out the whole way round and a
/// stray outward pixel looks exactly like setting off for a child.
///
/// So this asks for a DIRECTION instead: the movement has to point outward and
/// lie within `maxAngle` of straight out. A sweep around the ring is ~90° off
/// that and never qualifies, however much the radius wobbles.
///
/// Direction alone is not enough, because a slow sweep's wobble can point outward
/// for a while. The other half is `OutwardRun`, which measures how far the pointer
/// has actually pushed.
///
/// This is the same idea as the slope test in `jQuery-menu-aim` (the library that
/// came out of taking Amazon's mega-menu apart), which compares the direction of
/// the mouse vector against the directions to the submenu's corners. A ring only
/// makes it cheaper: "toward the submenu" is just "away from the centre".
enum WheelAim {

    /// The cone can afford to be generous — reaching a child at the far end of a
    /// wide arc is a genuinely slanted move, and a tight cone would refuse exactly
    /// the gesture this exists to protect. What keeps a sweep out is not the width
    /// of the cone but `OutwardRun`, which the caller checks alongside this.
    ///
    /// - Parameters:
    ///   - from: the pointer's position a fixed stretch of TIME ago, not the
    ///     immediately previous sample, and not a fixed number of samples ago.
    ///     A longer baseline keeps hand tremor from deciding the answer; making it
    ///     a duration rather than a sample count is what makes the answer the same
    ///     for a slow reach and a quick one, instead of depending on how much
    ///     ground the hand happened to cover between two events.
    ///   - minDistance: movement shorter than this says nothing about intent.
    ///   - maxAngle: how far off straight-out still counts, in degrees.
    static func isHeadingOutward(from: CGPoint, to: CGPoint, centre: CGPoint,
                                 minDistance: CGFloat = 4,
                                 maxAngle: Double = 70) -> Bool {
        let move = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let distance = (move.x * move.x + move.y * move.y).squareRoot()
        guard distance >= minDistance else { return false }

        func radius(_ p: CGPoint) -> CGFloat {
            let dx = p.x - centre.x, dy = p.y - centre.y
            return (dx * dx + dy * dy).squareRoot()
        }
        // Over this stretch the pointer must at least not have come back in.
        guard radius(to) >= radius(from) else { return false }

        // The outward direction taken at the MIDPOINT of the movement, not at
        // either end. Measured at the destination a long slanted move flatters
        // itself — the move itself has swung the radial direction round to meet it —
        // and measured at the start it does the opposite. The midpoint is the
        // direction that actually describes the segment travelled.
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let out = CGPoint(x: mid.x - centre.x, y: mid.y - centre.y)
        let radius = (out.x * out.x + out.y * out.y).squareRoot()
        guard radius > 1 else { return false }   // at the centre there is no "outward"

        // How much of the movement went straight out, as a fraction of all of it.
        let outward = (move.x * out.x + move.y * out.y) / (radius * distance)
        return outward >= CGFloat(cos(maxAngle * .pi / 180))
    }

    /// How far the pointer has pushed OUTWARD since it last turned back.
    ///
    /// This is the half of the test that a sweep around the first ring can never
    /// fake, and the reason is that the two gestures differ in kind, not in speed:
    /// a sweep's distance from the centre **wobbles within bounds** — a hand pivots
    /// at the wrist, not at the wheel's centre, so the radius drifts in and out the
    /// whole way round without going anywhere — while a reach has to **cross the
    /// whole gap** between the rings, some forty points, and never comes back.
    ///
    /// So the anchor only ever moves when the pointer genuinely turns around. A
    /// wobble therefore never accumulates past its own peak-to-peak swing, however
    /// slowly the hand is moving, while a reach keeps adding to the total until it
    /// clears the bar.
    ///
    /// Measuring PROGRESS rather than SPEED is what makes this indifferent to how
    /// fast the hand is going, which is the whole point: the protection switches on
    /// at the same place along the gesture whether the pointer is ambling or
    /// flicking. A pointer that merely slowed down is not a pointer that changed
    /// its mind.
    ///
    /// (Two simpler rules were tried against simulated gestures first and both
    /// failed, in opposite directions. A fixed count of samples measures however
    /// much ground the hand happened to cover between two events, so a quick reach
    /// was protected and a slow one was not. A fixed stretch of time fixes that and
    /// breaks the other side: over any window short enough to react in time, a slow
    /// sweep's wobble is indistinguishable from a slow reach.)
    struct OutwardRun {

        /// Where the current push started, and the furthest out it has got. Both are
        /// needed: the anchor is what progress is measured FROM, and the peak is what
        /// says whether the pointer has turned back. Watching only the anchor cannot
        /// see a turn at all — coming back in from 130 to 110 is still far outside an
        /// anchor at 84, so a pointer that had already arrived and then started
        /// browsing sideways would go on counting as "reaching".
        private var anchor: CGFloat?
        private var peak: CGFloat?

        /// Feed every sample's distance from the centre; get back how far out the
        /// pointer has pushed since this run began.
        ///
        /// - Parameter slack: how far back from its furthest point the pointer has to
        ///   come before it counts as having turned around.
        ///
        ///   This has to clear a shaky hand. A hand tremor is a few hertz and a few
        ///   points wide, and it is there during a reach just as much as during a
        ///   sweep — so too tight a value reads every tremor dip as "changed their
        ///   mind", restarts the run, and a slow reach by an unsteady hand never adds
        ///   up to anything. Six points was the smallest value that left every
        ///   simulated reach protected, tremor included, while still letting a sweep's
        ///   own wobble restart the run before it could accumulate.
        mutating func progress(radius: CGFloat, slack: CGFloat = 6) -> CGFloat {
            guard let started = anchor, let furthest = peak else {
                anchor = radius
                peak = radius
                return 0
            }
            if radius < furthest - slack {   // turned back — this push is over
                anchor = radius
                peak = radius
                return 0
            }
            if radius > furthest { peak = radius }
            return radius - started
        }

        mutating func reset() {
            anchor = nil
            peak = nil
        }
    }

    /// The rolling answer to "is the pointer on its way out to the open ring?".
    ///
    /// Owns both halves of the test and the memory they need, so the whole
    /// judgement is one pure value that can be driven by a list of positions and
    /// timestamps — which is what its tests do. The view above it is left with only
    /// the things that are genuinely SwiftUI: when to restart the run, and what to
    /// do with a `true`.
    ///
    /// Feed it every hover sample. It answers `true` while BOTH hold:
    ///
    ///  - the pointer has pushed `minPush` points outward since it last turned back
    ///    (`OutwardRun`), and
    ///  - its movement across the last `window` of time points outward
    ///    (`isHeadingOutward`).
    ///
    /// Neither is enough alone, and they fail different gestures, which is the
    /// point: direction alone lets a slow sweep's wobble through, and progress alone
    /// would keep saying yes once the pointer had arrived and started browsing
    /// sideways out there.
    struct Tracker {

        /// How far back the direction test looks.
        ///
        /// It has to be a stretch of TIME rather than a count of samples, because a
        /// count measures different amounts of movement depending on how fast the
        /// hand is going. Three samples is about 25ms at a normal event rate: enough
        /// travel to measure when the pointer is moving quickly, and barely two
        /// pixels when it is not — which is how an earlier version came to protect a
        /// quick reach for a child and not a slow one.
        ///
        /// A longer baseline also makes the direction test stricter rather than
        /// looser, which is the opposite of what one might fear: wobble is
        /// back-and-forth and cancels out over a stretch, so what is left is the
        /// gesture the hand actually made. Over two samples a single wobbly step can
        /// look radial; over 150ms of sliding around the ring, the net movement is
        /// unmistakably tangential.
        var window: TimeInterval = 0.15

        /// Ignore a baseline shorter than this. At the very start of a gesture the
        /// window holds almost nothing, and the direction of a two-pixel move is
        /// noise.
        var minSpan: TimeInterval = 0.08

        /// How far out the pointer must have pushed before it counts as reaching for
        /// a child, in points.
        ///
        /// It has to clear the widest wobble a sweep around the first ring can
        /// produce — simulated gestures put a sloppy sweep's peak-to-peak swing near
        /// seventeen points, which is what sets the floor — and stay well under the
        /// gap between the rings, which is about forty. So it arms a little under
        /// halfway across, with the pointer still inside its own slice and short of
        /// the boundary it would have to cross for the ring to be stolen.
        var minPush: CGFloat = 18

        private struct Sample {
            let point: CGPoint
            let at: Date
        }

        private var samples: [Sample] = []
        private var run = OutwardRun()

        /// Begin a fresh run. The caller does this whenever a different ring becomes
        /// the open one — including when none is — because the push that matters is
        /// the one from a group's own slice out to ITS children. Without it the run
        /// would still be anchored wherever the pointer entered the wheel, which is
        /// the hollow centre the wheel opens around: by the time the pointer reached
        /// the first ring it would already be eighty points "outward", every sweep
        /// would clear the bar, and the test would be dead on arrival.
        mutating func restart() {
            samples.removeAll()
            run.reset()
        }

        /// Feed one hover sample; get back whether the pointer is reaching outward.
        mutating func isReaching(to point: CGPoint, at now: Date, centre: CGPoint) -> Bool {
            samples.append(Sample(point: point, at: now))
            // Drop what has aged out. The sample just appended can never be dropped,
            // so the buffer is never empty; after a pause long enough to empty
            // everything else it holds only that one, the baseline is zero-length,
            // and `minSpan` rejects it — which is right, because a pointer that
            // stopped is not on its way anywhere.
            let cutoff = now.addingTimeInterval(-window)
            samples.removeAll { $0.at < cutoff }
            // A backstop, in case a clock ever moves backwards: the window normally
            // holds a dozen or two samples, never this many.
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }

            let dx = point.x - centre.x, dy = point.y - centre.y
            let pushed = run.progress(radius: (dx * dx + dy * dy).squareRoot())

            guard let earliest = samples.first else { return false }
            guard now.timeIntervalSince(earliest.at) >= minSpan else { return false }
            // Has the pointer actually GONE anywhere outward? This is the half a
            // sweep around the first ring fails: its radius wobbles within bounds
            // and never adds up, however slowly the hand moves.
            guard pushed >= minPush else { return false }
            // …and is it POINTING out along the radius, rather than around it?
            return WheelAim.isHeadingOutward(from: earliest.point, to: point, centre: centre)
        }
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
    ///
    /// Deliberately the VISIBLE reach and not the overshoot slack beyond it: the
    /// slack exists so the pointer can stray past the ring without the wheel
    /// dismissing itself, and there is nothing drawn out there to click. Including
    /// it here would swallow clicks on whatever the user can actually see behind
    /// the wheel's transparent margin.
    var outerRadius: CGFloat = 0

    /// How far the cursor is from the wheel's centre RIGHT NOW, in the wheel's own
    /// units — set by the panel, because AppKit can answer this at any moment and
    /// SwiftUI can only report where the pointer was when it last sampled.
    ///
    /// That difference is a whole frame of travel, which is the difference between
    /// knowing someone left and guessing.
    var cursorRadius: (() -> CGFloat?)?
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

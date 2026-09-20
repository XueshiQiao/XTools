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

    // MARK: - Second ring (submenu)

    /// Transparent gap between the main ring's outer edge and the submenu ring.
    /// User-adjustable (`popbar.wheel.subSeam`).
    var submenuSeam: CGFloat = 6
    /// Band width of the submenu ring. User-adjustable (`popbar.wheel.subThickness`).
    var submenuThickness: CGFloat = 52
    /// Corner radius of the submenu arc's four corners. Locked at 14 with the user
    /// against `docs/popbar-wheel-submenu-mockup.html` (the "一整条 + 圆角" option).
    var submenuCorner: CGFloat = 14
    /// Angular width of ONE child. Locked at 40° with the user: narrower than a
    /// parent slice, so a 3-4 item submenu stays a compact arc rather than sweeping
    /// half the ring.
    var submenuStepDegrees: Double = 40

    var submenuInnerRadius: CGFloat { outerRadius + submenuSeam }
    var submenuOuterRadius: CGFloat { submenuInnerRadius + submenuThickness }
    /// Radius at which a child's icon/label sits.
    var submenuMidRadius: CGFloat { (submenuInnerRadius + submenuOuterRadius) / 2 }

    /// The square content side the wheel needs.
    var diameter: CGFloat { (outerRadius + pad) * 2 }
    /// The square side needed once a submenu can unfold.
    ///
    /// The window is sized for the EXPANDED state up front rather than resized when
    /// a submenu opens: an NSWindow resize mid-hover rebuilds the tracking areas,
    /// which AppKit reports as a spurious `mouseExited` — exactly the signal that
    /// auto-hide treats as "the pointer left the ring", so the wheel would vanish
    /// the moment a submenu opened. The extra area costs nothing: it is transparent
    /// and stays click-through (see `WheelHitRegion`).
    /// How far past the second ring's visible edge still counts as being on the
    /// wheel.
    ///
    /// Reaching for a child is a push outward, and a push overshoots — the ring is
    /// about fifty points wide and the hand does not stop on a line. Without this
    /// the wheel is gone the instant the pointer passes the edge by a pixel, and the
    /// whole selection starts again.
    ///
    /// It is deliberately a DISTANCE and not a delay. A delay would have to be paid
    /// every time the wheel is dismissed on purpose, which makes getting rid of it
    /// feel sticky; this costs nothing, because the pointer either is within reach
    /// of the ring or it is not, and the answer is known the moment it moves.
    var overshootSlack: CGFloat = 26

    var expandedDiameter: CGFloat { (submenuOuterRadius + overshootSlack + pad) * 2 }
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
    /// Live bridge to the panel's AppKit hit-test, so the clickable region grows
    /// with the submenu ring and shrinks back when it closes.
    var hitRegion: WheelHitRegion?
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
    /// The submenu currently on screen. RETAINED through the closing animation —
    /// clearing it outright would make the second ring disappear instantly instead
    /// of folding back under the main ring.
    @State private var submenu: OpenSubmenu?
    /// Whether that submenu is unfolded. Flipping this (not `submenu`) is what the
    /// open/close animation interpolates.
    @State private var expanded = false
    /// Bumped on every open/collapse so an unfold scheduled for the next pass can be
    /// cancelled if the pointer has moved on by then.
    @State private var openToken = 0
    /// When the ring was last told to fold shut. Used to tell "opening from nothing"
    /// from "opening while the previous one is still visibly folding away".
    @State private var collapsedAt: Date?
    /// When the ring will have finished moving. Until then a child cannot be
    /// picked — see `hit(at:)`.
    @State private var settledAt: Date?
    /// Whether the pointer is on its way out to the open ring. Owns the sample
    /// window and the outward-progress run; see `WheelAim.Tracker`.
    @State private var aim = WheelAim.Tracker()
    /// Which group's ring `aim` is currently measuring against, so the run can
    /// restart whenever that changes.
    @State private var aimRunParent: String?
    /// While this is in the future, the pointer is treated as being on its way OUT
    /// to the open ring, and slices it crosses do not steal it.
    @State private var aimingUntil: Date?
    /// Scopes the one re-check scheduled for when the aim grace runs out.
    @State private var aimToken = 0
    /// id of the hovered child on the second ring (nil = none).
    /// Becomes true once the pointer has been within the ring at least once, so we only
    /// auto-hide on EXIT — not immediately when the wheel is clamped near a screen edge
    /// and the cursor starts outside the ring. Reset each time the wheel appears.
    @State private var enteredRing = false
    @State private var hoveredChild: String?
    /// Last hover location (view-`.local`), used by the `.ended` handler to tell a
    /// genuine outward exit from a spurious one: only a pointer that was actually
    /// at/past the ring's outer edge when the hover ended counts as leaving.
    @State private var lastHover: CGPoint?

    var body: some View {
        let d = canvas
        ZStack {
            // The submenu ring is drawn UNDER the main ring, so unfolding reads as
            // the second ring sliding out from beneath the first rather than being
            // pasted on top of it.
            submenuVisuals
                .allowsHitTesting(false)

            // Decorative ring — strictly non-interactive. A wedge `Shape` fills the
            // whole square frame (it only DRAWS its sector), so if it hit-tested, the
            // topmost wedge would swallow every hover (the "stuck on 复制" bug). All
            // interaction lives on the dedicated clear layer below, never here.
            ringVisuals
                .allowsHitTesting(false)

            interactiveSurface
        }
        .frame(width: d, height: d)
        .onAppear {
            // Re-arm the auto-hide and start closed for each fresh wheel.
            enteredRing = false
            submenu = nil
            expanded = false
            settledAt = nil
            aimingUntil = nil
            aim.restart()
            aimRunParent = nil
            openToken &+= 1
            hitRegion?.outerRadius = 0
        }
    }

    /// How opaque the invisible backing has to be.
    ///
    /// Not zero, because a fully transparent window pixel is not the window's: a
    /// click on it goes to whatever is behind. Kept as low as it can be, and — more
    /// importantly — never painted anywhere the ring does not already cover, because
    /// anywhere else it IS visible: two parts in 255 still reads as a grey film on a
    /// dark backdrop.
    private var backingOpacity: Double { 0.008 }

    /// The single interactive surface. The wheel is ONE control: which slice (or
    /// which child on the second ring) the pointer is on is resolved from its
    /// angle + radius in `hit(at:)`, so hover and tap always agree with what's
    /// drawn, on both rings.
    ///
    /// The bands are PAINTED here (a near-invisible fill) rather than `Color.clear`
    /// so the NSWindow has real, non-transparent backing pixels across them.
    /// Without that, the window server passes a mouse-DOWN straight THROUGH to the
    /// app behind before our `hitTest` ever runs — which is exactly why the Liquid
    /// Glass skin's clicks fell through (its `.glassEffect` is composited server-
    /// side and leaves the app backing clear; hover still worked because tracking
    /// areas aren't subject to click-through). The classic skin only worked by
    /// accident, via its opaque `VisualEffectBlur`/sector fills.
    private var interactiveSurface: some View {
        let d = canvas
        return ZStack {
            // EXACTLY the ring band, never a point further. Anything painted past
            // the ring's outer edge is not covered by anything and the user sees it —
            // a faint ring in the seam, plainly visible on a dark backdrop.
            //
            // Which is why the seam is NOT covered, even though the pointer crossing
            // it is what ends the hover: an event landing on a window pixel with
            // nothing painted in it is not ours to receive. That is handled where it
            // does no harm instead — an exit reported while the pointer is still
            // demonstrably on the wheel is ignored outright (see the hover `.ended`
            // branch), so the ring stays open, the child stays lit, and hover picks
            // up again by itself about seven milliseconds later on the far side.
            Annulus(innerRadius: layout.innerRadius, outerRadius: layout.outerRadius)
                .fill(Color.white.opacity(backingOpacity), style: FillStyle(eoFill: true))
            // Same treatment for the open submenu, painted to the ARC only so the
            // transparent space around it stays click-through.
            if let open = submenu, expanded {
                submenuShape(open).fill(Color.white.opacity(backingOpacity))
            }
        }
        // Tracked (hit-tested + hover) as a FULL disc out to the wheel's widest
        // reach — deliberately NOT the same hollow shape the fill paints. If the
        // tracked shape had the same hole, sliding from the ring back toward the
        // centre would cross a shape boundary and SwiftUI would report the hover as
        // "ended" — indistinguishable from actually exiting past the outer edge
        // (this was the bug: centre → ring → centre falsely auto-hid the wheel).
        // Making the hole part of the SAME tracked region means `.ended` only ever
        // fires on a genuine outward exit. `innerRadius: 0` makes `Annulus` act as a
        // plain disc; taps that land in the hole still no-op below (`hit(at:)`
        // returns `.hole` there), and real clicks never reach here anyway — AppKit's
        // own ring-only hit-test (`FirstMouseHostingView`) already excludes the hole
        // so they pass through to the app behind.
        .contentShape(Annulus(innerRadius: 0, outerRadius: trackedReach), eoFill: true)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let loc):
                // Anywhere within the wheel's reach (band OR hole) counts as "on the
                // wheel". Arm only once the pointer has actually been here, so a
                // wheel clamped near a screen edge — where the cursor can start
                // outside it — doesn't vanish on appear.
                enteredRing = true
                lastHover = loc
                updateAim(at: loc)
                let result = hit(at: loc)
                apply(result)
            case .ended:
                // How far the wheel can reach AT ALL — not how far it happens to
                // reach this instant.
                //
                // Hovering a group means its ring is coming out, so the pointer
                // heading outward is heading somewhere that will be part of the
                // wheel. Asking whether the ring is out YET made the answer depend
                // on a race: push out during the moment between the hover and the
                // ring appearing and the pointer was judged against the first ring's
                // edge, which it had already passed. Judging it against the widest
                // the wheel can ever be has no such moment — and it is the same
                // number the hover tracking itself uses, so "inside the tracked
                // area" and "on the wheel" can no longer disagree.
                let reach = trackedReach
                // Only auto-hide on a GENUINE outward exit: the pointer's last
                // tracked position must be at/past the wheel's outer edge.
                // `onContinuousHover` tracks the whole square frame and ALSO fires
                // `.ended` spuriously while the pointer is still well inside the
                // wheel — notably when the ring is recycled/rebuilt for a new
                // selection (a view/tracking-area teardown, not a real exit).
                // Logging the exit distance proved the split: false exits sit well
                // inside the edge, real ones at or past it.
                //
                // The edge is whatever the wheel reaches NOW. It used to be the main
                // ring's outer radius always, which was right while there was only
                // one ring and wrong the moment a second one opened outside it: with
                // a group open the wheel genuinely reaches ~58 points further, so
                // every spurious exit out there — including one in the transparent
                // seam BETWEEN the rings, two points past the old line — was read as
                // "they left" and took the whole wheel down, mid-reach for a child.
                // Measured: an exit reported at r=117.8 with the submenu open and the
                // pointer not moving.
                // Where the cursor IS, asked of AppKit — not where this view last
                // saw it. Hover only reports on a sample, so the last one before an
                // exit sits up to a frame of travel inside the edge, and a brisk
                // flick away leaves it far enough inside to read as "still here".
                // Measured before this: four exits in thirty-two were misread that
                // way and left the wheel on screen with a frozen highlight until
                // something else replaced it. The fallback is the old guess, for the
                // case where the panel is gone by the time this runs.
                let c = d / 2
                let exitDist = hitRegion?.cursorRadius?()
                    ?? lastHover.map { hypot($0.x - c, $0.y - c) }
                    ?? 0
                let genuineExit = exitDist >= reach
                // A spurious exit changes NOTHING. It used to tear the hover state
                // down and fold the submenu away regardless, and only the auto-hide
                // was gated on this — which is why, once the wheel stopped vanishing,
                // the symptom became "the second ring appears and instantly goes
                // away again": the teardown was still running, and with the ring gone
                // every position past the main ring then read as off the wheel, so it
                // could not come back either. Measured: exits reported at r≈117 with
                // the pointer moving steadily outward and not going anywhere near the
                // real edge at 174.
                guard genuineExit else { break }

                // A real exit, but not acted on yet: nothing is torn down until the
                // grace has run out, so a pointer that overshot and came straight
                // back finds the wheel exactly as it left it — same group open, same
                // child under the cursor.
                hovered = nil
                hoveredChild = nil
                aim.restart()
                aimRunParent = nil
                collapseSubmenu()
                if autoHideOnExit && enteredRing { onExitRing() }
            }
        }
        .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { ev in
            switch hit(at: ev.location) {
            case .child(let i):
                if let open = submenu, open.children.indices.contains(i) {
                    onAction(open.children[i])
                }
            case .parent(let i):
                // A group runs nothing — tapping it just leaves its ring open.
                if !actions[i].hasChildren { onAction(actions[i]) }
            case .hole, .keep, .outside:
                break
            }
        })
    }

    // MARK: - Visuals (skin-specific; geometry shared)

    @ViewBuilder
    private var ringVisuals: some View {
        ZStack {
            switch skin {
            case .classic: classicVisuals
            case .liquid:  liquidVisuals
            }
            submenuTicks
        }
    }

    /// A short mark at the outer edge of every slice that owns children, so it is
    /// visible which slices have a second ring to push out to. Nothing else on the
    /// wheel says so — without it a group looks like a dud action.
    private var submenuTicks: some View {
        let d = canvas
        return ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
            if action.hasChildren {
                let mid = angles(idx).mid.degrees
                let hot = expanded && submenu?.parentID == action.id
                RingSector(startAngle: .degrees(mid - 5.5), endAngle: .degrees(mid + 5.5),
                           innerRadius: layout.outerRadius - 5, outerRadius: layout.outerRadius - 2)
                    .fill(hot ? AnyShapeStyle(Color.accentColor)
                              : AnyShapeStyle(tickColor))
                    .frame(width: d, height: d)
            }
        }
    }

    private var tickColor: Color {
        switch skin {
        case .classic: return Color.primary.opacity(0.45)
        case .liquid:  return isDark ? Color.white.opacity(0.55)
                                     : Color(red: 0.10, green: 0.13, blue: 0.20).opacity(0.5)
        }
    }

    /// CLASSIC: frosted annulus backdrop + per-wedge accent fill + light icons.
    private var classicVisuals: some View {
        let d = canvas
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
        let d = canvas
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
        let d = canvas, mid = layout.midRadius
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
        let d = canvas, o = layout.outerRadius
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

    /// What the point `p` (in the view's local space) is over. One resolver for
    /// BOTH rings, so hover, tap and drawing can never disagree.
    private enum WheelHit {
        /// The hollow centre.
        case hole
        /// A slice of the main ring.
        case parent(Int)
        /// A child on the open submenu ring.
        case child(Int)
        /// Still on the wheel, but on no slice — change nothing. This is what keeps
        /// the seam between the two rings, and the empty space past the ends of a
        /// short submenu arc, from slamming the submenu shut under the pointer.
        case keep
        /// Off the wheel entirely.
        case outside
    }

    private func hit(at p: CGPoint) -> WheelHit {
        let c = canvas / 2
        let dx = p.x - c, dy = p.y - c
        let dist = (dx * dx + dy * dy).squareRoot()

        if dist < layout.innerRadius { return .hole }

        if dist <= layout.outerRadius {
            let n = actions.count
            guard n > 0 else { return .keep }
            let step = 360.0 / Double(n)
            // atan2 here matches the wedge drawing: 0° = +x (right), +clockwise (y-down).
            // Slices start at the top (−90°), so shift the angle by +90 before bucketing.
            var rel = atan2(dy, dx) * 180 / .pi + 90
            rel.formTruncatingRemainder(dividingBy: 360)
            if rel < 0 { rel += 360 }
            return .parent(min(Int(rel / step), n - 1))
        }

        guard expanded, let open = submenu else { return .outside }
        // The transparent seam between the two rings: crossing it on the way out to
        // a child must not read as leaving.
        if dist <= layout.submenuInnerRadius { return .keep }
        if dist <= layout.submenuOuterRadius + layout.overshootSlack {
            // NOT while the ring is still moving. `plan` describes the ring once it
            // has finished unfolding, but for the third of a second it spends
            // growing out — or travelling to another group — the wedges are drawn
            // somewhere else entirely: narrower, tucked further in, and packed
            // around the axis. Answering from the finished plan during that window
            // hands back a child the pointer is nowhere near, and a click then runs
            // THAT action. So the second ring simply isn't live until it has
            // settled; `scheduleSettleCheck` re-asks the moment it is, so a pointer
            // that arrived early and stopped still lights up on its own.
            guard let settled = settledAt, Date() >= settled else { return .keep }
            // Same frame the plan is built in: degrees where −90 is twelve o'clock.
            let degrees = atan2(dy, dx) * 180 / .pi
            if let i = open.plan.index(atDegrees: degrees) { return .child(i) }
            return .keep
        }
        return .outside
    }

    /// How long a single outward sample keeps other slices from stealing the ring.
    /// Renewed by every further outward sample, so it is a grace period, not a
    /// lockout: stop moving, or turn back, and it lapses.
    ///
    /// 0.3s is the same figure `jQuery-menu-aim` uses (its `DELAY`), which is the
    /// implementation of this trick that came out of taking Amazon's mega-menu
    /// apart — so it is a number with some mileage on it rather than a guess.
    private var aimGrace: TimeInterval { 0.3 }

    /// Decide whether the pointer is currently ON ITS WAY to the open ring.
    ///
    /// This is the radial version of the trick Amazon's mega-menu uses (the "aim
    /// triangle"): a submenu sits further out than the thing that opened it, so
    /// reaching a child on the far side of the arc means cutting diagonally across
    /// the slices in between. Judging each slice the moment the pointer touches it
    /// closes the ring under the user's hand, every time, for the crime of taking
    /// the short route.
    ///
    /// A ring makes the test simpler than a rectangle does. Two things together
    /// mean "heading out there": the pointer is getting FURTHER from the centre,
    /// and it is pointed somewhere within the arc's own angular span (plus a little
    /// slack for corner-cutting). While both hold, whatever slice it crosses is
    /// passed through rather than acted on.
    ///
    /// The grace period is the escape hatch, and it is why this cannot trap anyone:
    /// it only ever renews while the pointer keeps moving outward. Pause on another
    /// group, or turn back toward the centre, and it lapses within
    /// `aimGrace` — and a check scheduled for that moment re-reads the position, so
    /// a pointer that stopped does not have to be nudged to take effect.
    private func updateAim(at point: CGPoint) {
        let c = canvas / 2
        let centre = CGPoint(x: c, y: c)
        // Keyed on the open ring rather than done inside `openSubmenu`, because that
        // is called on every hover over an already-open group and no-ops; restarting
        // the run there would restart it on every sample and nothing could ever add
        // up. `expanded` is part of the key because `collapseSubmenu` deliberately
        // KEEPS `submenu` set while the ring folds away.
        let openRing = expanded ? submenu?.parentID : nil
        if aimRunParent != openRing {
            aimRunParent = openRing
            aim.restart()
        }
        let reaching = aim.isReaching(to: point, at: Date(), centre: centre)

        guard reaching, expanded, let open = submenu else { return }
        // …and aimed at the arc that is actually open, not away from it.
        let degrees = atan2(point.y - c, point.x - c) * 180 / .pi
        guard open.plan.contains(degrees: degrees, tolerance: 12) else { return }

        aimingUntil = Date().addingTimeInterval(aimGrace)
        aimToken &+= 1
        let token = aimToken
        DispatchQueue.main.asyncAfter(deadline: .now() + aimGrace + 0.02) {
            guard aimToken == token, expanded, let point = lastHover else {
                return
            }
            apply(hit(at: point))
        }
    }

    /// Whether a hover on `id` should be ignored because the pointer is only
    /// passing over it on its way to the open ring.
    private func isPassingThrough(_ id: String) -> Bool {
        guard expanded, let open = submenu, open.parentID != id else { return false }
        guard let until = aimingUntil else { return false }
        return Date() < until
    }

    /// Apply a hover result to the two highlight states + the submenu.
    private func apply(_ result: WheelHit) {
        switch result {
        case .parent(let i):
            guard actions.indices.contains(i) else { return }
            let action = actions[i]
            // Cutting the corner toward a child: this slice is on the way, not the
            // destination. Leave everything as it is.
            if isPassingThrough(action.id) {
                return
            }
            if hovered != action.id { hovered = action.id }
            if hoveredChild != nil { hoveredChild = nil }
            if action.hasChildren {
                openSubmenu(for: action, at: i)
            } else {
                collapseSubmenu()
            }
        case .child(let i):
            guard let open = submenu, open.children.indices.contains(i) else { return }
            let id = open.children[i].id
            if hoveredChild != id { hoveredChild = id }
        case .keep:
            if hoveredChild != nil { hoveredChild = nil }
        case .hole, .outside:
            if hovered != nil { hovered = nil }
            if hoveredChild != nil { hoveredChild = nil }
            collapseSubmenu()
        }
    }

    private func openSubmenu(for action: PopBarActionConfig, at index: Int) {
        let target = angles(index).mid.degrees
        // Tell AppKit the wheel now occupies the wider disc, so a click on a child
        // lands on us instead of falling through to the app behind.
        hitRegion?.outerRadius = layout.submenuOuterRadius

        if expanded, let current = submenu {
            // Already out: travel to the new group the SHORT way round.
            let next = makeSubmenu(action, mid: current.midDegrees + shortWay(from: current.midDegrees, to: target))
            if submenu != next {
                withAnimation(openSpring) { submenu = next }
                armSettle()
            }
            return
        }

        // Still visibly folding away at the previous group (the pointer crossed a
        // plain slice on its way here and the spring has not settled): carry the
        // ring ACROSS rather than snapping the leftover to the new axis, which would
        // read as it teleporting mid-fade.
        if let current = submenu, let at = collapsedAt,
           Date().timeIntervalSince(at) < 0.35, !current.children.isEmpty {
            let next = makeSubmenu(action, mid: current.midDegrees + shortWay(from: current.midDegrees, to: target))
            openToken &+= 1
            withAnimation(openSpring) {
                submenu = next
                expanded = true
            }
            armSettle()
            return
        }

        // Folded and settled: put it in place FIRST — invisible, zero width, already
        // on this slice's axis — and unfold on the NEXT pass. Doing both at once
        // would make the ring travel from wherever the last group was while it
        // grew, so it would appear to slide in from across the wheel.
        let next = makeSubmenu(action, mid: target)
        if submenu != next { submenu = next }
        openToken &+= 1
        let token = openToken
        DispatchQueue.main.async {
            // Cancelled if the pointer moved off (collapse bumps the token) or moved
            // to a different group (which schedules its own).
            guard openToken == token, let open = submenu, !open.children.isEmpty else { return }
            withAnimation(openSpring) { expanded = true }
            armSettle()
        }
    }

    /// How long the ring keeps moving after it is told to. The spring is
    /// `response: 0.36, dampingFraction: 0.9`, which is done well inside this.
    private var settleDelay: TimeInterval { 0.45 }

    /// Mark the ring as "still moving", then re-run the hit test once it isn't.
    ///
    /// The second half matters: hover only reports when the pointer MOVES, so
    /// someone who pushed out onto a child early and stopped there would sit on an
    /// unlit wedge until they jiggled the mouse.
    private func armSettle() {
        openToken &+= 1
        let token = openToken
        settledAt = Date().addingTimeInterval(settleDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay + 0.02) {
            guard openToken == token, expanded, let point = lastHover else {
                return
            }
            apply(hit(at: point))
        }
    }

    /// Signed turn from `from` to `to`, always the shorter way round (±180° at most).
    ///
    /// The result is ADDED to the current axis rather than replacing it, which keeps
    /// the angle "unwrapped" — it may run past ±180. That is the whole point:
    /// SwiftUI interpolates the raw number, so handing it a wrapped angle (e.g. 258
    /// when the ring sits at −6) would make the ring travel 264° the wrong way round
    /// instead of 96° the short way.
    ///
    /// Shortest-turn matches the hand, not just the maths: a straight pointer move
    /// between two slices is a chord, and a chord always subtends the MINOR arc, so
    /// the angle it sweeps is the short way round by construction.
    private func shortWay(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func makeSubmenu(_ action: PopBarActionConfig, mid: Double) -> OpenSubmenu {
        OpenSubmenu(parentID: action.id,
                    midDegrees: mid,
                    children: action.children,
                    plan: SubmenuPlan(count: action.children.count,
                                      midDegrees: mid,
                                      stepDegrees: layout.submenuStepDegrees))
    }

    /// Fold the submenu shut. `submenu` is deliberately KEPT: the ring animates back
    /// under the main ring, and clearing it here would make it vanish instead.
    private func collapseSubmenu() {
        openToken &+= 1   // cancel an open that was scheduled for the next pass
        if expanded {
            collapsedAt = Date()
            withAnimation(openSpring) { expanded = false }
        }
        settledAt = nil
        aimingUntil = nil
        aimToken &+= 1    // cancel an aim re-check scheduled for a ring that is now shut
        hitRegion?.outerRadius = 0
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

    // MARK: - Submenu ring (second level)

    /// The submenu on screen: which slice opened it, the axis it is centred on, and
    /// the children to draw. Held by value so the ring can finish folding shut after
    /// the pointer has already moved somewhere else.
    struct OpenSubmenu: Equatable {
        var parentID: String
        var midDegrees: Double
        var children: [PopBarActionConfig]
        var plan: SubmenuPlan
    }

    private var hasSubmenus: Bool { actions.contains { $0.hasChildren } }

    /// The square the wheel draws into — wide enough for the submenu whenever any
    /// action owns one (see `WheelLayout.expandedDiameter` for why it is not resized
    /// on the fly).
    private var canvas: CGFloat { hasSubmenus ? layout.expandedDiameter : layout.diameter }

    /// How far hover tracking reaches. Always the full disc when submenus exist, so
    /// pushing out from a slice onto its children never crosses a tracking boundary.
    private var trackedReach: CGFloat {
        hasSubmenus ? layout.submenuOuterRadius + layout.overshootSlack : layout.outerRadius
    }

    private var openSpring: Animation { .spring(response: 0.36, dampingFraction: 0.9) }

    /// The arc at its fully-open size. Used ONLY to paint the invisible click
    /// backing, which deliberately does not animate: the ring must be clickable the
    /// moment it starts coming out, and at `backingOpacity` there is nothing to see.
    private func submenuShape(_ open: OpenSubmenu) -> RoundedRingSector {
        RoundedRingSector(startAngle: open.plan.start,
                          endAngle: open.plan.start + open.plan.span,
                          innerRadius: layout.submenuInnerRadius,
                          outerRadius: layout.submenuOuterRadius,
                          cornerRadius: layout.submenuCorner)
    }

    /// The second ring.
    ///
    /// ALWAYS present, even with nothing open, and that is deliberate: SwiftUI can
    /// only animate `unfold` up from 0 if the view already existed at 0. Inserting
    /// it into the hierarchy already-open would pop straight to full size with no
    /// animation at all.
    private var submenuVisuals: some View {
        let open = submenu
        let plan = open?.plan
        return SubmenuRing(
            unfold: expanded ? 1 : 0,
            span: expanded ? (plan?.span ?? 0) : 0,
            mid: open?.midDegrees ?? -90,
            items: open?.children.map {
                SubmenuItem(id: $0.id, title: $0.title, symbol: $0.iconSymbol)
            } ?? [],
            isFullRing: plan?.isFullRing ?? false,
            canvas: canvas,
            ringOuterRadius: layout.outerRadius,
            seam: layout.submenuSeam,
            thickness: layout.submenuThickness,
            corner: layout.submenuCorner,
            showIcons: layout.showIcons,
            showLabels: layout.showLabels,
            labelWidth: layout.labelWidth,
            hoveredIndex: open.flatMap { hoveredChildIndex($0) },
            highlight: submenuHighlightStyle,
            dividerColor: Color.primary.opacity(skin == .liquid ? 0.16 : 0.12),
            glyphColor: { hot in childGlyphColor(hot: hot, dark: isDark) },
            glyphShadow: skin == .liquid ? (isDark ? .black.opacity(0.55) : .white.opacity(0.6)) : nil,
            material: { shape in submenuMaterial(shape) }
        )
    }

    private var submenuHighlightStyle: SubmenuHighlight {
        switch skin {
        case .classic:
            return .fill(Color.accentColor)
        case .liquid:
            return .dot(isDark ? Color.white.opacity(0.9) : Color(red: 0.10, green: 0.13, blue: 0.20))
        }
    }

    @ViewBuilder
    private func submenuMaterial(_ shape: RoundedRingSector) -> some View {
        let d = canvas
        switch skin {
        case .classic:
            ZStack {
                VisualEffectBlur(cornerRadius: 0, bordered: false)
                    .frame(width: d, height: d)
                    .mask(shape.fill())
                shape.fill(Color.primary.opacity(0.06))
                shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.75)
            }
        case .liquid:
            ZStack {
                submenuLiquidMaterial(shape)
                if isDark {
                    // Same reason as the main ring: macOS 26 Liquid Glass samples the
                    // backdrop, so over dark content it goes near-black and the glyphs
                    // lose contrast. A controlled scrim pins it to predictable glass.
                    shape.fill(Color.black.opacity(0.34))
                }
            }
        }
    }

    /// The real macOS 26 Liquid Glass clipped to the arc where available, the same
    /// frost fallback the main ring uses otherwise. Gated at COMPILE time as well as
    /// at runtime: `.glassEffect` only exists in the macOS 26 SDK.
    @ViewBuilder
    private func submenuLiquidMaterial(_ shape: RoundedRingSector) -> some View {
        let d = canvas
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear
                .frame(width: d, height: d)
                .glassEffect(.regular, in: shape)
        } else {
            submenuFrost(shape)
        }
        #else
        submenuFrost(shape)
        #endif
    }

    private func submenuFrost(_ shape: RoundedRingSector) -> some View {
        let d = canvas
        return LiquidGlassBlur(dark: isDark)
            .frame(width: d, height: d)
            .overlay(Color.white.opacity(isDark ? 0.08 : 0.10))
            .mask(shape.fill())
    }

    private func childGlyphColor(hot: Bool, dark: Bool) -> Color {
        switch skin {
        case .classic: return hot ? .white : .primary
        case .liquid:  return glyphColor(hot: hot, dark: dark)
        }
    }

    private func hoveredChildIndex(_ open: OpenSubmenu) -> Int? {
        guard let id = hoveredChild else { return nil }
        return open.children.firstIndex { $0.id == id }
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

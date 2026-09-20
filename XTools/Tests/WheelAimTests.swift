import XCTest
import CoreGraphics

/// Does the wheel tell "reaching for a child" apart from "browsing the first ring"?
///
/// The wheel's second ring sits further out than the slice that opened it, so
/// reaching a child on the far side of the arc means cutting diagonally across the
/// slices in between. `WheelAim.Tracker` decides when to let the pointer do that;
/// these tests are the reason to trust its two thresholds.
///
/// **Every case here is a real bug that shipped or nearly shipped**, which is why
/// they are worth keeping:
///
///  - judging direction over a fixed count of samples protected a quick reach and
///    never a slow one, because a count measures however much ground the hand
///    happened to cover between two events;
///  - judging it over a stretch of time fixed that and broke the other side, because
///    inside any window short enough to react in time, a slow sweep's wobble and a
///    slow reach look identical;
///  - measuring outward progress from wherever the pointer entered the wheel made
///    the whole test inert, since the wheel opens centred on the cursor and so every
///    gesture begins in the hollow middle, eighty points "outward" of the ring;
///  - too tight a turn-back slack read an ordinary hand tremor as changing one's
///    mind, so an unsteady hand never accumulated anything.
///
/// The gestures are synthesised rather than recorded, so the numbers below are a
/// model of a hand, not a measurement of one. What they pin down is the SHAPE of
/// the rule — that the answer depends on how far the pointer has gone and not on
/// how fast it went, and that a bounded wobble can never add up to an unbounded
/// reach.
final class WheelAimTests: XCTestCase {

    // The wheel as the user has it: a ring whose glyphs sit at 84 points out, and a
    // second ring beginning at 130.
    private let centre = CGPoint(x: 124, y: 124)
    private let ringMid: CGFloat = 84
    private let submenuInner: CGFloat = 130

    private struct Sample {
        let point: CGPoint
        let at: TimeInterval
    }

    // MARK: - Driving the real tracker

    /// Every moment the tracker says the pointer is reaching, with the run restarted
    /// at `opensAt` the way the view restarts it when a different ring opens.
    private func armings(_ gesture: [Sample], opensAt: Int = 0) -> [TimeInterval] {
        let base = Date()
        var tracker = WheelAim.Tracker()
        var fired: [TimeInterval] = []
        for (i, s) in gesture.enumerated() {
            if i == opensAt { tracker.restart() }
            let reaching = tracker.isReaching(to: s.point,
                                              at: base.addingTimeInterval(s.at),
                                              centre: centre)
            if reaching && i >= opensAt { fired.append(s.at) }
        }
        return fired
    }

    private func isProtected(_ gesture: [Sample], opensAt: Int = 0) -> Bool {
        !armings(gesture, opensAt: opensAt).isEmpty
    }

    /// How far out the pointer had pushed when the protection switched on. This is
    /// the number that should NOT move when the speed does.
    private func armedAfter(_ gesture: [Sample]) -> CGFloat? {
        guard let t = armings(gesture).first,
              let s = gesture.first(where: { $0.at == t }) else { return nil }
        return radius(s.point) - ringMid
    }

    // MARK: - Synthesised gestures

    private func radius(_ p: CGPoint) -> CGFloat {
        let dx = p.x - centre.x, dy = p.y - centre.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func point(r: CGFloat, deg: Double) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: centre.x + r * CGFloat(cos(a)), y: centre.y + r * CGFloat(sin(a)))
    }

    /// Reaching outward for a child, optionally swinging sideways on the way — which
    /// is what reaching a child at the far end of a wide arc actually looks like.
    /// `tremor` adds an 8Hz shake, the frequency of an ordinary unsteady hand.
    private func reach(speed: Double, hz: Double = 120,
                       slant: Double = 0, tremor: CGFloat = 0) -> [Sample] {
        let dt = 1 / hz
        let distance = Double(submenuInner - ringMid) + 8
        let steps = max(1, Int((distance / speed) / dt))
        return (0...steps).map { i in
            let t = Double(i) * dt, f = Double(i) / Double(steps)
            let shake = tremor * CGFloat(sin(2 * .pi * 8 * t))
            return Sample(point: point(r: ringMid + CGFloat(f * distance) + shake,
                                       deg: -90 + slant * f),
                          at: t)
        }
    }

    /// Browsing the first level: going AROUND the ring. The radius wanders because a
    /// hand pivots at the wrist and not at the wheel's centre — it drifts in and out
    /// the whole way round without going anywhere, and telling that apart from a
    /// reach is the entire job.
    private func sweep(degPerSecond: Double, wobble: CGFloat,
                       wobbleHz: Double = 1.16, hz: Double = 120,
                       from startDegrees: Double = -90, at radius: CGFloat? = nil,
                       startingAt t0: TimeInterval = 0) -> [Sample] {
        let dt = 1 / hz
        let r = radius ?? ringMid
        let steps = max(1, Int((120.0 / degPerSecond) / dt))
        return (0...steps).map { i in
            let t = Double(i) * dt
            let w = wobble * CGFloat(sin(2 * .pi * wobbleHz * t))
                  + wobble * 0.4 * CGFloat(sin(2 * .pi * wobbleHz * 3.2 * t))
            return Sample(point: point(r: r + w, deg: startDegrees + degPerSecond * t), at: t0 + t)
        }
    }

    /// Coming out of the hollow centre the wheel opens around, onto a group's slice
    /// — which is how every single interaction begins.
    private func approachFromCentre(speed: Double, hz: Double = 120) -> [Sample] {
        let dt = 1 / hz
        var out: [Sample] = []
        var r: CGFloat = 6
        var t = 0.0
        while r < ringMid {
            out.append(Sample(point: point(r: r, deg: -90), at: t))
            r += CGFloat(speed * dt)
            t += dt
        }
        return out
    }

    // MARK: - Reaching for a child

    func testAReachIsProtectedAtEverySpeed() {
        for speed in [40.0, 60, 100, 150, 250, 400] {
            XCTAssertTrue(isProtected(reach(speed: speed)),
                          "reaching at \(Int(speed)) pt/s lost the ring")
        }
    }

    func testAReachIsProtectedAtEitherEventRate() {
        for hz in [60.0, 120] {
            XCTAssertTrue(isProtected(reach(speed: 60, hz: hz)),
                          "a slow reach sampled at \(Int(hz))Hz lost the ring")
        }
    }

    func testASlantedReachIsProtected() {
        for slant in [30.0, 50, 80] {
            XCTAssertTrue(isProtected(reach(speed: 150, slant: slant)),
                          "reaching across \(Int(slant))° of arc lost the ring")
        }
    }

    func testAnUnsteadyHandIsStillProtected() {
        for tremor in [CGFloat(1), 2, 3, 4] {
            XCTAssertTrue(isProtected(reach(speed: 60, tremor: tremor)),
                          "a slow reach with ±\(Int(tremor))pt of hand tremor lost the ring")
        }
    }

    /// The property the whole rework is for: the protection switches on at the same
    /// PLACE however fast the pointer is travelling. A pointer that merely slowed
    /// down is not a pointer that changed its mind.
    func testProtectionArmsAtTheSameDistanceWhateverTheSpeed() {
        let slow = armedAfter(reach(speed: 40))
        let quick = armedAfter(reach(speed: 150))
        XCTAssertNotNil(slow); XCTAssertNotNil(quick)
        guard let slow, let quick else { return }
        XCTAssertEqual(slow, quick, accuracy: 3,
                       "armed \(slow)pt out when slow but \(quick)pt out when quick")
    }

    /// …and it has to happen before the pointer could have crossed into a
    /// neighbouring slice, or the ring is already gone. A slice of an eight-action
    /// wheel is 45° wide, so there is about 22° of room from its middle.
    func testProtectionArmsBeforeTheSliceBoundaryIsReached() {
        for speed in [40.0, 150] {
            let gesture = reach(speed: speed, slant: 50)
            guard let t = armings(gesture).first,
                  let s = gesture.first(where: { $0.at == t }) else {
                return XCTFail("a slanted reach at \(Int(speed)) pt/s never armed")
            }
            let swung = abs(atan2(s.point.y - centre.y, s.point.x - centre.x) * 180 / .pi + 90)
            XCTAssertLessThan(swung, 22,
                              "armed only after swinging \(Int(swung))°, past the slice boundary")
        }
    }

    // MARK: - Browsing the first ring

    func testBrowsingIsNeverMistakenForReaching() {
        for degPerSecond in [20.0, 45, 90, 180] {
            for wobble in [CGFloat(4), 6] {
                XCTAssertFalse(isProtected(sweep(degPerSecond: degPerSecond, wobble: wobble)),
                               "browsing at \(Int(degPerSecond))°/s with ±\(Int(wobble))pt of wobble "
                               + "was taken for a reach — the ring would go sticky")
            }
        }
    }

    func testBrowsingIsNotMistakenForReachingAtAnyWobbleFrequency() {
        for wobbleHz in [0.3, 1.16, 3.0, 8.0] {
            XCTAssertFalse(isProtected(sweep(degPerSecond: 45, wobble: 5, wobbleHz: wobbleHz)),
                           "browsing with a \(wobbleHz)Hz wander was taken for a reach")
        }
    }

    func testStandingStillAndPullingBackAreNotReaching() {
        let still = (0..<60).map { Sample(point: point(r: ringMid, deg: -90), at: Double($0) / 120) }
        XCTAssertFalse(isProtected(still), "a motionless pointer was taken for a reach")

        let back = reach(speed: 150).reversed().enumerated()
            .map { Sample(point: $0.element.point, at: Double($0.offset) / 120) }
        XCTAssertFalse(isProtected(back), "a pointer coming back inward was taken for a reach")
    }

    // MARK: - The two gestures joined together

    /// Opening a group means moving outward, so the guard does arm on the way in —
    /// harmless, because it lapses on its own. What must not happen is it staying
    /// armed once the user starts browsing, which would make the ring refuse to
    /// follow them to the next group.
    func testOpeningAGroupThenBrowsingOnFallsQuiet() {
        for degPerSecond in [45.0, 90, 180] {
            let approach = approachFromCentre(speed: 250)
            let opensAt = approach.firstIndex { radius($0.point) >= 53 } ?? 0
            let browsing = sweep(degPerSecond: degPerSecond, wobble: 4,
                                 startingAt: approach.last!.at)
            let joined = approach + browsing
            let late = armings(joined, opensAt: opensAt).filter { $0 > browsing[0].at + 0.3 }
            XCTAssertTrue(late.isEmpty,
                          "still arming \(late.count)× after browsing began at \(Int(degPerSecond))°/s")
        }
    }

    /// Having arrived at the children, browsing sideways among them must not keep
    /// renewing the grace — that is what tracking the furthest point reached, rather
    /// than only where the push started, is for.
    func testArrivingThenBrowsingAmongTheChildrenStopsRearming() {
        for degPerSecond in [45.0, 90] {
            let arriving = reach(speed: 150)
            let browsing = sweep(degPerSecond: degPerSecond, wobble: 4,
                                 at: submenuInner + 8, startingAt: arriving.last!.at)
            let joined = arriving + browsing
            let fired = armings(joined)
            XCTAssertFalse(fired.isEmpty, "the reach itself never armed")
            let late = fired.filter { $0 > arriving.last!.at + 0.3 }
            XCTAssertTrue(late.isEmpty,
                          "kept re-arming \(late.count)× while browsing among the children")
        }
    }

    // MARK: - OutwardRun on its own

    func testOutwardRunMeasuresFromWhereThePushBegan() {
        var run = WheelAim.OutwardRun()
        XCTAssertEqual(run.progress(radius: 84), 0, "the first sample is the starting line")
        XCTAssertEqual(run.progress(radius: 94), 10, accuracy: 0.001)
        XCTAssertEqual(run.progress(radius: 104), 20, accuracy: 0.001)
    }

    func testOutwardRunRestartsWhenThePointerTurnsBack() {
        var run = WheelAim.OutwardRun()
        _ = run.progress(radius: 84)
        XCTAssertEqual(run.progress(radius: 114), 30, accuracy: 0.001)
        // Coming back in past the slack ends the push, even though 100 is still far
        // outside where it began. Watching only the starting point cannot see this.
        XCTAssertEqual(run.progress(radius: 100), 0, "turning back did not end the run")
        XCTAssertEqual(run.progress(radius: 106), 6, accuracy: 0.001)
    }

    func testOutwardRunIgnoresATremorSmallerThanTheSlack() {
        var run = WheelAim.OutwardRun()
        _ = run.progress(radius: 84)
        _ = run.progress(radius: 94)
        XCTAssertEqual(run.progress(radius: 92), 8, accuracy: 0.001,
                       "a 2pt dip should not count as changing one's mind")
        XCTAssertEqual(run.progress(radius: 100), 16, accuracy: 0.001)
    }

    func testOutwardRunResets() {
        var run = WheelAim.OutwardRun()
        _ = run.progress(radius: 84)
        XCTAssertEqual(run.progress(radius: 120), 36, accuracy: 0.001)
        run.reset()
        XCTAssertEqual(run.progress(radius: 120), 0, "reset should start a fresh run")
    }

    // MARK: - The arc test

    func testAnArcKnowsWhichAnglesPointAtIt() {
        let plan = SubmenuPlan(count: 3, midDegrees: 0, stepDegrees: 40)   // spans -60…60
        XCTAssertTrue(plan.contains(degrees: 0))
        XCTAssertTrue(plan.contains(degrees: 59))
        XCTAssertFalse(plan.contains(degrees: 90))
        // Slack, for a pointer cutting the corner just outside the run's edge.
        XCTAssertTrue(plan.contains(degrees: -70, tolerance: 12))
        XCTAssertFalse(plan.contains(degrees: -80, tolerance: 12))
    }

    func testAnArcStraddlingTwelveOClockStillAnswersCorrectly() {
        let plan = SubmenuPlan(count: 3, midDegrees: -90, stepDegrees: 40)  // spans -150…-30
        XCTAssertTrue(plan.contains(degrees: -90))
        XCTAssertTrue(plan.contains(degrees: -149))
        XCTAssertFalse(plan.contains(degrees: 20))
        XCTAssertTrue(plan.contains(degrees: -25, tolerance: 12), "slack must wrap, not clip")
    }

    func testAFullRingContainsEveryAngle() {
        let plan = SubmenuPlan(count: 12, midDegrees: 0, stepDegrees: 40)   // closes up
        XCTAssertTrue(plan.isFullRing)
        for deg in stride(from: -180.0, through: 180, by: 30) {
            XCTAssertTrue(plan.contains(degrees: deg), "\(deg)° fell outside a full ring")
        }
    }
}

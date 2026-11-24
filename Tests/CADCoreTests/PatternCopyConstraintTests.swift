// A constraint on a copy a pattern made holds the copy by moving its original.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import simd
import Testing
@testable import CADCore

@Suite struct PatternCopyConstraintTests {
    /// One Ø5 circle at (-8, 6), copied 12 times round the origin: a ring of radius 10, so neighbours are 5.176 apart.
    static func ring() -> Sketch {
        var s = Sketch()
        let c = s.addPoint(-8, 6)
        s.addCircle(center: c, radius: 2.5, id: "src")
        s.dimension(.diameter("src"), "5 mm", id: "d")
        s.patterns = [SketchPatternDef(id: "pat", kind: .circular, sources: ["src"], count: "12", angle: "360 deg", center: "origin")]
        s.refreshGenerated(ParameterValues())
        return s
    }

    static func centre(_ s: Sketch, _ circle: EntityID) -> SIMD2<Double> {
        guard case .circle(let m, _)? = s.curve(circle)?.geometry, let p = s.position(m) else { return .zero }
        return p
    }
    static func radius(_ s: Sketch, _ circle: EntityID) -> Double {
        guard case .circle(_, let r)? = s.curve(circle)?.geometry else { return 0 }
        return r
    }
    static let values: [EntityID: Double] = ["d": 5]

    @Test func aCircleCanBeTangentToItsNeighbourInTheRing() {
        var s = Self.ring()
        let a = Self.centre(s, "src"), b = Self.centre(s, "pat~11~src")
        #expect(abs(simd_length(a - b) - 5.17638) < 1e-4, "the ring starts 0.176 mm short of touching")
        let ok34 = s.applyConstraints([.tangent("src", "pat~11~src")], values: Self.values)
        #expect(ok34, "the solver can do it, by moving the original")
        s.refreshGenerated(ParameterValues())
        // The original slid in along its spoke until 12 circles of Ø5 just touch: ring radius 2.5 / sin 15° = 9.659 mm.
        let ring = simd_length(Self.centre(s, "src"))
        #expect(abs(ring - 2.5 / sin(Double.pi / 12)) < 1e-6, "\(ring)")
        for k in 1...11 {
            let next = k == 11 ? "src" : "pat~\(k + 1)~src"
            let d = simd_length(Self.centre(s, "pat~\(k)~src") - Self.centre(s, next))
            #expect(abs(d - 5) < 1e-6, "copy \(k) touches the next: \(d)")
        }
        #expect(abs(Self.radius(s, "src") - 2.5) < 1e-9 && abs(Self.radius(s, "pat~4~src") - 2.5) < 1e-9, "the Ø5 dimension still holds")
        #expect(SketchSolver.diagnose(s, dimensionValues: Self.values).isEmpty)
    }

    @Test func aSecondTangentOfTheSameKindIsRedundantNotAConflict() {
        var s = Self.ring()
        let ok51 = s.applyConstraints([.tangent("src", "pat~11~src")], values: Self.values)
        #expect(ok51)
        let ok53 = s.applyConstraints([.tangent("src", "pat~1~src")], values: Self.values)
        #expect(ok53, "the other neighbour says the same")
        let ok55 = s.applyConstraints([.tangent("pat~1~src", "pat~2~src")], values: Self.values)
        #expect(ok55, "and so do two copies of it")
        s.refreshGenerated(ParameterValues())
        let diagnosis = SketchSolver.diagnose(s, dimensionValues: Self.values)
        #expect(diagnosis.conflicting.isEmpty, "\(diagnosis)")
    }

    @Test func theDiameterCanDoItInstead() {
        // Without the Ø5 dimension, the circle can grow until the ring touches: Ø 5.176 at ring radius 10.
        var s = Self.ring()
        s.dimensions.removeAll()
        let ok66 = s.applyConstraints([.tangent("src", "pat~11~src")], values: [:])
        #expect(ok66)
        s.refreshGenerated(ParameterValues())
        let moved = simd_length(Self.centre(s, "src"))
        let grown = Self.radius(s, "src")
        // One of the two gave way (the solver prefers moving the circle to growing it).
        #expect(abs(moved - 2 * grown / (2 * sin(Double.pi / 12))) < 1e-6 || abs(grown * 2 - 2 * 10 * sin(Double.pi / 12)) < 1e-6, "ring \(moved), r \(grown)")
        #expect(abs(simd_length(Self.centre(s, "src") - Self.centre(s, "pat~11~src")) - 2 * Self.radius(s, "src")) < 1e-6)
    }

    @Test func aRowOfCopiesCanBeHeldToTheirNeighbourToo() {
        // A row of three circles 20 mm apart, radius 5: tangent to the next copy means radius 10.
        var s = Sketch()
        let c = s.addPoint(0, 0)
        s.addCircle(center: c, radius: 5, id: "src")
        s.constrain(.fix(c, x: 0, y: 0))
        s.patterns = [SketchPatternDef(id: "row", kind: .rectangular, sources: ["src"], countX: "3", spacingX: "20 mm", countY: "1")]
        s.refreshGenerated(ParameterValues())
        let ok84 = s.applyConstraints([.tangent("src", "row~1~src")], values: [:])
        #expect(ok84)
        s.refreshGenerated(ParameterValues())
        #expect(abs(Self.radius(s, "src") - 10) < 1e-6 && abs(Self.radius(s, "row~2~src") - 10) < 1e-6)
        #expect(abs(simd_length(Self.centre(s, "row~2~src") - SIMD2(40, 0))) < 1e-9)
    }

    @Test func aConstraintBetweenTwoCopiesIsHeldThroughTheOriginalToo() {
        var s = Self.ring()
        let ok93 = s.applyConstraints([.tangent("pat~3~src", "pat~4~src")], values: Self.values)
        #expect(ok93, "two copies, neither of them the original")
        s.refreshGenerated(ParameterValues())
        #expect(abs(simd_length(Self.centre(s, "pat~3~src") - Self.centre(s, "pat~4~src")) - 5) < 1e-6)
    }

    @Test func aConflictAmongCopiesIsStillNamed() {
        // Held tangent while the ring radius is also fixed at 10: those can't both hold, and the sketch says so.
        var s = Self.ring()
        let c = "origin"
        let origin = s.points.first { $0.id == "origin" }
        _ = origin
        let centre = s.curves.compactMap { curve -> EntityID? in if case .circle(let m, _) = curve.geometry, curve.id == "src" { return m }; return nil }.first!
        s.dimension(.distance(c, centre), "10 mm", id: "ringRadius")
        var values = Self.values
        values["ringRadius"] = 10
        let ok109 = s.applyConstraints([.tangent("src", "pat~11~src")], values: values)
        #expect(!ok109, "Ø5 at ring radius 10 can't touch")
        let diagnosis = SketchSolver.diagnose({ var t = s; t.constrain(.tangent("src", "pat~11~src")); return t }(), dimensionValues: values)
        #expect(!diagnosis.conflicting.isEmpty)
    }

    @Test func copiesTakeNoPartWhenNothingNamesThem() {
        // The old fast path: a pattern nobody constrains leaves the copies alone for the solver.
        let s = Self.ring()
        #expect(!s.constrainsPatternCopies)
        var t = s
        t.constrain(.tangent("src", "pat~11~src"))
        #expect(t.constrainsPatternCopies)
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

@Suite struct SolverTests {
    @Test func dimensionedRectangleIsFullyConstrained() {
        var s = Sketch()
        // Deliberately sloppy initial geometry; the solver has to fix it.
        let c = [s.addPoint(0.3, -0.2), s.addPoint(9, 1), s.addPoint(8, 7), s.addPoint(-1, 6)]
        let l = (0..<4).map { s.addLine(c[$0], c[($0 + 1) % 4]) }
        s.constrain(.horizontal(l[0])); s.constrain(.vertical(l[1]))
        s.constrain(.horizontal(l[2])); s.constrain(.vertical(l[3]))
        s.constrain(.coincident(c[0], "origin"))
        s.dimension(.length(l[0]), "60", id: "w")
        s.dimension(.length(l[1]), "40", id: "h")

        let r = SketchSolver.solve(&s, dimensionValues: ["w": 60, "h": 40])
        #expect(r.status == .solved)
        #expect(r.degreesOfFreedom == 0)
        let p2 = s.point(c[2])!
        #expect(abs(p2.x - 60) < 1e-6 && abs(p2.y - 40) < 1e-6)
    }

    @Test func underConstrainedReportsFreedomAndMovesLittle() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 1)
        let l = s.addLine(a, b)
        s.constrain(.horizontal(l))
        let r = SketchSolver.solve(&s, dimensionValues: [:])
        #expect(r.status == .solved)
        #expect(r.degreesOfFreedom == 3)  // 4 coordinates - 1 constraint
        #expect(abs(s.point(a)!.y - 0.5) < 1e-6 && abs(s.point(b)!.y - 0.5) < 1e-6)  // met in the middle
    }

    /// A sketch that can't be satisfied settles on a compromise; the solver has to see that it is creeping and stop, not use up its
    /// iterations (solveLocally tries a sketch several ways, and every attempt that can't succeed used to cost the full 200).
    @Test func aSketchThatCannotBeSatisfiedGivesUpEarly() {
        var s = Sketch()
        let q = [s.addPoint(0, 0), s.addPoint(10, 0), s.addPoint(0, 5), s.addPoint(10, 6)]
        let l1 = s.addLine(q[0], q[1]), l2 = s.addLine(q[2], q[3])
        s.constrain(.coincident(q[0], "origin")); s.constrain(.horizontal(l1)); s.constrain(.parallel(l1, l2))
        s.constrain(.coincident(q[1], q[3]))  // parallel lines 5 apart can't meet, and are told to
        s.dimension(.length(l1), "10", id: "x"); s.dimension(.pointLineDistance(point: q[2], line: l1), "5", id: "y")
        s.dimension(.angle(l1, l2), "0.5", id: "z")
        let r = SketchSolver.solve(&s, dimensionValues: ["x": 10, "y": 5, "z": 0.5])
        #expect(r.status == .failed)
        #expect(r.iterations < 60, "gave up after \(r.iterations) iterations")
    }

    @Test func conflictingConstraintsFail() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let l = s.addLine(a, b)
        s.constrain(.horizontal(l)); s.constrain(.vertical(l))
        s.dimension(.length(l), "10", id: "len")
        let r = SketchSolver.solve(&s, dimensionValues: ["len": 10])
        #expect(r.status == .failed)
    }

    @Test func tangentCircleAndAngle() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(50, 0), c = s.addPoint(0, 30)
        let base = s.addLine(a, b), side = s.addLine(a, c)
        s.constrain(.coincident(a, "origin")); s.constrain(.horizontal(base))
        s.dimension(.angle(base, side), "60 deg", id: "ang")
        let center = s.addPoint(20, 12)
        let circle = s.addCircle(center: center, radius: 4)
        s.constrain(.tangent(base, circle))
        s.dimension(.radius(circle), "5", id: "r")
        let r = SketchSolver.solve(&s, dimensionValues: ["ang": .pi / 3, "r": 5])
        #expect(r.status == .solved)
        #expect(abs(s.point(center)!.y - 5) < 1e-6)
        let d = s.point(c)!.position - s.point(a)!.position
        #expect(abs(atan2(d.y, d.x) - .pi / 3) < 1e-6)
    }

    @Test func negativeAngleIsTheSameAsTheTurnTheOtherWay() {
        for target in [-58.003, 58.003, 302.0] {
            var s = Sketch()
            let a = s.addPoint(0, 0), b = s.addPoint(50, 0), c = s.addPoint(20, 30)
            let base = s.addLine(a, b), side = s.addLine(a, c)
            s.constrain(.coincident(a, "origin")); s.constrain(.horizontal(base))
            s.dimension(.angle(base, side), "\(target) deg", id: "ang")
            let v = target * .pi / 180
            let r = SketchSolver.solveLocally(&s, dimensionValues: ["ang": v])
            #expect(r.status == .solved, "\(target)")
            let got = s.measure(.angle(base, side)) ?? -1
            #expect(abs(atan2(sin(got - v), cos(got - v))) < 1e-6, "\(target) measured as \(got)")
        }
    }

    @Test func anAngleOnTheOtherSideOfTheLinesIsDrawnAboveThem() throws {
        // A base running left from the corner and a side drawn from the top down to it: the bodies make 76°,
        // the dimension (from the base's direction to the side's) is 104°.
        var s = Sketch()
        let corner = s.addPoint(49.5, 0), farEnd = s.addPoint(43, 0), top = s.addPoint(40, 38)
        let base = s.addLine(corner, farEnd), side = s.addLine(top, corner)
        let d = SketchDimension(.angle(base, side), "104 deg")
        let t = try #require(s.measure(d.kind))
        #expect(abs(t * 180 / .pi - 104) < 1, "the value is the supplement of the 76° the bodies make")
        let arc = try #require(s.angleArc(of: d, size: 1))
        #expect(sin(arc.middle) > 0, "above the lines, where the bodies are")
        // Between the side's body and the base's extension (to the right of the corner).
        #expect(abs(cos(arc.start) - 1) < 1e-6)
    }

    @Test func lineAngleTurnsTheLineAboutItsStart() {
        var s = Sketch()
        let a = s.addPoint(5, 5), b = s.addPoint(15, 5)
        let l = s.addLine(a, b)
        s.dimension(.lineAngle(l), "220 deg", id: "ang")
        s.dimension(.length(l), "10 mm", id: "len")
        let target = 220.0 * .pi / 180
        #expect(abs((s.measure(.lineAngle(l)) ?? -1) - 0) < 1e-9)
        let r = SketchSolver.solveLocally(&s, dimensionValues: ["ang": target, "len": 10])
        #expect(r.status == .solved)
        let pa = s.point(a)!.position, pb = s.point(b)!.position
        #expect(abs(pa.x - 5) < 1e-6 && abs(pa.y - 5) < 1e-6, "the start stays")
        #expect(abs((s.measure(.lineAngle(l)) ?? -1) - (140 * .pi / 180)) < 1e-6, "measured as the angle to the x-axis: 140°")
        #expect(abs(vlen(pb - pa) - 10) < 1e-3, "and the length is kept")
        // Change it again: it follows, and the old value isn't a second solution.
        _ = SketchSolver.solveLocally(&s, dimensionValues: ["ang": 30 * .pi / 180, "len": 10])
        #expect(abs((s.measure(.lineAngle(l)) ?? -1) - 30 * .pi / 180) < 1e-6)
    }

    @Test func arcAngleSweepsTheArcAboutItsCentre() throws {
        var s = Sketch()
        let c = s.addPoint(0, 0), a = s.addPoint(10, 0), b = s.addPoint(0, 10)
        let arc = s.addArc(center: c, start: a, end: b)
        s.dimension(.radius(arc), "10 mm", id: "r")
        s.dimension(.arcAngle(arc), "90 deg", id: "sweep")
        #expect(abs((s.measure(.arcAngle(arc)) ?? -1) - .pi / 2) < 1e-9, "counter-clockwise from the start to the end")
        let drawn = try #require(s.angleArc(of: SketchDimension(.arcAngle(arc), ""), size: 1))
        #expect(drawn.center == SIMD2(0, 0) && abs(drawn.sweep - .pi / 2) < 1e-9 && drawn.radius <= 10 && !drawn.axis)
        for degrees in [200.0, 45.0, 300.0, 120.0] {
            let r = SketchSolver.solveLocally(&s, dimensionValues: ["r": 10, "sweep": degrees * .pi / 180])
            #expect(r.status == .solved, "\(degrees)°")
            #expect(abs((s.measure(.arcAngle(arc)) ?? -1) - degrees * .pi / 180) < 1e-5, "\(degrees)° is the sweep now")
            #expect(abs((s.radius(of: s.curve(arc)!) ?? 0) - 10) < 1e-5, "and the radius stays")
        }
        let copy = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
        #expect(copy.dimensions.contains { $0.kind == .arcAngle(arc) }, "it is saved and read back")
        #expect(Sketch.references(.arcAngle(arc)) == [arc])
    }

    @Test func angleBetweenTwoLinesIsDrawnAtTheirCorner() throws {
        var s = Sketch()
        let o = s.addPoint(2, 1), a = s.addPoint(12, 1), b = s.addPoint(2 + 5, 1 + 5 * 3.0.squareRoot())
        let l1 = s.addLine(o, a), l2 = s.addLine(o, b)
        let d = SketchDimension(.angle(l1, l2), "60 deg")
        let arc = try #require(s.angleArc(of: d, size: 1))
        #expect(arc.center == SIMD2(2, 1) && abs(arc.start) < 1e-9 && abs(arc.sweep - .pi / 3) < 1e-9)
        // The same corner, with the lines the other way round: the arc still lies between them.
        let back = try #require(s.angleArc(of: SketchDimension(.angle(l2, l1), "300 deg"), size: 1))
        #expect(abs(back.sweep - 5 * .pi / 3) < 1e-9)
        // Lines that only cross meet at the crossing.
        var t = Sketch()
        let p = (t.addPoint(0, 0), t.addPoint(10, 0), t.addPoint(5, -5), t.addPoint(5, 5))
        let h = t.addLine(p.0, p.1), v = t.addLine(p.2, p.3)
        let cross = try #require(t.angleArc(of: SketchDimension(.angle(h, v), "90 deg"), size: 1))
        #expect(abs(cross.center.x - 5) < 1e-9 && abs(cross.center.y) < 1e-9)
    }

    @Test func demoSketchesAreFullyConstrained() {
        let doc = CADDocument.demo()
        let values = ParameterEvaluator.evaluate(doc.parameters)
        for f in doc.features {
            guard case .sketch(let sf) = f.kind else { continue }
            var sk = sf.sketch
            var dims: [EntityID: Double] = [:]
            for d in sk.dimensions { dims[d.id] = try? values.value(of: d.expression, kind: d.unitKind) }
            let r = SketchSolver.solve(&sk, dimensionValues: dims)
            #expect(r.status == .solved, "\(f.name)")
            #expect(r.degreesOfFreedom == 0, "\(f.name)")
        }
    }

    @Test func documentRoundTripsThroughJSON() throws {
        let doc = CADDocument.demo()
        let back = try CADDocument.decode(try doc.encoded())
        #expect(back == doc)
    }
}

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

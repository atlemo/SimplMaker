// A construction plane that stands square to a sketch path, at a point along it.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct PlaneAlongPathTests {
    typealias T = NewFeatureTests

    /// A path sketch on the XY floor through fixed points (x, y): lines "L0", "L1"…
    static func polyline(_ points: [(Double, Double)]) -> Feature {
        T.sketch("path") { s in
            let ids = points.map { p -> EntityID in
                let id = s.addPoint(p.0, p.1)
                s.constrain(.fix(id, x: p.0, y: p.1))
                return id
            }
            for i in 1..<ids.count { s.addLine(ids[i - 1], ids[i], id: "L\(i - 1)") }
        }
    }

    static func plane(_ position: String = "0.5", curves: [EntityID], offset: String = "0 mm", angle: String = "0 deg") -> Feature {
        Feature(id: "pp", name: "pp", .plane(PlaneFeature(along: CurveRef(sketch: "path", curves: curves), position: position,
                                                           offset: offset, angle: angle)))
    }

    static func frame(_ features: [Feature], parameters: [Parameter] = []) throws -> Frame {
        var doc = CADDocument()
        doc.features = features
        doc.parameters = parameters
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        return try #require(r.planes["pp"])
    }

    static func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double = 1e-6) -> Bool { simd_length(a - b) < tol }

    @Test func aLineGivesAPlaneSquareToItAtTheMiddle() throws {
        let f = try Self.frame([Self.polyline([(0, 0), (40, 0)]), Self.plane(curves: ["L0"])])
        #expect(Self.near(f.origin, SIMD3(20, 0, 0)), "\(f.origin)")
        #expect(Self.near(f.normal, SIMD3(1, 0, 0)), "\(f.normal)")
        // x runs sideways in the sketch plane, y is the sketch's normal.
        #expect(abs(simd_dot(f.xAxis, f.normal)) < 1e-9)
        #expect(Self.near(f.yAxis, SIMD3(0, 0, 1)), "\(f.yAxis)")
    }

    @Test func theEndsAreZeroAndOneAndOutsideIsHeldAtTheEnds() throws {
        let path = Self.polyline([(0, 0), (40, 0)])
        for (position, x) in [("0", 0.0), ("1", 40), ("0.25", 10), ("-3", 0), ("7", 40)] {
            let f = try Self.frame([path, Self.plane(position, curves: ["L0"])])
            #expect(abs(f.origin.x - x) < 1e-9, "\(position): \(f.origin)")
        }
    }

    @Test func anArcTurnsThePlaneWithIt() throws {
        // A quarter circle of radius 10 about the origin, from (10, 0) to (0, 10), counter-clockwise.
        let arc = T.sketch("path") { s in
            let c = s.addPoint(0, 0), a = s.addPoint(10, 0), b = s.addPoint(0, 10)
            s.constrain(.fix(c, x: 0, y: 0)); s.constrain(.fix(a, x: 10, y: 0)); s.constrain(.fix(b, x: 0, y: 10))
            s.addArc(center: c, start: a, end: b, id: "A")
        }
        let mid = try Self.frame([arc, Self.plane("0.5", curves: ["A"])])
        let r = 10 / 2.0.squareRoot()
        #expect(Self.near(mid.origin, SIMD3(r, r, 0)), "\(mid.origin)")
        #expect(Self.near(mid.normal, SIMD3(-r, r, 0) / 10), "\(mid.normal)")
        let end = try Self.frame([arc, Self.plane("1", curves: ["A"])])
        #expect(Self.near(end.normal, SIMD3(-1, 0, 0), 1e-4), "\(end.normal)")
    }

    @Test func aChainOfCurvesIsWalkedFromItsLooseEnd() throws {
        // Two lines, 30 mm along x then 10 mm up y, picked in the wrong order and the second drawn backwards.
        let path = T.sketch("path") { s in
            let a = s.addPoint(0, 0), b = s.addPoint(30, 0), c = s.addPoint(30, 10)
            s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 30, y: 0)); s.constrain(.fix(c, x: 30, y: 10))
            s.addLine(a, b, id: "L0")
            s.addLine(c, b, id: "L1")
        }
        let start = try Self.frame([path, Self.plane("0", curves: ["L1", "L0"])])
        let end = try Self.frame([path, Self.plane("1", curves: ["L1", "L0"])])
        // Either loose end may be the start, but the path is walked end to end and the two answers are opposite ends.
        let ends = [start.origin, end.origin].sorted { $0.x < $1.x }
        #expect(Self.near(ends[0], SIMD3(0, 0, 0)) && Self.near(ends[1], SIMD3(30, 10, 0)), "\(start.origin) \(end.origin)")
        // Picked from the line at the origin first, the path starts there and runs +x, then +y: 40 mm in all, so
        // 0.875 is 35 mm along, 5 mm up the second line, and there the path runs along +y.
        let first = try Self.frame([path, Self.plane("0.875", curves: ["L0", "L1"])])
        #expect(Self.near(first.origin, SIMD3(30, 5, 0)), "\(first.origin)")
        #expect(Self.near(first.normal, SIMD3(0, 1, 0)), "\(first.normal)")
    }

    @Test func aBezierIsMeasuredAlongItsLengthNotItsParameter() throws {
        // A bend that bunches the parameter: halfway along the length is still halfway by symmetry.
        let path = T.sketch("path") { s in
            let p = [(0.0, 0.0), (30.0, 0.0), (30.0, 30.0), (0.0, 30.0)].map { pt -> EntityID in
                let id = s.addPoint(pt.0, pt.1); s.constrain(.fix(id, x: pt.0, y: pt.1)); return id
            }
            s.addBezier(start: p[0], control1: p[1], control2: p[2], end: p[3], id: "B")
        }
        let f = try Self.frame([path, Self.plane("0.5", curves: ["B"])])
        #expect(abs(f.origin.y - 15) < 1e-3, "\(f.origin)")
        #expect(Self.near(f.normal, SIMD3(0, 1, 0), 1e-4), "at the middle of the bulge the path runs along y: \(f.normal)")
    }

    @Test func thePositionFollowsAParameterAndOffsetAndAngleStillApply() throws {
        let path = Self.polyline([(0, 0), (40, 0)])
        let f = try Self.frame([path, Self.plane("where", curves: ["L0"])], parameters: [Parameter("where", "0.75", unit: .none)])
        #expect(abs(f.origin.x - 30) < 1e-9, "\(f.origin)")
        // The offset runs along the path's direction there.
        let moved = try Self.frame([path, Self.plane("0.5", curves: ["L0"], offset: "5 mm")])
        #expect(Self.near(moved.origin, SIMD3(25, 0, 0)), "\(moved.origin)")
        // The angle tips the plane about its own x axis (sideways in the sketch), as it does on any plane.
        let tipped = try Self.frame([path, Self.plane("0.5", curves: ["L0"], angle: "90 deg")])
        #expect(Self.near(tipped.origin, SIMD3(20, 0, 0)), "\(tipped.origin)")
        #expect(abs(simd_dot(tipped.normal, SIMD3(1, 0, 0))) < 1e-9, "turned square to where it was: \(tipped.normal)")
    }

    @Test func aDeletedCurveOrAMissingSketchIsAClearError() throws {
        var doc = CADDocument()
        doc.features = [Self.polyline([(0, 0), (40, 0)]), Self.plane(curves: ["gone"])]
        var r = Regenerator.regenerate(doc)
        #expect(r.errors["pp"]?.contains("deleted") == true, "\(r.errors)")
        doc.features = [Self.plane(curves: ["L0"])]
        r = Regenerator.regenerate(doc)
        #expect(r.errors["pp"] != nil, "\(r.errors)")
    }

    @Test func aSketchOnThePlaneAndASweepAlongTheSamePathWorks() throws {
        // Quarter-circle-ish path in the XZ plane; the profile circle sits on a plane at the start of it.
        let path = T.sketch("path", on: .xz) { s in
            let a = s.addPoint(0, 0), b = s.addPoint(0, 40)
            s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 0, y: 40))
            s.addLine(a, b, id: "L0")
        }
        let profile = T.sketch("ci", on: .plane("pp")) { s in
            let c = s.addPoint(0, 0)
            s.constrain(.fix(c, x: 0, y: 0))
            s.addCircle(center: c, radius: 5, id: "K")
        }
        let sweep = Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "ci", profiles: [ProfileRef(curves: ["K"])],
                                                                      path: CurveRef(sketch: "path", curves: ["L0"]))))
        let r = try T.regen([path, Self.plane("0", curves: ["L0"]), profile, sweep])
        let body = try #require(r.body("sw"))
        #expect(body.isValid)
        #expect(T.close(body.volume, .pi * 25 * 40, 0.01), "\(body.volume)")
        let f = try #require(r.planes["pp"])
        #expect(Self.near(f.origin, .zero) && Self.near(f.normal, SIMD3(0, 0, 1), 1e-9), "\(f.origin) \(f.normal)")
    }

    @Test func anOldPlaneFileStillOpens() throws {
        let old = #"{"base":{"xy":{}},"offset":"10 mm","angle":"0 deg","axis":"Horizontal"}"#
        let decoded = try JSONDecoder().decode(PlaneFeature.self, from: Data(old.utf8))
        #expect(decoded.along == nil)
        let mine = PlaneFeature(along: CurveRef(sketch: "s", curves: ["a"]), position: "0.3")
        let round = try JSONDecoder().decode(PlaneFeature.self, from: JSONEncoder().encode(mine))
        #expect(round == mine)
    }
}

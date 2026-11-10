// A loft that follows a path (a centerline loft), end to end through the regenerator.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct LoftAlongPathTests {
    typealias T = NewFeatureTests

    /// A 20 mm square on the floor and a circle (radius 6) on a plane 40 mm up, moved sideways by `shift` along x.
    static func sections(shift: Double = 0) -> [Feature] {
        [T.sketch("sq") { T.rect(&$0, -10, -10, 10, 10, ids: ["A", "B", "C", "D"]) },
         Feature(id: "up", name: "up", .plane(PlaneFeature(base: .xy, offset: "40 mm"))),
         T.sketch("ci", on: .plane("up")) { s in
             let c = s.addPoint(shift, 0)
             s.constrain(.fix(c, x: shift, y: 0))
             s.addCircle(center: c, radius: 6, id: "K")
         }]
    }

    /// A path sketch on the XZ plane through the points given as (x, z): a line for two points, a Bézier for four.
    static func path(_ points: [(Double, Double)]) -> Feature {
        let frame = Frame.xz
        return T.sketch("path", on: .xz) { s in
            let ids = points.map { p -> EntityID in
                let world = SIMD3<Double>(p.0, 0, p.1) - frame.origin
                let u = (world * frame.xAxis).sum(), v = (world * frame.yAxis).sum()
                let id = s.addPoint(u, v)
                s.constrain(.fix(id, x: u, y: v))
                return id
            }
            if ids.count == 4 {
                s.addBezier(start: ids[0], control1: ids[1], control2: ids[2], end: ids[3], id: "P")
            } else {
                s.addLine(ids[0], ids[1], id: "P")
            }
        }
    }

    static func loft(path: Bool = true, reversed: Bool = false) -> Feature {
        let sq = LoftSection(sketch: "sq", profile: ProfileRef(curves: ["A", "B", "C", "D"]))
        let ci = LoftSection(sketch: "ci", profile: ProfileRef(curves: ["K"]))
        return Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: reversed ? [ci, sq] : [sq, ci],
                                                             path: path ? CurveRef(sketch: "path", curves: ["P"]) : nil)))
    }

    @Test func aStraightPathGivesTheShapeOfAPlainLoft() throws {
        let plain = try #require(try T.regen(Self.sections() + [Self.loft(path: false)]).body("lf"))
        let r = try T.regen(Self.sections() + [Self.path([(0, 0), (0, 40)]), Self.loft()])
        let body = try #require(r.body("lf"))
        #expect(body.isValid)
        #expect(T.close(body.volume, plain.volume, 0.03), "\(body.volume) against \(plain.volume)")
        #expect(body.hasFace("lf.start") && body.hasFace("lf.end"), "\(body.faceNames)")
        #expect(try body.faceFrame("lf.start").origin.z < 1e-6)
        #expect(abs(try body.faceFrame("lf.end").origin.z - 40) < 1e-6)
        for tag in ["A", "B", "C", "D"] { #expect(body.hasFace("lf.side.\(tag)"), "\(body.faceNames)") }
    }

    @Test func theShapeBendsAlongACurvedPath() throws {
        // The path leaves the square at a slant, swings 15 mm out along x and comes back to the circle. The profiles are
        // parallel, so every slice stays parallel to them and only moves sideways: the volume is the plain loft's.
        let plain = try #require(try T.regen(Self.sections() + [Self.loft(path: false)]).body("lf"))
        let r = try T.regen(Self.sections() + [Self.path([(0, 0), (20, 10), (20, 30), (0, 40)]), Self.loft()])
        let body = try #require(r.body("lf"))
        #expect(body.isValid)
        #expect(T.close(body.volume, plain.volume, 0.03), "\(body.volume) against \(plain.volume)")
        let b = try #require(body.bounds)
        #expect(b.max.x > 18, "the middle is pushed out along x: \(b.max.x)")
        #expect(b.min.x > -10.5 && b.min.z > -1e-6 && b.max.z < 40 + 1e-6, "\(b)")
        #expect(abs(b.min.y + 10) < 0.5 && abs(b.max.y - 10) < 0.5, "it does not roll or swell across the path's plane: \(b)")
        // The profiles stay where they were drawn.
        #expect(try body.faceFrame("lf.start").origin.z < 1e-6)
        #expect(abs(try body.faceFrame("lf.end").origin.z - 40) < 1e-6)
    }

    @Test func anSBendJoinsProfilesThatAreNotAboveEachOther() throws {
        let r = try T.regen(Self.sections(shift: 30) + [Self.path([(0, 0), (0, 25), (30, 15), (30, 40)]), Self.loft()])
        let body = try #require(r.body("lf"))
        #expect(body.isValid)
        let b = try #require(body.bounds)
        #expect(abs(b.min.x + 10) < 0.5 && abs(b.max.x - 36) < 0.5, "\(b)")
        // The path meets both profiles at a right angle, so the shape stays square to it, like a duct: it is as wide in the
        // slanted middle as at the ends, where a plain loft (which shears straight across) gets thinner. So it holds more.
        let plain = try #require(try T.regen(Self.sections(shift: 30) + [Self.loft(path: false)]).body("lf"))
        #expect(body.volume > plain.volume * 1.05 && body.volume < plain.volume * 1.5, "\(body.volume) against \(plain.volume)")
    }

    @Test func anElbowJoinsProfilesOnPlanesThatAreSquareToEachOther() throws {
        // A circle on the floor and one on an upright plane 20 mm along x, joined by a quarter turn of radius 20.
        let circle = { (id: FeatureID, plane: PlaneRef, u: Double, v: Double, tag: EntityID) in
            T.sketch(id, on: plane) { s in
                let c = s.addPoint(u, v)
                s.constrain(.fix(c, x: u, y: v))
                s.addCircle(center: c, radius: 5, id: tag)
            }
        }
        let features = [circle("lo", .xy, 0, 0, "K1"),
                        Feature(id: "side", name: "side", .plane(PlaneFeature(base: .yz, offset: "20 mm"))),
                        circle("hi", .plane("side"), 0, 20, "K2"),
                        Self.path([(0, 0), (0, 11), (9, 20), (20, 20)]),
                        Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
                            LoftSection(sketch: "lo", profile: ProfileRef(curves: ["K1"])),
                            LoftSection(sketch: "hi", profile: ProfileRef(curves: ["K2"])),
                        ], path: CurveRef(sketch: "path", curves: ["P"]))))]
        let body = try #require(try T.regen(features).body("lf"))
        #expect(body.isValid)
        #expect(T.close(body.volume, .pi * 25 * (.pi / 2 * 20), 0.05), "a quarter of a ring: \(body.volume)")
        #expect(abs(try body.faceFrame("lf.end").origin.x - 20) < 1e-6)

        // The same profiles with a path that meets them at a slant: there is no good answer, and it says so.
        var slanted = CADDocument()
        slanted.features = features
        slanted.features[3] = Self.path([(0, 0), (8, 6), (14, 12), (20, 20)])
        #expect(Regenerator.regenerate(slanted).errors["lf"]?.contains("right angle") == true)
    }

    @Test func aLoftAlongAPathGoesThroughEveryProfile() throws {
        // Square, a small circle halfway up and off to the side, and the circle at the top.
        let middle = [Feature(id: "mid", name: "mid", .plane(PlaneFeature(base: .xy, offset: "20 mm"))),
                      T.sketch("waist", on: .plane("mid")) { s in
                          let c = s.addPoint(15, 0)
                          s.constrain(.fix(c, x: 15, y: 0))
                          s.addCircle(center: c, radius: 3, id: "W")
                      }]
        let three = Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
            LoftSection(sketch: "sq", profile: ProfileRef(curves: ["A", "B", "C", "D"])),
            LoftSection(sketch: "waist", profile: ProfileRef(curves: ["W"])),
            LoftSection(sketch: "ci", profile: ProfileRef(curves: ["K"])),
        ], path: CurveRef(sketch: "path", curves: ["P"]))))
        let body = try #require(try T.regen(Self.sections() + middle + [Self.path([(0, 0), (20, 10), (20, 30), (0, 40)]), three]).body("lf"))
        #expect(body.isValid)
        let two = try #require(try T.regen(Self.sections() + [Self.path([(0, 0), (20, 10), (20, 30), (0, 40)]), Self.loft()]).body("lf"))
        #expect(body.volume < two.volume * 0.8 && body.volume > two.volume * 0.2, "the waist takes volume away: \(body.volume) against \(two.volume)")
    }

    @Test func aPathLongerThanTheLoftIsCutAtTheProfiles() throws {
        let exact = try #require(try T.regen(Self.sections() + [Self.path([(0, 0), (0, 40)]), Self.loft()]).body("lf"))
        let long = try #require(try T.regen(Self.sections() + [Self.path([(0, -15), (0, 60)]), Self.loft()]).body("lf"))
        #expect(T.close(long.volume, exact.volume, 1e-3), "\(long.volume) against \(exact.volume)")
        let b = try #require(long.bounds)
        #expect(b.min.z > -1e-6 && b.max.z < 40 + 1e-6, "\(b)")
    }

    @Test func thePathCanBeDrawnEitherWayAndTheProfilesPickedEitherWay() throws {
        let forward = try #require(try T.regen(Self.sections() + [Self.path([(0, 0), (20, 10), (20, 30), (0, 40)]), Self.loft()]).body("lf"))
        let backward = try #require(try T.regen(Self.sections() + [Self.path([(0, 40), (20, 30), (20, 10), (0, 0)]), Self.loft()]).body("lf"))
        #expect(T.close(backward.volume, forward.volume, 1e-3))
        #expect(try backward.faceFrame("lf.start").origin.z < 1e-6, "start is the first profile, whichever way the path was drawn")
        let flipped = try #require(try T.regen(Self.sections() + [Self.path([(0, 0), (20, 10), (20, 30), (0, 40)]),
                                                                   Self.loft(reversed: true)]).body("lf"))
        #expect(T.close(flipped.volume, forward.volume, 1e-3))
        #expect(abs(try flipped.faceFrame("lf.start").origin.z - 40) < 1e-6)
        #expect(flipped.hasFace("lf.side.K"), "\(flipped.faceNames)")
    }

    @Test func ringsAlongAPathStayHollow() throws {
        let ring = { (id: FeatureID, plane: PlaneRef, outer: Double, inner: Double, tags: [EntityID]) in
            T.sketch(id, on: plane) { s in
                let c = s.addPoint(0, 0)
                s.constrain(.fix(c, x: 0, y: 0))
                s.addCircle(center: c, radius: outer, id: tags[0])
                s.addCircle(center: c, radius: inner, id: tags[1])
            }
        }
        let features = [ring("lo", .xy, 8, 6, ["O1", "I1"]),
                        Feature(id: "up", name: "up", .plane(PlaneFeature(base: .xy, offset: "40 mm"))),
                        ring("hi", .plane("up"), 8, 6, ["O2", "I2"]),
                        Self.path([(0, 0), (12, 10), (12, 30), (0, 40)]),
                        Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
                            LoftSection(sketch: "lo", profile: ProfileRef(curves: ["O1", "I1"])),
                            LoftSection(sketch: "hi", profile: ProfileRef(curves: ["O2", "I2"])),
                        ], path: CurveRef(sketch: "path", curves: ["P"]))))]
        let body = try #require(try T.regen(features).body("lf"))
        #expect(body.isValid)
        // The rings are parallel, so every slice is the ring: its area times the height.
        #expect(T.close(body.volume, .pi * (64 - 36) * 40, 0.01), "\(body.volume)")
        #expect(body.hasFace("lf.hole.I1"), "\(body.faceNames)")
    }

    @Test func aPathThatDoesNotRunBetweenTheProfilesIsAnError() throws {
        var doc = CADDocument()
        // A line along the floor: it never leaves the first profile's plane.
        doc.features = Self.sections() + [Self.path([(-20, 0), (20, 0)]), Self.loft()]
        let r = Regenerator.regenerate(doc)
        #expect(r.errors["lf"]?.contains("path") == true, "\(r.errors)")
    }

    @Test func curvesOfAnotherSketchLandInASketchAsTheRightKind() throws {
        let r = try T.regen(Self.sections(shift: 3) + [T.sketch("arcs") { s in
            let c = s.addPoint(0, 0), a = s.addPoint(5, 0), b = s.addPoint(0, 5)
            for (id, x, y) in [(c, 0.0, 0.0), (a, 5.0, 0.0), (b, 0.0, 5.0)] { s.constrain(.fix(id, x: x, y: y)) }
            s.addArc(center: c, start: a, end: b, id: "Q")
            let p = [(0.0, 0.0), (2, 6), (8, 6), (10, 0)].map { s.addPoint($0.0, $0.1) }
            for (id, at) in zip(p, [(0.0, 0.0), (2, 6), (8, 6), (10, 0)]) { s.constrain(.fix(id, x: at.0, y: at.1)) }
            s.addBezier(start: p[0], control1: p[1], control2: p[2], end: p[3], id: "Z")
        }])
        let sq = try #require(r.sketches["sq"]), ci = try #require(r.sketches["ci"]), arcs = try #require(r.sketches["arcs"])
        func near(_ a: SIMD2<Double>, _ x: Double, _ y: Double) -> Bool { abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9 }
        // Onto the upright XZ plane (x across, z up): flat sketches are seen edge-on.
        let side = try #require(Regenerator.sketchCurveSnap(sq, edge: EdgeRef(body: "sq", edge: "A"), frame: .xz))
        #expect(side.center == nil && side.chain == nil && abs(side.start.y) < 1e-9 && abs(side.end.y) < 1e-9)
        let disc = try #require(Regenerator.sketchCurveSnap(ci, edge: EdgeRef(body: "ci", edge: "K"), frame: .xz))
        #expect(disc.chain == nil && disc.center == nil, "a circle seen edge-on is the stretch it covers")
        #expect(near(disc.start, -3, 40) || near(disc.end, -3, 40), "\(disc)")
        #expect(near(disc.start, 9, 40) || near(disc.end, 9, 40), "\(disc)")
        let quarter = try #require(Regenerator.sketchCurveSnap(arcs, edge: EdgeRef(body: "arcs", edge: "Q"), frame: .xz))
        #expect(near(quarter.start, 0, 0) && near(quarter.end, 5, 0), "a quarter arc edge-on covers its radius: \(quarter)")
        // Onto the floor: the same curves land as themselves.
        let round = try #require(Regenerator.sketchCurveSnap(ci, edge: EdgeRef(body: "ci", edge: "K"), frame: .xy))
        let roundCenter = try #require(round.center)
        #expect(round.isFullCircle && near(roundCenter, 3, 0) && near(round.start, 9, 0))
        let arc = try #require(Regenerator.sketchCurveSnap(arcs, edge: EdgeRef(body: "arcs", edge: "Q"), frame: .xy))
        let arcCenter = try #require(arc.center)
        #expect(!arc.isFullCircle && near(arc.start, 5, 0) && near(arc.end, 0, 5) && near(arcCenter, 0, 0))
        let bezier = try #require(Regenerator.sketchCurveSnap(arcs, edge: EdgeRef(body: "arcs", edge: "Z"), frame: .xy))
        #expect(bezier.chain?.count == 4 && near(bezier.end, 10, 0))
        // Onto a plane at 45 degrees a circle is an ellipse: Bézier pieces through it, closing on themselves.
        let tilted = Frame(origin: .zero, normal: simd_normalize(SIMD3(0, -1, 1)), xAxis: SIMD3(1, 0, 0))
        let oval = try #require(Regenerator.sketchCurveSnap(ci, edge: EdgeRef(body: "ci", edge: "K"), frame: tilted))
        let chain = try #require(oval.chain)
        #expect((chain.count - 1) % 3 == 0 && chain.first == chain.last)
        let xs = chain.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.x), ys = chain.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.y)
        #expect(abs(xs.max()! - xs.min()! - 12) < 1e-6, "full width across")
        #expect(abs(ys.max()! - ys.min()! - 12 * 0.5.squareRoot()) < 1e-6, "squashed the other way")
        #expect(Regenerator.sketchCurveSnap(sq, edge: EdgeRef(body: "sq", edge: "nope"), frame: .xz) == nil)
    }

    @Test func aLoftSavedBeforePathsExistedStillOpens() throws {
        let old = LoftFeature(sections: [LoftSection(sketch: "a", profile: ProfileRef(curves: ["A"])),
                                         LoftSection(sketch: "b", profile: ProfileRef(curves: ["B"]))])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["path"] = nil
        let back = try JSONDecoder().decode(LoftFeature.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back == old && back.path == nil)
        let with = LoftFeature(sections: old.sections, path: CurveRef(sketch: "p", curves: ["P"]))
        #expect(try JSONDecoder().decode(LoftFeature.self, from: JSONEncoder().encode(with)) == with)
        #expect(Feature(id: "lf", name: "lf", .loft(with)).sketchesUsed == ["a", "b", "p"])
    }
}

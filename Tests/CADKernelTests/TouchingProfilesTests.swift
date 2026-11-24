// Profiles that touch one another (circles tangent to within the solver's last billionth of a millimetre) sweep, revolve and extrude as
// the separate solids they are, instead of failing as "an invalid solid".
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct TouchingProfilesTests {
    typealias T = NewFeatureTests

    static let path = T.sketch("path", on: .xz) { s in
        let p = [(0.0, 0.0), (40.0, 10.0), (40.0, 50.0), (0.0, 60.0)].map { pt -> EntityID in
            let id = s.addPoint(pt.0, pt.1); s.constrain(.fix(id, x: pt.0, y: pt.1)); return id
        }
        s.addBezier(start: p[0], control1: p[1], control2: p[2], end: p[3], id: "B")
    }
    static let plane = Feature(id: "pp", name: "pp", .plane(PlaneFeature(along: CurveRef(sketch: "path", curves: ["B"]), position: "1")))

    /// Twelve Ø5 circles round a ring, held tangent by the solver (so they touch to about 1e-9 rather than exactly): one original and
    /// its copies from a circular pattern, with a Tangent between the original and its neighbour.
    static func ring(on plane: PlaneRef) -> (Feature, [ProfileRef]) {
        var s = Sketch()
        let c = s.addPoint(-8, 6)
        s.addCircle(center: c, radius: 2.5, id: "src")
        s.dimension(.diameter("src"), "5 mm", id: "d")
        s.patterns = [SketchPatternDef(id: "pat", kind: .circular, sources: ["src"], count: "12", angle: "360 deg", center: "origin")]
        s.refreshGenerated(ParameterValues())
        s.constrain(.tangent("src", "pat~11~src"))
        let ids: [EntityID] = ["src"] + (1...11).map { "pat~\($0)~src" }
        return (Feature(id: "ring", name: "ring", .sketch(SketchFeature(plane: plane, sketch: s))), ids.map { ProfileRef(curves: [$0]) })
    }

    @Test func aRingOfTouchingCirclesSweepsAlongACurvedPath() throws {
        let (ring, profiles) = Self.ring(on: .plane("pp"))
        let sweep = Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "ring", profiles: profiles, path: CurveRef(sketch: "path", curves: ["B"]))))
        // Each circle swept on its own, for what the whole should come to.
        let singles = profiles.enumerated().map { i, p in
            Feature(id: "one\(i)", name: "one\(i)", .sweep(SweepFeature(sketch: "ring", profiles: [p], path: CurveRef(sketch: "path", curves: ["B"]))))
        }
        let r = try T.regen([Self.path, Self.plane, ring, sweep] + singles)
        let body = try #require(r.body("sw"))
        #expect(body.isValid)
        let expected = try singles.reduce(0.0) { $0 + (try #require(r.body($1.id)).volume) }
        #expect(abs(body.volume - expected) < 1e-6 * expected, "\(body.volume) against the twelve swept alone: \(expected)")
    }

    @Test func theSameRingExtrudesAndRevolves() throws {
        let (ring, profiles) = Self.ring(on: .xy)
        let extrude = Feature(id: "ex", name: "ex", .extrude(ExtrudeFeature(sketch: "ring", profiles: profiles, extent: .distance("10 mm"))))
        // Round the Y axis, far enough off that the ring does not cross it: a ring of 12 tori.
        let ringAway = T.sketch("far", on: .xz) { s in
            let c = s.addPoint(40, 0)
            s.constrain(.fix(c, x: 40, y: 0))
            s.addCircle(center: c, radius: 2.5, id: "k")
        }
        let revolve = Feature(id: "rv", name: "rv", .revolve(RevolveFeature(sketch: "far", profiles: [ProfileRef(curves: ["k"])], axis: .z, angle: "360 deg")))
        let r = try T.regen([ring, extrude, ringAway, revolve])
        let body = try #require(r.body("ex"))
        #expect(body.isValid && T.close(body.volume, 12 * .pi * 6.25 * 10, 1e-6), "\(body.volume)")
        #expect(try #require(r.body("rv")).isValid)
    }
}

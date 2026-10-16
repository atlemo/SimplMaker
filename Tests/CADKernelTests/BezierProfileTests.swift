// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A Bézier curve closes profiles like any other sketch curve.
@Suite struct BezierProfileTests {
    @Test func aCurveAndALineMakeAProfileThatExtrudes() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(30, 0)
        s.addLine(a, b)
        s.addBezier(start: a, control1: s.addPoint(0, 20), control2: s.addPoint(30, 20), end: b)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        #expect(sk.regions.count == 1)
        let region = try #require(sk.regions.first)
        // Area under the cubic: 3/10 · (sum of the handle heights) · width = 0.3 · 40 · 30.
        #expect(abs(region.area - 360) < 1e-3, "\(region.area)")
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)],
            extent: .distance("2 mm")))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("e")).volume - 720) < 1e-2)
    }

    /// A strip whose top edge is a run of smooth cubics (and bottom one cubic), closed with two lines.
    private func strip(sharpMiddle: Bool = false) throws -> (CADDocument, ProfileRef) {
        var s = Sketch()
        let p0 = s.addPoint(0, 0), p1 = s.addPoint(40, 0), p2 = s.addPoint(80, 10), p3 = s.addPoint(100, 40)
        let q0 = s.addPoint(0, -10), q3 = s.addPoint(100, 30)
        s.addBezier(start: p0, control1: s.addPoint(15, 0), control2: s.addPoint(25, 0), end: p1)
        // A smooth join keeps the handle on the line through the joint; a sharp one breaks it.
        s.addBezier(start: p1, control1: s.addPoint(55, sharpMiddle ? 12 : 0), control2: s.addPoint(70, 3), end: p2)
        s.addBezier(start: p2, control1: s.addPoint(90, 17), control2: s.addPoint(98, 28), end: p3)
        s.addBezier(start: q0, control1: s.addPoint(60, -10), control2: s.addPoint(95, 5), end: q3)
        s.addLine(p0, q0); s.addLine(p3, q3)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        let region = try #require(sk.regions.first)
        let ref = ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ref], extent: .distance("2 mm")))))
        return (d, ref)
    }

    @Test func aSmoothRunOfCubicsExtrudesToOneSideFace() throws {
        let (d, ref) = try strip()
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("e"))
        // Top run (1), bottom curve (1), two end lines (2), and the two caps.
        #expect(body.faceNames.count == 6, "\(body.faceNames)")
        #expect(ref.curves.count == 6, "the profile still names every sketch curve: \(ref.curves)")
        #expect(body.volume > 0)
    }

    @Test func aSharpCornerBetweenCubicsKeepsItsSeam() throws {
        let (d, _) = try strip(sharpMiddle: true)
        let body = try #require(Regenerator.regenerate(d).body("e"))
        #expect(body.faceNames.count == 7, "\(body.faceNames)")
    }
}

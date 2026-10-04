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
}

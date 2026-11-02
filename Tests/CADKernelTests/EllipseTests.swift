// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// An ellipse closes a profile like a circle: its four Bézier quarters make one region, which extrudes.
@Suite struct EllipseTests {
    @Test func anEllipseExtrudesToItsAreaTimesTheDepth() throws {
        var s = Sketch()
        _ = s.addEllipse(center: SketchSnap(SIMD2(0, 0)), major: SketchSnap(SIMD2(10, 0)), minor: SketchSnap(SIMD2(0, 5)))
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        #expect(sk.regions.count == 1)
        let region = try #require(sk.regions.first)
        // π · 10 · 5, and the Bézier quarters are within a fraction of a percent of that.
        #expect(abs(region.area - Double.pi * 50) / (Double.pi * 50) < 2e-3, "\(region.area)")
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)],
            extent: .distance("2 mm")))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("e")).volume - 2 * Double.pi * 50) / (2 * Double.pi * 50) < 2e-3)
    }
}

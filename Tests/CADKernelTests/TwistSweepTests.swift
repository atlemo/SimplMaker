// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// Twist Sweep: a profile pushed along a straight line while it turns about it and slides sideways.
@Suite struct TwistSweepTests {
    /// A 10 × 2 bar (x from -5 to 5, y from -1 to 1) on the xy plane, swept by `twist`.
    private func bar(_ twist: TwistSweepFeature? = nil, _ change: (inout TwistSweepFeature) -> Void = { _ in }) -> CADDocument {
        var s = Sketch()
        s.addRectangle(-5, -1, 5, 1)
        var f = twist ?? TwistSweepFeature(sketch: "sk", profiles: [ProfileRef(curves: [], hintU: 0, hintV: 0)], distance: "30 mm",
                                           endAngle: "90 deg")
        change(&f)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
                      Feature(id: "tw", name: "Twist Sweep1", .twistSweep(f))]
        return d
    }

    private func bounds(_ r: RegenResult) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        try #require(try r.body("tw")?.measure(.body).bounds)
    }

    @Test func aTwistedBarKeepsItsCrossSectionArea() throws {
        let r = Regenerator.regenerate(bar())
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("tw"))
        #expect(body.isValid)
        // Turning a section about its own middle does not change its area, so the volume is the area times the length.
        #expect(abs(body.volume - 600) < 6, "volume \(body.volume)")
        let b = try bounds(r)
        #expect(abs(b.min.z) < 0.05 && abs(b.max.z - 30) < 0.05)
        // The corners of the bar are 5.1 mm from the axis, and the sweep is smooth, so nothing reaches past that.
        #expect(b.max.x < 5.15 && b.max.y < 5.15 && b.min.x > -5.15 && b.min.y > -5.15, "\(b)")
        // The far end has turned a quarter: the 10 mm side now runs along y.
        #expect(b.max.y > 4.9)
    }

    @Test func noTurnAndNoSlideIsAnExtrude() throws {
        let r = Regenerator.regenerate(bar { $0.endAngle = "0 deg" })
        let body = try #require(r.body("tw"))
        #expect(abs(body.volume - 600) < 0.5)
        let b = try bounds(r)
        #expect(abs(b.max.x - 5) < 0.05 && abs(b.max.y - 1) < 0.05)
    }

    @Test func flippingRunsAgainstTheSketchNormal() throws {
        let r = Regenerator.regenerate(bar { $0.flipped = true })
        let b = try bounds(r)
        #expect(abs(b.max.z) < 0.05 && abs(b.min.z + 30) < 0.05, "\(b)")
    }

    @Test func slidingMovesTheEndSideways() throws {
        let r = Regenerator.regenerate(bar { $0.endAngle = "0 deg"; $0.shiftV = "10 mm"; $0.shiftU = "-4 mm" })
        let b = try bounds(r)
        // The end section has moved by (-4, 10); the start has not.
        #expect(abs(b.max.y - 11) < 0.05 && abs(b.min.x + 9) < 0.05 && abs(b.max.x - 5) < 0.05 && abs(b.min.y + 1) < 0.05, "\(b)")
        #expect(abs(try #require(r.body("tw")).volume - 600) < 0.5, "a lean keeps the volume")
    }

    @Test func theProfileCanTurnAboutAPointOfItsOwn() throws {
        // About (5, 0), the bar's right end: after a quarter turn the 10 mm side hangs down from there.
        let r = Regenerator.regenerate(bar { $0.pivotU = "5 mm"; $0.pivotV = "0 mm" })
        #expect(r.errors.isEmpty, "\(r.errors)")
        let b = try bounds(r)
        #expect(abs(b.min.y + 10) < 0.1, "\(b)")
        #expect(b.max.x < 6.01, "\(b)")
    }

    @Test func sketchedOnAnotherPlaneItRunsAlongThatNormal() throws {
        // A bar drawn on the yz plane runs along X.
        var s = Sketch()
        s.addRectangle(-5, -1, 5, 1)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .yz, sketch: s))),
                      Feature(id: "tw", name: "Twist Sweep1", .twistSweep(TwistSweepFeature(
                          sketch: "sk", profiles: [ProfileRef(curves: [], hintU: 0, hintV: 0)], distance: "40 mm", endAngle: "60 deg")))]
        let r = Regenerator.regenerate(d)
        let b = try bounds(r)
        #expect(abs(b.min.x) < 0.05 && abs(b.max.x - 40) < 0.05, "\(b)")
        #expect(abs(try #require(r.body("tw")).volume - 800) < 8)
    }

    @Test func aBadSettingSaysWhy() throws {
        let zero = Regenerator.regenerate(bar { $0.distance = "0 mm" })
        #expect(zero.errors["tw"]?.contains("length") == true, "\(zero.errors)")
        let curve = Regenerator.regenerate(bar { $0.curve = "0" })
        #expect(curve.errors["tw"]?.contains("curve") == true, "\(curve.errors)")
    }

    @Test func aTwistedPlateCutToAnOutlineIsABlade() throws {
        // The blade recipe: a thin plate that turns by 40°, intersected with a straight extrusion of its outline.
        var plate = Sketch()
        plate.addRectangle(-30, -0.75, 30, 0.75)  // a 60 × 1.5 section on the yz plane: y = across, z = thickness
        var outline = Sketch()
        outline.addRectangle(0, -20, 50, 20)  // the plan outline on xy: x along the blade, y across
        var d = CADDocument()
        d.features = [
            Feature(id: "sk", name: "Section", .sketch(SketchFeature(plane: .yz, sketch: plate))),
            Feature(id: "tw", name: "Twist", .twistSweep(TwistSweepFeature(
                sketch: "sk", profiles: [ProfileRef(curves: [], hintU: 0, hintV: 0)], distance: "50 mm", endAngle: "-40 deg", curve: "2"))),
            Feature(id: "so", name: "Outline", .sketch(SketchFeature(plane: .xy, sketch: outline))),
            Feature(id: "cut", name: "Cut", .extrude(ExtrudeFeature(sketch: "so", profiles: [ProfileRef(curves: [], hintU: 25, hintV: 0)],
                                                                    extent: .symmetric("100 mm"), operation: .intersect, target: "tw"))),
        ]
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let blade = try #require(r.body("tw"))
        #expect(blade.isValid)
        // 40 wide × 50 long × 1.5 thick, give or take what the tilt adds to the cut: a thin plate, not a lump.
        #expect(blade.volume > 40 * 50 * 1.5 * 0.9 && blade.volume < 40 * 50 * 1.5 * 1.35, "volume \(blade.volume)")
        let b = try blade.measure(.body).bounds
        #expect(abs(b.max.y - 20) < 0.05 && abs(b.min.y + 20) < 0.05, "the outline's width, \(b)")
    }

    @Test func aCurvedProfileTwistsThroughAnyAngleQuicklyAndExactly() throws {
        // An 84 × 12 ellipse (four Bézier quarters), as drawn with the Ellipse tool. The loft's own search for how the corners of
        // one section map to the next used to fail (after seconds, or minutes) or turn the solid inside out once the sections had
        // turned a long way from each other; the sections are copies of one wire, so they are used as they are.
        var s = Sketch()
        _ = s.addEllipse(center: SketchSnap(SIMD2(0, 0)), major: SketchSnap(SIMD2(42, 0)), minor: SketchSnap(SIMD2(0, 6)))
        var base = CADDocument()
        base.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .yz, sketch: s)))]
        let sketch = try #require(Regenerator.regenerate(base).sketches["sk"])
        let region = try #require(sketch.regions.first)
        let ref = ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)
        for (length, angle) in [(28.0, 68.0), (39, 90), (64, 116), (39, -120), (50, 180), (80, 360)] {
            var d = base
            d.features.append(Feature(id: "tw", name: "Twist", .twistSweep(TwistSweepFeature(
                sketch: "sk", profiles: [ref], distance: "\(length) mm", endAngle: "\(angle) deg"))))
            let began = Date()
            let r = Regenerator.regenerate(d)
            #expect(r.errors.isEmpty, "\(length) mm, \(angle)°: \(r.errors)")
            let body = try #require(r.body("tw"), "\(length) mm, \(angle)°")
            #expect(body.isValid)
            #expect(abs(body.volume - region.area * length) / (region.area * length) < 0.002, "\(length) mm, \(angle)°: volume \(body.volume)")
            #expect(Date().timeIntervalSince(began) < 3, "\(length) mm, \(angle)° took \(Date().timeIntervalSince(began)) s")
        }
    }

    @Test func aProfileWithAHoleTwistsAndKeepsItsBore() throws {
        // A 20 × 20 plate with a 6 mm hole, turned half a revolution: the hole's wires are copies too.
        var s = Sketch()
        s.addRectangle(-10, -10, 10, 10)
        _ = s.addCircle(center: SketchSnap(SIMD2(2, 0)), through: SketchSnap(SIMD2(5, 0)))
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sketch = try #require(Regenerator.regenerate(d).sketches["sk"])
        let plate = try #require(sketch.regions.max { $0.area < $1.area })
        d.features.append(Feature(id: "tw", name: "Twist", .twistSweep(TwistSweepFeature(
            sketch: "sk", profiles: [ProfileRef(curves: plate.tags.split(separator: ",").map(String.init), hintU: plate.sample.x, hintV: plate.sample.y)],
            distance: "20 mm", endAngle: "180 deg"))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("tw"))
        #expect(body.isValid)
        let expected = (400 - Double.pi * 9) * 20
        #expect(abs(body.volume - expected) / expected < 0.01, "volume \(body.volume) against \(expected)")
    }
}

// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A gear sketch closes into one profile (with the bore as a hole) and extrudes to a solid of the right size.
@Suite struct GearTests {
    /// Area inside the outline by the shoelace formula over finely flattened curves.
    private func outlineArea(_ spec: GearSpec) throws -> Double {
        var pts: [SIMD2<Double>] = []
        for piece in try GearProfile.outline(spec) {
            switch piece {
            case .line(let a, _): pts.append(a)
            case .bezier(let a, let b, let c, let d): pts.append(contentsOf: Bezier.flatten([a, b, c, d], steps: 200).dropLast())
            case .arc(let a, let b):
                let a0 = atan2(a.y, a.x), r = hypot(a.x, a.y)
                var sweep = atan2(b.y, b.x) - a0
                if sweep < 0 { sweep += 2 * .pi }
                for k in 0..<200 { let t = a0 + sweep * Double(k) / 200; pts.append(SIMD2(r * cos(t), r * sin(t))) }
            }
        }
        var twice = 0.0
        for i in 0..<pts.count { let p = pts[i], q = pts[(i + 1) % pts.count]; twice += p.x * q.y - q.x * p.y }
        return twice / 2
    }

    private func document(_ def: SketchGearDef, parameters: [Parameter] = []) throws -> CADDocument {
        var s = Sketch()
        var def = def
        def.center = s.addPoint(0, 0)
        try s.addGear(def, ParameterEvaluator.evaluate(parameters))
        var d = CADDocument()
        d.parameters = parameters
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        return d
    }

    /// The biggest region (the toothed ring, when there is a bore) and a profile reference to it.
    private func ringProfile(_ d: CADDocument) throws -> (area: Double, ref: ProfileRef) {
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        let region = try #require(sk.regions.max { $0.area < $1.area })
        return (region.area, ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y))
    }

    private func extruded(_ d: CADDocument, _ ref: ProfileRef) -> CADDocument {
        var d = d
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ref], extent: .distance("5 mm")))))
        return d
    }

    @Test(arguments: [SketchGearDef(teeth: "12", module: "2 mm", bore: "6 mm"), SketchGearDef(teeth: "24", module: "1.5 mm", backlash: "0.15 mm", bore: "5 mm"),
                      SketchGearDef(teeth: "48", module: "1 mm")])
    func aGearExtrudes(def: SketchGearDef) throws {
        let d = try document(def)
        let spec = try def.spec(ParameterValues())
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        // With a bore there are two regions: the toothed ring, and the disc in the hole.
        #expect(sk.regions.count == (spec.boreDiameter > 0 ? 2 : 1), "\(sk.regions.map(\.area))")
        let (area, ref) = try ringProfile(d)
        let bore = spec.boreDiameter > 0 ? Double.pi * pow(spec.boreDiameter / 2, 2) : 0
        let expected = try outlineArea(spec) - bore
        #expect(abs(area - expected) < 0.01, "\(area) vs \(expected)")
        let r = Regenerator.regenerate(extruded(d, ref))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("e")).volume - expected * 5) < 0.1)
    }

    @Test func theSolidFollowsTheGearWhenItsValuesChange() throws {
        let d = try document(SketchGearDef(teeth: "12", module: "2 mm", bore: "6 mm"))
        let (_, ref) = try ringProfile(d)
        var edited = extruded(d, ref)
        for (teeth, module) in [("16", "2 mm"), ("16", "3 mm"), ("30", "1.5 mm")] {
            guard case .sketch(var sf) = edited.features[0].kind else { return }
            sf.sketch.gears[0].teeth = teeth
            sf.sketch.gears[0].module = module
            edited.features[0].kind = .sketch(sf)
            let r = Regenerator.regenerate(edited)
            #expect(r.errors.isEmpty, "\(teeth) teeth, module \(module): \(r.errors)")
            let spec = try sf.sketch.gears[0].spec(ParameterValues())
            let expected = try outlineArea(spec) - Double.pi * 9
            #expect(abs(try #require(r.body("e")).volume - expected * 5) < 0.1, "\(teeth) teeth, module \(module)")
        }
    }

    @Test func aParameterDrivesTheSolid() throws {
        let params = [Parameter("n", "14", unit: .none), Parameter("mod", "2 mm")]
        let d = try document(SketchGearDef(teeth: "n", module: "mod"), parameters: params)
        let (_, ref) = try ringProfile(d)
        var edited = extruded(d, ref)
        let before = try #require(Regenerator.regenerate(edited).body("e")).volume
        edited.parameters = [Parameter("n", "26", unit: .none), Parameter("mod", "2 mm")]
        let r = Regenerator.regenerate(edited)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(try #require(r.body("e")).volume > before * 2.5, "twice the teeth is a bigger wheel")
    }

    @Test func aGearThatCantBeMadeIsReportedNotDrawn() throws {
        var d = try document(SketchGearDef())
        guard case .sketch(var sf) = d.features[0].kind else { return }
        sf.sketch.gears[0].teeth = "3"
        d.features[0].kind = .sketch(sf)
        #expect(Regenerator.regenerate(d).errors.values.contains { $0.contains("gear") })
    }
}

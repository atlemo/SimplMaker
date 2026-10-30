// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Combining bodies (cutting text out of a plate), moving sketches, and cuts that remove everything.
@Suite struct CombineTests {
    /// Text "test" extruded 3 mm, and a 43 × 16 × 2 mm plate under and around it, as two bodies.
    private func textAndPlate() throws -> CADDocument {
        var s = Sketch()
        let p = s.addPoint(0, 0)
        s.constrain(.fix(p, x: 0, y: 0))
        s.texts = [SketchText(id: "T", text: "test", position: p, height: "9 mm")]
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        // The letters, without the hole in the "e".
        let letters = sk.regions.filter { r in !sk.regions.contains { $0.tags != r.tags && $0.tags.split(separator: ",").contains(Substring(r.tags)) } }
        #expect(letters.count == 4)
        d.features.append(Feature(id: "text", name: "Extrude1", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: letters.map { ProfileRef(curves: $0.tags.split(separator: ",").map(String.init), hintU: $0.sample.x, hintV: $0.sample.y) },
            extent: .distance("3 mm")))))
        var s2 = Sketch()
        s2.addRectangle(-3, -3, 40, 13)
        d.features.append(Feature(id: "sk2", name: "Sketch2", .sketch(SketchFeature(plane: .xy, sketch: s2))))
        d.features.append(Feature(id: "plate", name: "Extrude2", .extrude(ExtrudeFeature(
            sketch: "sk2", profiles: [ProfileRef(curves: [], hintU: 0, hintV: 0)], extent: .distance("2 mm")))))
        let sk2 = try #require(Regenerator.regenerate(d).sketches["sk2"])
        if case .extrude(var e) = d.features[3].kind, let region = sk2.regions.first {
            e.profiles = [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)]
            d.features[3].kind = .extrude(e)
        }
        return d
    }

    @Test func textCutsOutOfAPlate() throws {
        var d = try textAndPlate()
        let before = Regenerator.regenerate(d)
        #expect(before.errors.isEmpty, "\(before.errors)")
        let text = try #require(before.body("text")).volume, plate = try #require(before.body("plate")).volume
        d.features.append(Feature(id: "c", name: "Combine1", .combine(CombineFeature(target: "plate", tools: ["text"], operation: .cut))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.map(\.id) == ["plate"], "the text is used up")
        let cut = try #require(r.body("plate")).volume
        #expect(abs(cut - (plate - text * 2 / 3)) < 1e-3, "the letters' bottom 2 mm are hollowed out of the plate: \(cut)")

        if case .combine(var c) = d.features[4].kind { c.keepTools = true; c.operation = .join; d.features[4].kind = .combine(c) }
        let joined = Regenerator.regenerate(d)
        let joinedPlate = try #require(joined.body("plate")).volume
        #expect(joined.bodies.count == 2 && abs(joinedPlate - (plate + text / 3)) < 1e-3, "\(joinedPlate)")
    }

    @Test func aCutThatRemovesEverythingIsAnError() throws {
        var d = try textAndPlate()
        d.features.append(Feature(id: "c", name: "Combine1", .combine(CombineFeature(target: "text", tools: ["plate"], operation: .cut))))
        #expect(Regenerator.regenerate(d).errors["c"] == nil, "the plate only takes the letters' bottom 2 mm")
        if case .extrude(var e) = d.features[3].kind { e.extent = .distance("5 mm"); d.features[3].kind = .extrude(e) }
        #expect(Regenerator.regenerate(d).errors["c"]?.contains("removes the whole body") == true)
    }

    @Test func movingASketchMovesWhatIsBuiltFromItAfterwards() throws {
        var d = try textAndPlate()
        d.features.insert(Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: [], sketches: ["sk2"], dz: "10 mm"))), at: 3)
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let plate = try #require(r.body("plate")?.bounds)
        #expect(abs(plate.min.z - 10) < 1e-6 && abs(plate.max.z - 12) < 1e-6, "\(plate)")
        let input = try #require(r.sketchInputs["m"]?["sk2"])
        #expect(abs(input.frame.origin.z) < 1e-9, "the handle starts where the sketch was")
        let back = try CADDocument.decode(try d.encoded())
        #expect(back == d)
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Choosing which bodies an extrude's Join, Cut or Intersect works on.
@Suite struct ExtrudeTargetsTests {
    /// Two 10 × 10 × 10 mm blocks, "a" at x 0…10 and "b" at x 20…30, and a second extrude on top of them.
    private func document(operation: BodyOperation, x0: Double, x1: Double, y0: Double, y1: Double, distance: String,
                          targets: [FeatureID]?) -> CADDocument {
        var d = CADDocument()
        for (id, x) in [("a", 0.0), ("b", 20.0)] {
            var s = Sketch()
            s.addRectangle(x, 0, x + 10, 10)
            d.features.append(Feature(id: "\(id)sk", name: "Sketch \(id)", .sketch(SketchFeature(plane: .xy, sketch: s))))
            d.features.append(Feature(id: id, name: "Block \(id)", .extrude(ExtrudeFeature(
                sketch: "\(id)sk", profiles: [ProfileRef(curves: [], hintU: x + 5, hintV: 5)], extent: .distance("10 mm")))))
        }
        var s = Sketch()
        s.addRectangle(x0, y0, x1, y1)
        d.features.append(Feature(id: "tsk", name: "Tool sketch", .sketch(SketchFeature(plane: .xy, sketch: s))))
        var tool = ExtrudeFeature(sketch: "tsk", profiles: [ProfileRef(curves: [], hintU: (x0 + x1) / 2, hintV: (y0 + y1) / 2)],
                                  extent: .distance(distance), operation: operation)
        tool.targets = targets
        d.features.append(Feature(id: "t", name: "Tool", .extrude(tool)))
        return d
    }

    private func slot(targets: [FeatureID]?) -> CADDocument {
        document(operation: .cut, x0: -5, x1: 35, y0: 4, y1: 6, distance: "20 mm", targets: targets)
    }

    @Test func aCutWithoutAChoiceGoesThroughEveryBodyItReaches() throws {
        let r = Regenerator.regenerate(slot(targets: nil))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("a")).volume - 800) < 1e-3)
        #expect(abs(try #require(r.body("b")).volume - 800) < 1e-3)
        #expect(r.affectedBodies["t"] == ["a", "b"])
    }

    @Test func aCutOnlyCutsThePickedBodies() throws {
        let r = Regenerator.regenerate(slot(targets: ["a"]))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("a")).volume - 800) < 1e-3)
        #expect(abs(try #require(r.body("b")).volume - 1000) < 1e-3, "b was not picked")
        #expect(r.affectedBodies["t"] == ["a"])
    }

    @Test func aCutSkipsAPickedBodyItDoesNotReach() throws {
        let d = document(operation: .cut, x0: -5, x1: 15, y0: 4, y1: 6, distance: "20 mm", targets: ["a", "b"])
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("b")).volume - 1000) < 1e-3)
        #expect(r.affectedBodies["t"] == ["a"], "only the bodies actually cut")
    }

    @Test func joiningSeveralBodiesMergesThemWithTheTool() throws {
        // A bar from x = 5 to 25 bridges the blocks.
        let d = document(operation: .join, x0: 5, x1: 25, y0: 0, y1: 10, distance: "10 mm", targets: ["a", "b"])
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.map(\.id) == ["a"], "b is merged into a")
        #expect(abs(try #require(r.body("a")).volume - 3000) < 1e-3)
        #expect(r.affectedBodies["t"] == ["a", "b"])
    }

    @Test func joiningOnePickedBodyLeavesTheOthers() throws {
        let d = document(operation: .join, x0: 5, x1: 15, y0: 0, y1: 10, distance: "10 mm", targets: ["a"])
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.map(\.id) == ["a", "b"])
        #expect(abs(try #require(r.body("a")).volume - 1500) < 1e-3)
    }

    @Test func pickingNothingOrAMissingBodyIsAnError() {
        #expect(Regenerator.regenerate(slot(targets: [])).errors["t"]?.contains("pick the bodies") == true)
        #expect(Regenerator.regenerate(slot(targets: ["gone"])).errors["t"]?.contains("missing") == true)
    }

    @Test func thePickedBodiesSurviveSavingAndOldFilesLoad() throws {
        var e = ExtrudeFeature(sketch: "sk", profiles: [], extent: .distance("4 mm"))
        #expect(try JSONDecoder().decode(ExtrudeFeature.self, from: JSONEncoder().encode(e)).targets == nil)
        e.targets = ["a", "b"]
        #expect(try JSONDecoder().decode(ExtrudeFeature.self, from: JSONEncoder().encode(e)).targets == ["a", "b"])
    }
}

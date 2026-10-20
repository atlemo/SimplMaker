// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Choosing which bodies a sweep's Join, Cut or Intersect works on.
@Suite struct SweepTargetsTests {
    /// Two 10 × 10 × 10 mm blocks, "a" at y 10…20 and "b" at y 30…40 (x -5…5, z -5…5), and a round sweep of radius 2
    /// along the y axis from 0 to 50 that passes through both.
    private func document(operation: BodyOperation, targets: [FeatureID]?) -> CADDocument {
        var d = CADDocument()
        for (id, y) in [("a", 10.0), ("b", 30.0)] {
            var s = Sketch()
            s.addRectangle(-5, y, 5, y + 10)
            d.features.append(Feature(id: "\(id)sk", name: "Sketch \(id)", .sketch(SketchFeature(plane: .xy, sketch: s))))
            d.features.append(Feature(id: id, name: "Block \(id)", .extrude(ExtrudeFeature(
                sketch: "\(id)sk", profiles: [ProfileRef(curves: [], hintU: 0, hintV: y + 5)], extent: .twoSides("5 mm", back: "5 mm")))))
        }
        var path = Sketch()
        let p = path.addPoint(0, 0), q = path.addPoint(0, 50)
        path.constrain(.fix(p, x: 0, y: 0)); path.constrain(.fix(q, x: 0, y: 50))
        path.addLine(p, q, id: "P")
        d.features.append(Feature(id: "path", name: "Path", .sketch(SketchFeature(plane: .xy, sketch: path))))
        var prof = Sketch()
        let c = prof.addPoint(0, 0)
        prof.constrain(.fix(c, x: 0, y: 0))
        prof.addCircle(center: c, radius: 2, id: "C")
        d.features.append(Feature(id: "prof", name: "Profile", .sketch(SketchFeature(plane: .xz, sketch: prof))))
        var sweep = SweepFeature(sketch: "prof", profiles: [ProfileRef(curves: ["C"])],
                                 path: CurveRef(sketch: "path", curves: ["P"]), operation: operation)
        sweep.targets = targets
        d.features.append(Feature(id: "sw", name: "Sweep", .sweep(sweep)))
        return d
    }

    private let hole = Double.pi * 4 * 10  // the sweep's length inside one block

    @Test func aCutWithoutAChoiceGoesThroughEveryBodyItReaches() throws {
        let r = Regenerator.regenerate(document(operation: .cut, targets: nil))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("a")).volume - (1000 - hole)) < 1e-2)
        #expect(abs(try #require(r.body("b")).volume - (1000 - hole)) < 1e-2)
        #expect(r.affectedBodies["sw"] == ["a", "b"])
    }

    @Test func aCutOnlyCutsThePickedBodies() throws {
        let r = Regenerator.regenerate(document(operation: .cut, targets: ["a"]))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs(try #require(r.body("a")).volume - (1000 - hole)) < 1e-2)
        #expect(abs(try #require(r.body("b")).volume - 1000) < 1e-2, "b was not picked")
        #expect(r.affectedBodies["sw"] == ["a"])
    }

    @Test func joiningSeveralBodiesMergesThemWithTheSweep() throws {
        let r = Regenerator.regenerate(document(operation: .join, targets: ["a", "b"]))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.map(\.id) == ["a"], "b is merged into a")
        // Both blocks, plus the rod outside them: 50 mm long, 20 mm of it inside the blocks.
        #expect(abs(try #require(r.body("a")).volume - (2000 + Double.pi * 4 * 30)) < 1e-1)
        #expect(r.affectedBodies["sw"] == ["a", "b"])
    }

    @Test func pickingNothingOrAMissingBodyIsAnError() {
        #expect(Regenerator.regenerate(document(operation: .cut, targets: [])).errors["sw"]?.contains("pick the bodies") == true)
        #expect(Regenerator.regenerate(document(operation: .cut, targets: ["gone"])).errors["sw"]?.contains("missing") == true)
    }

    @Test func thePickedBodiesSurviveSavingAndOldFilesLoad() throws {
        var s = SweepFeature(sketch: "sk", profiles: [], path: CurveRef(sketch: "p", curves: ["P"]))
        #expect(try JSONDecoder().decode(SweepFeature.self, from: JSONEncoder().encode(s)).targets == nil)
        s.targets = ["a", "b"]
        #expect(try JSONDecoder().decode(SweepFeature.self, from: JSONEncoder().encode(s)).targets == ["a", "b"])
    }
}

// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Feedback: moving or scaling a sketch leaves what was built from it where it was, so one source gives shapes of
/// different sizes. A move or scale of sketches alone now carries what was made from them (the default); the choice
/// "only what comes after" keeps the old behaviour.
@Suite struct SketchTransformCarryTests {
    /// A 10 × 4 sketch, a 3 mm extrusion of it, then the transform, then a second extrusion of the same sketch.
    private func doc(_ transform: Feature) throws -> CADDocument {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 4)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        let region = try #require(sk.regions.first)
        let profile = ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)
        d.features.append(Feature(id: "e1", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [profile], extent: .distance("3 mm")))))
        d.features.append(transform)
        d.features.append(Feature(id: "e2", name: "Extrude2", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: [profile], extent: .distance("3 mm"), operation: .newBody))))
        return d
    }

    private func move(carry: Bool) -> Feature {
        Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: [], sketches: ["sk"], dx: "50 mm", carry: carry)))
    }

    @Test func carriedBodiesFollowTheMove() throws {
        let r = Regenerator.regenerate(try doc(move(carry: true)))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let first = try #require(r.body("e1")?.bounds), second = try #require(r.body("e2")?.bounds)
        #expect(abs(first.min.x - 50) < 1e-6, "the body made before the move follows the sketch: \(first)")
        #expect(abs(second.min.x - 50) < 1e-6, "and the one made after it is where the sketch is")
    }

    @Test func notCarryingLeavesEarlierBodiesWhereTheyWere() throws {
        let r = Regenerator.regenerate(try doc(move(carry: false)))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let first = try #require(r.body("e1")?.bounds), second = try #require(r.body("e2")?.bounds)
        #expect(abs(first.min.x) < 1e-6, "as before: \(first)")
        #expect(abs(second.min.x - 50) < 1e-6)
    }

    @Test func aScaleCarriesToo() throws {
        let scale = Feature(id: "m", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], factor: "2")))
        let r = Regenerator.regenerate(try doc(scale))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let first = try #require(r.body("e1")?.bounds), second = try #require(r.body("e2")?.bounds)
        #expect(abs((first.max.x - first.min.x) - 20) < 1e-6 && abs((second.max.x - second.min.x) - 20) < 1e-6, "\(first) \(second)")
        let kept = Feature(id: "m", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], factor: "2", carry: false)))
        let old = Regenerator.regenerate(try doc(kept))
        #expect(abs(((old.body("e1")?.bounds?.max.x ?? 0) - (old.body("e1")?.bounds?.min.x ?? 0)) - 10) < 1e-6)
    }

    @Test func aCachedRebuildAfterEditingTheTransformMatchesAFullOne() throws {
        let cache = RegenCache()
        _ = Regenerator.regenerate(try doc(move(carry: true)), cache: cache)
        let edited = Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: [], sketches: ["sk"], dx: "80 mm")))
        let r = Regenerator.regenerate(try doc(edited), cache: cache)
        #expect(abs((r.body("e1")?.bounds?.min.x ?? 0) - 80) < 1e-6, "the early body follows the edited move, not a stale snapshot")
        let off = Regenerator.regenerate(try doc(move(carry: false)), cache: cache)
        #expect(abs(off.body("e1")?.bounds?.min.x ?? 99) < 1e-6, "turning carry off is seen by a cached rebuild too")
    }

    @Test func oldFilesKeepTheirMeaningAndTheChoiceIsSaved() throws {
        let old = #"{"bodies":[],"sketches":["sk"],"dx":"5 mm","dy":"0 mm","dz":"0 mm","arrow":"X"}"#
        #expect(try JSONDecoder().decode(MoveFeature.self, from: Data(old.utf8)).carry == false, "a file from before the choice moves the sketch from there on only")
        let m = MoveFeature(bodies: [], sketches: ["sk"], dx: "5 mm", carry: true)
        #expect(try JSONDecoder().decode(MoveFeature.self, from: JSONEncoder().encode(m)).carry == true)
        let oldScale = #"{"sketches":["sk"],"factor":"2"}"#
        #expect(try JSONDecoder().decode(ScaleFeature.self, from: Data(oldScale.utf8)).carry == false)
    }
}

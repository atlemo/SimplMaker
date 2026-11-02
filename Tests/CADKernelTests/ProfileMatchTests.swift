// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Sketch edits that change the curves around a profile don't break what's built from it.
@Suite struct ProfileMatchTests {
    /// A 40 × 20 rectangle extruded 5 mm, its profile picked in the middle.
    private func plate() throws -> (CADDocument, rect: (lines: [EntityID], corners: [EntityID])) {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 40, 20)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let region = try #require(Regenerator.regenerate(d).sketches["sk"]?.regions.first)
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: 20, hintV: 10)],
            extent: .distance("5 mm")))))
        return (d, r)
    }

    private func edit(_ d: inout CADDocument, _ change: (inout Sketch) -> Void) {
        guard case .sketch(var sf) = d.features[0].kind else { return }
        change(&sf.sketch)
        _ = SketchSolver.solve(&sf.sketch, dimensionValues: [:])
        d.features[0].kind = .sketch(sf)
    }

    @Test func roundingACornerKeepsTheExtrude() throws {
        var (d, r) = try plate()
        edit(&d) { _ = $0.filletCorner(r.corners[2], radius: 4, expression: "4 mm") }
        let result = Regenerator.regenerate(d)
        #expect(result.errors.isEmpty, "\(result.errors)")
        let expected = (800 - (16 - .pi * 4)) * 5.0  // one corner rounded off
        #expect(abs(try #require(result.body("e")).volume - expected) < 1e-3)
    }

    @Test func redrawingTheShapeKeepsTheExtrude() throws {
        var (d, r) = try plate()
        edit(&d) { s in
            s.delete(Set(r.lines))  // every curve gone: nothing of the old profile's curves is left
            s.addRectangle(-5, -5, 30, 30)
        }
        let result = Regenerator.regenerate(d)
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(abs(try #require(result.body("e")).volume - 35 * 35 * 5) < 1e-6, "the new shape around the picked point")
    }

    @Test func aMovedShapeIsFoundByItsCurves() throws {
        var (d, r) = try plate()
        edit(&d) { s in
            for p in r.corners { if let i = s.points.firstIndex(where: { $0.id == p }) { s.points[i].x += 100 } }
            _ = s.filletCorner(r.corners[0], radius: 2, expression: "2 mm")  // and not the same curves either
        }
        let result = Regenerator.regenerate(d)
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect((result.body("e")?.bounds?.min.x ?? 0) > 99)
    }

    @Test func somethingUnrelatedStillFails() throws {
        var (d, r) = try plate()
        edit(&d) { s in
            s.delete(Set(r.lines))
            s.addRectangle(100, 100, 120, 120)
        }
        #expect(Regenerator.regenerate(d).errors["e"]?.contains("no longer exists") == true)
    }
}

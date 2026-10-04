// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Moving features in the timeline: allowed unless it puts something before what it's built from.
@Suite struct ReorderTests {
    private func doc() -> CADDocument {
        let sketch = { Feature.Kind.sketch(SketchFeature(plane: .xy, sketch: Sketch())) }
        var d = CADDocument()
        d.features = [
            Feature(id: "s1", name: "Sketch1", sketch()),
            Feature(id: "e1", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "s1", profiles: [], extent: .distance("5 mm")))),
            Feature(id: "s2", name: "Sketch2", sketch()),
            Feature(id: "j", name: "Extrude2", .extrude(ExtrudeFeature(sketch: "s2", profiles: [], extent: .distance("5 mm"),
                                                                       operation: .join, target: "e1"))),
            Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: "e1", edge: "x")], size: "1 mm"))),
            Feature(id: "p", name: "Plane1", .plane(PlaneFeature(base: .xy))),
            Feature(id: "s3", name: "Sketch3", .sketch(SketchFeature(plane: .plane("p"), sketch: Sketch()))),
        ]
        return d
    }

    @Test func whatMayMove() {
        let d = doc()
        #expect(d.reorderProblem("s2", to: 0) == nil, "a sketch on an origin plane can go first")
        #expect(d.reorderProblem("e1", to: 0)?.contains("built from Sketch1") == true)
        #expect(d.reorderProblem("s1", to: 3)?.contains("Sketch1 has to come before it") == true)
        #expect(d.reorderProblem("f", to: 3)?.contains("as Extrude2 leaves it") == true, "the fillet's edges are on the joined body")
        #expect(d.reorderProblem("p", to: 0) == nil)
        #expect(d.reorderProblem("s3", to: 5)?.contains("built from Plane1") == true)
        #expect(d.reorderProblem("j", to: 5)?.contains("Fillet1") == true, "the fillet needs the join before it")
    }

    @Test func referencesAndChangedBodies() {
        let d = doc()
        #expect(d.features[3].references == ["s2", "e1"] && d.features[3].changedBodies == ["e1"])
        #expect(d.features[6].references == ["p"] && d.features[6].changedBodies.isEmpty)
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

@Suite struct AddFeatureTests {
    private func sketch(_ id: String) -> Feature {
        Feature(id: id, name: id, .sketch(SketchFeature(plane: .xy, sketch: Sketch())))
    }

    private func extrude(_ id: String, from sketch: String) -> Feature {
        Feature(id: id, name: id, .extrude(ExtrudeFeature(sketch: sketch, profiles: [], extent: .distance("4 mm"))))
    }

    @Test func aFeatureGoesAtTheEndAndHidesTheSketchesItUses() {
        var doc = CADDocument()
        doc.addFeature(sketch("s"))
        #expect(doc.hidden.isEmpty, "a sketch uses no sketch")
        doc.addFeature(extrude("e", from: "s"))
        #expect(doc.features.map(\.id) == ["s", "e"])
        #expect(doc.hidden == ["s"])
        #expect(doc.rollback == nil)
    }

    @Test func rolledBackAFeatureGoesWhereTheMarkerIs() {
        var doc = CADDocument()
        doc.addFeature(sketch("s"))
        doc.addFeature(extrude("e", from: "s"))
        doc.rollback = 1
        doc.addFeature(sketch("t"))
        #expect(doc.features.map(\.id) == ["s", "t", "e"])
        #expect(doc.rollback == 2, "the marker stays after the new feature, so it is built")
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Testing

/// A new feature must land inside the timeline marker, also after deleting the features past it.
@Suite struct MarkerAtEndTests {
    private func feature(_ name: String) -> Feature {
        Feature(name: name, .hole(HoleFeature(face: FaceRef(body: "b", face: "f"), u: "0 mm", v: "0 mm")))
    }

    @Test func aFeatureAddedAfterDeletingTheOnesPastTheMarkerIsBuilt() {
        var doc = CADDocument(features: [feature("A"), feature("B"), feature("C")])
        doc.rollback = 2                                    // C is rolled back
        let c = doc.features[2].id
        doc.features.removeAll { $0.id == c }               // deleting it leaves the marker at the end
        doc.rollback = doc.rollback == doc.features.count ? nil : doc.rollback  // (deleteFeature does this)
        let new = feature("D")
        doc.insertAtMarker(new)
        #expect(doc.activeFeatures.last?.id == new.id)
    }

    @Test func aStaleMarkerAtTheEndDoesNotHideTheNewFeature() {
        var doc = CADDocument(features: [feature("A"), feature("B")])
        doc.rollback = 2
        let new = feature("C")
        doc.insertAtMarker(new)
        #expect(doc.activeFeatures.last?.id == new.id)
    }

    @Test func aRolledBackMarkerInsertsBeforeTheRestAndStaysAfterIt() {
        var doc = CADDocument(features: [feature("A"), feature("B")])
        doc.rollback = 1
        let new = feature("C")
        doc.insertAtMarker(new)
        #expect(doc.features.map(\.name) == ["A", "C", "B"] && doc.rollback == 2)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The timeline marker: rolling back, adding at the marker, and deleting before it.
@Suite @MainActor struct TimelineTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func rollingBackRebuildsFromTheFeaturesBeforeTheMarker() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        #expect(model.markerPosition == 6 && model.document.rollback == nil)
        model.selectedFeature = "topedge"
        model.setMarker(2)  // after Base Sketch and Plate
        #expect(model.markerPosition == 2 && model.document.rollback == 2)
        #expect(model.selectedFeature == nil, "a rolled-back feature can't stay selected")
        try await settle(model)
        #expect(model.result?.body("plate")?.hasFace("pin.side.C1") == false, "the pin hole comes later")

        // A new feature goes in at the marker, and the marker moves past it.
        model.clickRay = (SIMD3(100, 100, 50), SIMD3(0, 0, -1))
        model.run(.box)
        model.click(OriginPlane.xy.pickID, additive: false)
        #expect(model.document.features[2].typeName == "Box" && model.markerPosition == 3)
        model.finishFeatureEdit()

        model.deleteFeature("base")
        #expect(model.markerPosition == 2, "deleting before the marker keeps it after the same features")
        model.setMarker(99)
        #expect(model.document.rollback == nil && model.markerPosition == model.document.features.count)
        try await settle(model)
    }

    @Test func cancelPutsTheMarkerBack() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        model.setMarker(3)
        model.clickRay = (SIMD3(100, 100, 50), SIMD3(0, 0, -1))
        model.run(.sphere)
        model.click(OriginPlane.xy.pickID, additive: false)
        #expect(model.markerPosition == 4)
        model.cancelNewFeature()
        #expect(model.markerPosition == 3 && model.document.features.count == 6)
        try await settle(model)
    }

    @Test func theTimelineLightsTheFeaturesBehindWhatIsSelected() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        #expect(model.timelineMarks.isEmpty)

        model.selectBody("plate")  // a body clicked in the browser: its feature
        #expect(model.selectedFeature == nil && model.timelineMarks == ["plate"])

        model.selectedFeature = "base"  // a feature picked directly wins
        #expect(model.timelineMarks == ["base"])

        // A face or edge lights the feature that made it: here the top edge's fillet or chamfer.
        model.selectedFeature = nil
        let mesh = try #require(model.meshes.first?.mesh)
        let rounded = try #require(mesh.edgeNames.firstIndex { $0.hasPrefix("topedge.") || $0.contains("|topedge.") })
        model.selection = [PickID(body: 0, edge: rounded)]
        #expect(model.timelineMarks == ["topedge"])
        let face = try #require(mesh.faceNames.firstIndex { $0.hasPrefix("topedge.") })
        model.selection = [PickID(body: 0, face: face)]
        #expect(model.timelineMarks == ["topedge"])
        try await settle(model)
    }
}

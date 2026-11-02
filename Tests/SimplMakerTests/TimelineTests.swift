// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

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

    @Test func aNewFeatureThatDoesNotBuildIsNotKept() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        let count = model.document.features.count
        let tooBig = Feature(id: "huge", name: "Huge Fillet", .fillet(EdgeFeature(
            edges: [EdgeRef(body: "plate", edge: "plate.side.L0|plate.side.L1")], size: "500 mm")))
        model.add(tooBig)
        try await settle(model)
        for _ in 0..<1000 where model.document.features.count != count { try await Task.sleep(for: .milliseconds(5)) }
        try await settle(model)
        #expect(model.document.features.count == count && model.document.index(of: "huge") == nil)
        #expect(model.newFeature == nil && model.alert != nil)
        #expect(model.result?.errors.isEmpty == true, "the model is as it was")
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

    @Test func aNewSketchGoesInAtTheMarker() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        model.setMarker(2)  // after Base Sketch and Plate
        try await settle(model)
        model.beginSketch(on: .xy)
        #expect(model.document.features[2].typeName == "Sketch", "in at the marker, not at the end")
        #expect(model.markerPosition == 3 && model.document.features.count == 7)
        model.finishSketch()
        try await settle(model)
        #expect(model.result?.sketches[model.document.features[2].id] != nil, "the sketch is inside the model that is shown")
    }

    @Test func editingASketchTheMarkerRolledBackBringsItBack() async throws {
        var doc = CADDocument.demo()
        // A sketch on the plate's end face, at the end of the timeline.
        doc.features.append(Feature(id: "onface", name: "Face Sketch", .sketch(SketchFeature(
            plane: .face(FaceRef(body: "plate", face: "plate.end")), sketch: Sketch()))))
        let model = DocumentModel(document: doc)
        try await settle(model)
        model.setMarker(1)  // before the plate: the sketch's face does not exist
        try await settle(model)
        #expect(model.result?.sketches["onface"] == nil)

        model.editSketch("onface")
        for _ in 0..<1000 where model.sketchSession == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.alert == nil, "no 'face or plane is missing'")
        #expect(model.sketchSession?.featureID == "onface")
        #expect(model.markerPosition == model.document.index(of: "onface")! + 1, "the marker moved to just after the sketch")
        model.finishSketch()
        try await settle(model)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The right-click menu, double-click to edit, and the options panel's operations and Cancel.
@Suite @MainActor struct ContextActionTests {
    private func loaded(_ doc: CADDocument) async throws -> DocumentModel {
        let model = DocumentModel(document: doc)
        try await settle(model)
        return model
    }

    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func titles(_ items: [ContextItem]) -> [String] { items.compactMap(\.title) }

    private func run(_ items: [ContextItem], _ title: String) {
        for item in items {
            if case .action(let t, _, _, let action) = item, t == title { action(); return }
        }
        Issue.record("no menu item \(title) in \(titles(items))")
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        PickID(body: 0, face: try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: name)))
    }

    @Test func menusFollowWhatIsUnderTheCursor() async throws {
        let model = try await loaded(.demo())
        #expect(titles(model.contextItems(for: nil)).starts(with: ["New Sketch…", "Add Shape", "Fit All"]))
        let top = try face(model, "plate.end")
        #expect(titles(model.contextItems(for: top)) == ["Sketch on Face", "Extrude Face", "Insert Image…", "Hole Here", "Thread…", "Fillet Face Edges", "Chamfer Face Edges", "Move Body", "Rotate Body", "Combine with Other Bodies…", "Edit Plate", "Appearance…", "Hide Body1"])
        #expect(titles(model.contextItems(for: PickID(body: 0, edge: 0))).starts(with: ["Fillet", "Chamfer"]))
        model.selectedFeature = "base"
        let s = try #require(model.sketchSlots.firstIndex(of: "base")) + 1
        #expect(titles(model.contextItems(for: PickID(region: 0, slot: s))) == ["Extrude", "Revolve", "Sweep", "Loft", "Edit Base Sketch", "Move Base Sketch", "Scale Base Sketch", "Hide Base Sketch"])
        model.run(.box)
        #expect(titles(model.contextItems(for: top)) == ["Cancel Box"])
        model.cancelTool()
        try await settle(model)
    }

    @Test func menuActionsDoWhatTheySay() async throws {
        let model = try await loaded(.demo())
        let top = try face(model, "plate.end")
        run(model.contextItems(for: top, ray: (SIMD3(30, 20, 100), SIMD3(0, 0, -1))), "Hole Here")
        guard case .hole(let h)? = model.document.features.last?.kind else { Issue.record("expected a hole"); return }
        #expect(h.face == FaceRef(body: "plate", face: "plate.end"))
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")

        run(model.contextItems(for: try face(model, "plate.end")), "Sketch on Face")
        #expect(model.sketchSession != nil)
        #expect(titles(model.contextItems(for: nil)).first == "Finish Sketch")
        run(model.contextItems(for: nil), "Finish Sketch")
        #expect(model.sketchSession == nil)
        try await settle(model)
    }

    @Test func doubleClickEditsTheFeatureThatMadeAFace() async throws {
        let model = try await loaded(.demo())
        let fillet = try #require(model.meshes.first?.mesh.faceNames.firstIndex { $0.hasPrefix("corners.fillet") })
        model.doubleClick(PickID(body: 0, face: fillet))
        #expect(model.selectedFeature == "corners" && model.dragHandle?.label == "Radius")
        model.doubleClick(nil)  // nothing under the cursor: no change
        #expect(model.selectedFeature == "corners")
        model.editFeature("pinsk")
        #expect(model.sketchSession?.featureID == "pinsk")
        model.finishSketch()
        try await settle(model)
    }

    @Test func cancelTakesANewFeatureOutAndOKKeepsIt() async throws {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(1))
        let model = try await loaded(doc)
        let region = PickID(region: 0, slot: 1)
        model.selection = [region]
        model.run(.extrude)
        let id = try #require(model.newFeature)
        #expect(model.isHidden("base"))
        try await settle(model)
        #expect(model.operation(of: id) == .newBody)
        model.setOperation(.join, of: id)
        #expect(model.operation(of: id) == .join)
        #expect(model.isFlipped(id) == false)
        model.toggleFlip(id)
        #expect(model.isFlipped(id) == true)
        model.cancelNewFeature()
        #expect(model.document.features.count == 1 && !model.isHidden("base"), "gone, and its sketch shows again")
        #expect(model.selectedFeature == nil && model.newFeature == nil)
        try await settle(model)

        model.selection = [region]
        model.run(.extrude)
        #expect(model.newFeature != nil)
        model.finishFeatureEdit()
        #expect(model.newFeature == nil && model.document.features.count == 2 && model.dragHandle == nil)
        try await settle(model)
    }
}

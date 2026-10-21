// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Several bodies selected whole from the browser, to move, scale or colour together.
@Suite @MainActor struct MultiSelectBodiesTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func threeBoxes() -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy))),
            Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "40 mm"))),
            Feature(id: "c", name: "Box3", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "80 mm"))),
        ]
        return d
    }

    @Test func bodiesSelectTogether() async throws {
        let model = DocumentModel(document: threeBoxes())
        try await settle(model)
        model.selectBodies(["a", "c"], replacing: [])
        #expect(model.selectedBodies == ["a", "c"])
        #expect(model.selectedBody == nil, "two bodies are not one")
        #expect(model.appearanceTargets == ["a", "c"])

        model.selectBodies(["c"], replacing: ["a", "c"])  // ⌘-click took "a" out
        #expect(model.selectedBodies == ["c"] && model.selectedBody == "c")
    }

    @Test func aLockedBodyStaysOutOfTheSelection() async throws {
        let model = DocumentModel(document: threeBoxes())
        try await settle(model)
        model.setLocked(["b"], true)
        model.selectBodies(["a", "b", "c"], replacing: [])
        #expect(model.selectedBodies == ["a", "c"])
    }

    @Test func facesAndBodiesDoNotCount() async throws {
        let model = DocumentModel(document: threeBoxes())
        try await settle(model)
        model.selectBody("a")
        model.click(PickID(body: 1, face: 0), additive: true)
        #expect(model.selectedBodies.isEmpty, "a face among them: not a body selection")
    }

    @Test func aWaitingToolGetsEachBodyAsAClick() async throws {
        let model = DocumentModel(document: threeBoxes())
        try await settle(model)
        model.run(.mirror)
        #expect(model.pendingTool == .mirror)
        model.selectBodies(["a"], replacing: [])
        model.selectBodies(["a", "c"], replacing: ["a"])
        #expect(Set(model.pickedBodies) == ["a", "c"])
        model.selectBodies(["c"], replacing: ["a", "c"])
        #expect(model.pickedBodies == ["c"], "taking one out is a click on it again")
    }

    @Test func theMoveToolTakesBodiesSelectedBeforehand() async throws {
        let model = DocumentModel(document: threeBoxes())
        try await settle(model)
        model.selectBodies(["a", "c"], replacing: [])
        model.run(.move)
        guard case .move(let m)? = model.document.features.last?.kind else { Issue.record("no move made"); return }
        #expect(Set(m.bodies) == ["a", "c"])
    }

    @Test func moveAndColourTakeAllSelectedBodies() async throws {
        let model = DocumentModel(document: threeBoxes())
        try await settle(model)
        model.selectBodies(["a", "b"], replacing: [])
        model.move(bodies: model.selectedBodies)
        guard case .move(let m)? = model.document.features.last?.kind else { Issue.record("no move made"); return }
        #expect(m.bodies == ["a", "b"])

        model.openAppearance(for: ["a", "b"])
        #expect(model.showAppearance && model.appearanceTargets == ["a", "b"])
    }
}

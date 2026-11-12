// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Feedback: "I select an edge, then Chamfer, and the Inspector stays empty."
@Suite @MainActor struct ChamferInspectorTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func twoBoxes(hidden: Set<FeatureID> = []) async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
            Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "10"))),
        ]
        d.hidden = hidden
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    @Test func anEdgeThenChamferShowsTheChamfer() async throws {
        let model = try await twoBoxes()
        let i = try #require(model.meshes.firstIndex { $0.id == "b" })
        model.click(PickID(body: i, edge: 0), additive: false)
        #expect(model.selectedEdgeCount == 1)
        model.run(.chamfer)
        try await settle(model)
        #expect(model.selectedFeature != nil, "the chamfer is selected so the Inspector shows it; pending: \(String(describing: model.pendingTool)), alert: \(String(describing: model.alert?.message))")
        if let id = model.selectedFeature, case .chamfer? = model.document.features.first(where: { $0.id == id })?.kind {} else { Issue.record("no chamfer feature") }
    }

    @Test func anEdgeOfALaterBodyWhileAnEarlierOneIsHidden() async throws {
        let model = try await twoBoxes(hidden: ["a"])
        let i = try #require(model.meshes.firstIndex { $0.id == "b" })
        model.click(PickID(body: i, edge: 3), additive: false)
        model.run(.chamfer)
        try await settle(model)
        #expect(model.selectedFeature != nil)
    }

    @Test func anEdgeThenChamferWithTheTimelineRolledBack() async throws {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
            Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "10"))),
            Feature(id: "c", name: "Box3", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "5", length: "5", height: "10"))),
        ]
        d.rollback = 2
        let model = DocumentModel(document: d)
        try await settle(model)
        let i = try #require(model.meshes.firstIndex { $0.id == "b" })
        model.click(PickID(body: i, edge: 0), additive: false)
        model.run(.chamfer)
        try await settle(model)
        #expect(model.selectedFeature != nil, "pending: \(String(describing: model.pendingTool)), alert: \(String(describing: model.alert?.message))")
        let kinds = model.document.features.map(\.name)
        #expect(kinds.contains { $0.hasPrefix("Chamfer") }, "\(kinds)")
    }

    @Test func aCombineWithOneBodyPickedWaitsAndSaysSo() async throws {
        let model = try await twoBoxes()
        model.click(PickID(wholeBody: 0), additive: false)
        model.run(.combine)
        #expect(model.pendingTool == .combine)
        #expect(model.selectedFeature == nil, "while it waits for the second body the Inspector has no feature")
    }

    @Test func aWaitingToolHasAPromptForTheInspector() async throws {
        let model = try await twoBoxes()
        model.click(PickID(wholeBody: 0), additive: false)
        model.run(.combine)
        #expect(model.pendingTool == .combine)
        #expect(model.toolPrompt?.isEmpty == false, "the Inspector shows this while no feature exists yet")
    }

    @Test func picksThatNameNoEdgeAreSaidSoNotSwallowed() async throws {
        let model = try await twoBoxes()
        model.selection = [PickID(body: 0, edge: 9999)]
        model.run(.chamfer)
        #expect(model.selectedFeature == nil)
        #expect(model.pendingTool == .chamfer, "the tool keeps waiting")
        #expect(model.alert?.title == "Pick the edges again")
        #expect(model.document.features.count == 2, "nothing was made")
    }
}

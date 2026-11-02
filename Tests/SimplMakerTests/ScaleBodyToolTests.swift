// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Scale tool on bodies: picking them, the drag handle, and the menus that start it.
@Suite @MainActor struct ScaleBodyToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 20 × 10 × 5 box "b", with a 10 mm cube "c" beside it when asked.
    private func loaded(second: Bool = false) async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "10 mm", height: "5 mm")))]
        if second {
            d.features.append(Feature(id: "c", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10 mm", length: "10 mm", height: "10 mm"))))
            d.features.append(Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: ["c"], dx: "40 mm"))))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        let index = try #require(model.meshes.firstIndex { $0.mesh.faceNames.contains(name) })
        return PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: name)))
    }

    private func scale(_ model: DocumentModel) -> ScaleFeature? {
        guard case .scale(let s)? = model.document.features.last?.kind else { return nil }
        return s
    }

    @Test func clickingABodyScalesItAndShowsTheHandle() async throws {
        let model = try await loaded()
        model.run(.scale)
        #expect(model.pendingTool == .scale && model.toolPrompt == "Click the bodies or sketches to scale")
        model.toolClick(.scale, try face(model, "b.top"))
        let s = try #require(scale(model))
        #expect(s.bodies == ["b"] && s.sketches.isEmpty && s.factor == "1")
        #expect(model.pendingTool == nil)
        try await settle(model)
        let h = try #require(model.dragHandle)
        #expect(h.label == "Scale" && h.unit == .none)
        #expect(abs(h.value - 10) < 1e-4, "half the longest side times the factor: \(h.value)")
        #expect(model.commitHandle("2"))
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(abs((model.result?.body("b")?.volume ?? 0) - 8000) < 1e-6)
    }

    @Test func aFaceAlreadySelectedScalesAtOnce() async throws {
        let model = try await loaded()
        model.selection = [try face(model, "b.top")]
        model.run(.scale)
        #expect(scale(model)?.bodies == ["b"] && model.pendingTool == nil)
    }

    @Test func aBodyChosenInTheBrowserScalesToo() async throws {
        let model = try await loaded()
        let index = try #require(model.meshes.firstIndex { $0.id == "b" })
        model.selection = [PickID(wholeBody: index)]
        model.run(.scale)
        #expect(scale(model)?.bodies == ["b"])
    }

    @Test func scalingSeveralBodiesMakesOneFeature() async throws {
        let model = try await loaded(second: true)
        model.selection = [try face(model, "b.top"), try face(model, "c.top")]
        model.run(.scale)
        #expect(scale(model)?.bodies == ["b", "c"])
        try await settle(model)
        #expect(model.commitHandle("2"))
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(abs((model.result?.body("b")?.volume ?? 0) - 8000) < 1e-6 && abs((model.result?.body("c")?.volume ?? 0) - 8000) < 1e-6)
    }

    @Test func theModifyToolbarOffersScale() {
        #expect(DesignTool.modifiers.contains(.scale))
        #expect(DesignTool.scale.picksBodies && DesignTool.scale.accepts(.face) && DesignTool.scale.accepts(.region))
    }

    @Test func theBrowserMenuActionScalesAndUndoes() async throws {
        let model = try await loaded()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        try await settle(model)
        undo.beginUndoGrouping()
        model.scale(bodies: ["b"])
        undo.endUndoGrouping()
        #expect(scale(model)?.bodies == ["b"] && model.document.features.last?.name == "Scale1")
        undo.undo()
        #expect(model.document.features.count == 1)
    }

    @Test func aFaceContextMenuHasScaleBody() async throws {
        let model = try await loaded()
        let items = model.contextItems(for: try face(model, "b.top"))
        let titles = items.compactMap(\.title)
        #expect(titles.contains("Scale Body"), "\(titles)")
    }
}

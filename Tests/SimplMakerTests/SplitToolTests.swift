// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Split Body tool: pick the bodies, then the plane, profile or face that divides them.
@Suite @MainActor struct SplitToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 20 mm cube "a" about the origin, and (with `slab`) a thin slab "s" across it, 10 wide in x.
    private func loaded(slab: Bool = false) async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm")))]
        if slab {
            d.features.append(Feature(id: "s", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10 mm", length: "40 mm", height: "5 mm"))))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        let index = try #require(model.meshes.firstIndex { $0.mesh.faceNames.contains(name) })
        return PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: name)))
    }

    private func split(_ model: DocumentModel) -> SplitFeature? {
        guard case .split(let s)? = model.document.features.last?.kind else { return nil }
        return s
    }

    @Test func aBodyThenAPlaneSplitsIt() async throws {
        let model = try await loaded()
        model.run(.split)
        #expect(model.pendingTool == .split)
        model.toolClick(.split, try face(model, "a.top"))
        #expect(split(model) == nil, "a face only picks the body")
        #expect(model.toolPrompt?.contains("1 picked") == true, "\(model.toolPrompt ?? "")")
        model.toolClick(.split, OriginPlane.yz.pickID)
        let s = try #require(split(model))
        #expect(s.bodies == ["a"] && s.tool == .plane(.yz))
        #expect(model.pendingTool == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.result?.bodies.count == 2)
        #expect(model.result?.bodies.allSatisfy { abs($0.body.volume - 4000) < 1e-6 } == true)
    }

    @Test func aPlaneBeforeAnyBodyIsPickedNeedsOneInAModelWithMany() async throws {
        let model = try await loaded(slab: true)
        model.run(.split)
        model.toolClick(.split, OriginPlane.yz.pickID)
        #expect(split(model) == nil && model.pendingTool == .split, "two bodies: it has to be told which")
        model.toolClick(.split, try face(model, "a.top"))
        model.toolClick(.split, OriginPlane.yz.pickID)
        #expect(split(model)?.bodies == ["a"])
    }

    @Test func withOneBodyInTheModelAPlaneIsEnough() async throws {
        let model = try await loaded()
        model.run(.split)
        model.toolClick(.split, OriginPlane.xz.pickID)
        #expect(split(model)?.bodies == ["a"] && split(model)?.tool == .plane(.xz))
    }

    @Test func returnMovesOnToAFaceAndTheNextFaceClickSplits() async throws {
        let model = try await loaded(slab: true)
        model.run(.split)
        model.toolClick(.split, try face(model, "a.top"))
        model.confirmTool()
        #expect(model.pendingTool == .split && model.splitBodies == ["a"])
        #expect(model.toolPrompt == "Click the face, plane or profile to split the body with", "\(model.toolPrompt ?? "")")
        #expect(model.selection.allSatisfy(\.isWholeBody) && model.selection.count == 1, "the chosen body stays lit")
        // The slab's right face (x = 5) is the tool, even though the cube's own top face is lit already.
        model.toolClick(.split, try face(model, "s.right"))
        let s = try #require(split(model))
        #expect(s.bodies == ["a"] && s.tool == .face(FaceRef(body: "s", face: "s.right")))
        #expect(model.pendingTool == nil && model.splitBodies == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let volumes = (model.result?.bodies ?? []).filter { $0.id != "s" }.map { $0.body.volume }.sorted()
        #expect(volumes.count == 2 && abs(volumes[0] - 2000) < 1e-6 && abs(volumes[1] - 6000) < 1e-6, "\(volumes)")
    }

    @Test func pressingTheToolAgainMovesOnThenCancels() async throws {
        let model = try await loaded(slab: true)
        model.run(.split)
        model.toolClick(.split, try face(model, "a.top"))
        model.run(.split)
        #expect(model.pendingTool == .split && model.splitBodies == ["a"], "the first press moves on to the tool")
        model.run(.split)
        #expect(model.pendingTool == nil && model.splitBodies == nil, "the second cancels")
    }

    @Test func escapeLeavesNoStageBehind() async throws {
        let model = try await loaded(slab: true)
        model.run(.split)
        model.toolClick(.split, try face(model, "a.top"))
        model.confirmTool()
        model.cancelTool()
        #expect(model.splitBodies == nil)
        model.selection = []
        model.run(.split)
        #expect(model.toolPrompt?.hasPrefix("Click the bodies to split") == true, "\(model.toolPrompt ?? "")")
    }

    @Test func aFaceSelectedBeforehandStartsTheToolWithThatBody() async throws {
        let model = try await loaded(slab: true)
        model.selection = [try face(model, "a.top")]
        model.run(.split)
        #expect(model.pendingTool == .split)
        model.toolClick(.split, OriginPlane.yz.pickID)
        #expect(split(model)?.bodies == ["a"])
    }

    @Test func theInspectorCanAddMoreBodies() async throws {
        let model = try await loaded(slab: true)
        model.run(.split)
        model.toolClick(.split, try face(model, "a.top"))
        model.toolClick(.split, OriginPlane.yz.pickID)
        let id = try #require(model.document.features.last?.id)
        model.selection = [try face(model, "s.top")]
        #expect(model.pickedBodies == ["s"])
        // The feature is edited the way the inspector button does it.
        model.mutate("Add Bodies") { doc in
            guard case .split(var f)? = doc.features.last?.kind else { return }
            f.bodies += ["s"]
            doc.features[doc.features.count - 1].kind = .split(f)
        }
        try await settle(model)
        #expect(split(model)?.bodies == ["a", "s"])
        #expect(model.document.features.last?.id == id)
        #expect(model.result?.bodies.count == 4, "\(model.result?.bodies.map(\.id) ?? [])")
    }

    @Test func theToolHasItsKeyAndIcon() {
        #expect(DesignTool.split.symbol == "split-body" && IconGlyphs.table["split-body"] != nil)
        #expect(!SVGGlyph.parse(IconGlyphs.table["split-body"] ?? "").isEmpty)
        #expect(DesignTool.modifiers.contains(.split))
        #expect(Shortcuts.label(.tool(.split)) == "⇧S", "\(Shortcuts.label(.tool(.split)) ?? "")")
    }
}

// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Draft tool: pick the faces to lean, and it works out the flat face that stays put; the angle is a dial.
@Suite @MainActor struct DraftToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func loaded(_ feature: Feature? = nil) async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm")))]
        if let feature { d.features.append(feature) }
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        let index = try #require(model.meshes.firstIndex { $0.mesh.faceNames.contains(name) })
        return PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: name)))
    }

    private var draft: (DocumentModel) -> DraftFeature? {
        { model in
            guard case .draft(let d)? = model.document.features.last?.kind else { return nil }
            return d
        }
    }

    @Test func theToolWaitsForFacesAndReturnDraftsThem() async throws {
        let model = try await loaded()
        model.run(.draft)
        #expect(model.pendingTool == .draft)
        #expect(model.toolPrompt == "Click the faces to draft")
        model.toolClick(.draft, try face(model, "b.right"))
        model.toolClick(.draft, try face(model, "b.left"))
        #expect(draft(model) == nil, "it waits for Return, so more faces can be picked")
        #expect(model.toolPrompt?.contains("2 picked") == true, "\(model.toolPrompt ?? "")")
        model.confirmTool()
        try await settle(model)
        let d = try #require(draft(model))
        #expect(Set(d.faces.map(\.face)) == ["b.right", "b.left"] && d.body == "b")
        #expect(d.angle == "5 deg")
        #expect(model.pendingTool == nil)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }

    @Test func aFaceAlreadySelectedIsDraftedAtOnceAboutTheBottomFace() async throws {
        let model = try await loaded()
        model.selection = [try face(model, "b.right")]
        model.run(.draft)
        try await settle(model)
        let d = try #require(draft(model))
        #expect(d.fixed == FaceRef(body: "b", face: "b.bottom"), "the lowest flat face next to it, not the top: \(String(describing: d.fixed))")
        let volume = try #require(model.result?.body("b")).volume
        #expect(volume < 8000 - 1, "leaning in 5° narrows the box: \(volume)")
    }

    @Test func aRoundWallLeansAboutAFaceSquareToItsAxis() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "30 mm", diameter: "20 mm")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.selection = [try face(model, "c.side")]
        model.run(.draft)
        try await settle(model)
        let made = try #require(draft(model))
        #expect(made.fixed == FaceRef(body: "c", face: "c.bottom"))
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let before = Double.pi * 100 * 30
        #expect((model.result?.body("c")?.volume ?? before) < before - 1, "a cone frustum")
        let h = try #require(model.dragHandle, "the dial shows for a round wall too")
        #expect(h.dial != nil && abs(h.base.z) < 1e-6)
    }

    @Test func aBodyWithNoFlatFaceSaysSo() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "s", name: "Sphere1", .primitive(PrimitiveFeature(kind: .sphere, plane: .xy, diameter: "20 mm")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.selection = [PickID(body: 0, face: 0)]
        model.run(.draft)
        #expect(draft(model) == nil)
        #expect(model.alert?.title.contains("flat face") == true, "\(model.alert?.title ?? "no alert")")
    }

    @Test func theDialSitsWhereTheFaceMeetsTheFixedFaceAndLeansIn() async throws {
        let model = try await loaded(Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "b", faces: [FaceRef(body: "b", face: "b.right")], fixed: FaceRef(body: "b", face: "b.bottom"), angle: "5 deg"))))
        model.selectedFeature = "d"
        #expect(model.showsDial && model.selectedIsDraft)
        #expect(model.dragHandles.count == 1)
        let h = try #require(model.dragHandle)
        let dial = try #require(h.dial)
        #expect(h.label == "Angle" && h.unit == .angle && abs(h.value - 5 * .pi / 180) < 1e-9)
        #expect(abs(h.base.z) < 1e-6 && abs(h.base.x - 10) < 1e-6, "on the bottom edge of the right face: \(h.base)")
        #expect(simd_length(h.direction - SIMD3(0, 0, 1)) < 1e-9, "up the face")
        #expect(simd_length(dial.side - SIMD3(-1, 0, 0)) < 1e-9, "towards the inside of the body: \(dial.side)")
        #expect(model.featureWithoutHandle == nil)
    }

    @Test func typingAnAngleLeansTheFaceAndANegativeOneWidensIt() async throws {
        let model = try await loaded(Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "b", faces: [FaceRef(body: "b", face: "b.right")], fixed: FaceRef(body: "b", face: "b.bottom"), angle: "5 deg"))))
        model.selectedFeature = "d"
        let straight = 8000.0
        let five = try #require(model.result?.body("b")).volume
        #expect(five < straight)
        #expect(model.previewHandle("10 deg"))
        try await settle(model)
        #expect(try #require(model.result?.body("b")).volume < five)
        #expect(model.commitHandle("-10 deg"))
        try await settle(model)
        #expect(draft(model)?.angle == "-10 deg")
        #expect(try #require(model.result?.body("b")).volume > straight, "a negative angle widens it")
        #expect(model.handleProblem == nil)
    }

    @Test func theInspectorCanBeGivenAnotherFaceToStayPut() async throws {
        let model = try await loaded(Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "b", faces: [FaceRef(body: "b", face: "b.right")], fixed: FaceRef(body: "b", face: "b.bottom"), angle: "5 deg"))))
        model.selectedFeature = "d"
        model.updateFeature("d", "Change Fixed Face") { f in
            guard case .draft(var d) = f.kind else { return }
            d.fixed = FaceRef(body: "b", face: "b.top")
            f.kind = .draft(d)
        }
        try await settle(model)
        let h = try #require(model.dragHandle)
        #expect(abs(h.base.z - 20) < 1e-6 && h.direction.z < -0.99, "now it pivots at the top and pulls down: \(h.base) \(h.direction)")
    }

    @Test func theToolHasItsIconAndAKey() {
        #expect(DesignTool.modifiers.contains(.draft))
        #expect(IconGlyphs.table[DesignTool.draft.symbol] != nil)
        #expect(SVGGlyph.parse(IconGlyphs.table["draft"] ?? "").count == 2)
        #expect(DesignTool.draft.accepts(.face) && !DesignTool.draft.accepts(.edge))
        #expect(DesignTool.draft.help.contains("Draft"))
        #expect(ShortcutCommand.tool(.draft).defaultChord == KeyChord("d", .shift), "D is Thread's, and no plain letter is free")
        #expect(DesignTool.draft.help.hasPrefix("Draft (⇧D):"))
    }
}

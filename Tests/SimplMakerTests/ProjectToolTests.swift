// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The Project tool: pick the profiles (the letters of a text), pick the face they land on.
@Suite @MainActor struct ProjectToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A round post with the text "Hi" sketched on the YZ plane through its axis.
    private func postModel(extraBody: Bool = false, postX: String = "0 mm") async throws -> DocumentModel {
        var s = Sketch()
        let p = s.addPoint(-8, 25)
        s.constrain(.fix(p, x: -8, y: 25))
        s.texts = [SketchText(id: "T", text: "Hi", position: p, height: "10 mm")]
        var d = CADDocument()
        d.features = [
            Feature(id: "post", name: "Post", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: postX, height: "60 mm", diameter: "40 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .yz, sketch: s))),
        ]
        if extraBody {
            d.features.append(Feature(id: "box", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "100 mm"))))
        }
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func pickLetter(_ model: DocumentModel) throws {
        let slot = try #require(model.sketchSlots.firstIndex(of: "sk")) + 1
        let region = try #require((0..<20).map { PickID(region: $0, slot: slot) }.first { model.profile(of: $0) != nil })
        model.click(region, additive: false)
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        let index = try #require(model.meshes.firstIndex { $0.mesh.faceNames.contains(name) })
        return PickID(body: index, face: try #require(model.meshes[index].mesh.faceNames.firstIndex(of: name)))
    }

    private var project: (DocumentModel) -> ProjectFeature? {
        { model in
            guard case .project(let p)? = model.document.features.last?.kind else { return nil }
            return p
        }
    }

    @Test func theToolAsksForProfilesThenAFace() async throws {
        let model = try await postModel()
        model.run(.project)
        #expect(model.pendingTool == .project)
        #expect(model.toolPrompt?.contains("profiles to project") == true, "\(model.toolPrompt ?? "")")
        try pickLetter(model)
        #expect(project(model) == nil, "waits for the face")
        #expect(model.toolPrompt?.contains("face to project onto") == true, "\(model.toolPrompt ?? "")")
        model.toolClick(.project, try face(model, "post.side"))
        let p = try #require(project(model))
        #expect(p.target == "post" && p.faces == [FaceRef(body: "post", face: "post.side")])
        #expect(p.mode == .emboss && p.sketch == "sk" && !p.profiles.isEmpty)
        #expect(p.flipped, "a sketch through the middle of the body projects into the screen, against its normal")
        #expect(model.pendingTool == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }

    @Test func projectSketchFromTheBrowserPicksEverythingThenWaitsForAFace() async throws {
        let model = try await postModel()
        model.projectSketch("sk")
        #expect(model.pendingTool == .project)
        #expect(!model.selectedProfiles.isEmpty)
        #expect(project(model) == nil, "waits for the face")
        model.toolClick(.project, try face(model, "post.side"))
        let p = try #require(project(model))
        #expect(p.target == "post" && !p.profiles.isEmpty)
    }

    @Test func aFaceSelectedBeforeProjectSketchIsWhereItLands() async throws {
        let model = try await postModel()
        model.selection = [try face(model, "post.side")]
        model.projectSketch("sk")
        let p = try #require(project(model))
        #expect(p.faces == [FaceRef(body: "post", face: "post.side")], "the face picked first is kept")
    }

    @Test func returnProjectsOntoTheOnlyBody() async throws {
        let model = try await postModel()
        model.run(.project)
        try pickLetter(model)
        model.confirmTool()
        let p = try #require(project(model))
        #expect(p.target == "post" && p.faces.isEmpty)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }

    @Test func withSeveralBodiesReturnNeedsAFace() async throws {
        let model = try await postModel(extraBody: true)
        model.run(.project)
        try pickLetter(model)
        model.confirmTool()
        #expect(project(model) == nil && model.pendingTool == .project, "which body? it still waits")
        #expect(model.alert != nil)
    }

    @Test func aFacePickedFirstWaitsForTheProfiles() async throws {
        let model = try await postModel()
        model.run(.project)
        model.toolClick(.project, try face(model, "post.side"))
        #expect(project(model) == nil)
        try pickLetter(model)
        #expect(project(model)?.faces == [FaceRef(body: "post", face: "post.side")])
    }

    @Test func theDirectionPointsTowardTheBody() async throws {
        // The YZ plane's normal points along +X.
        let through = try await postModel()
        #expect(through.projectsAgainstNormal(sketch: "sk", onto: "post"), "through the middle: into the screen")
        let beyond = try await postModel(postX: "100 mm")
        #expect(!beyond.projectsAgainstNormal(sketch: "sk", onto: "post"), "a body on the normal's side: along it")
        let behind = try await postModel(postX: "-100 mm")
        #expect(behind.projectsAgainstNormal(sketch: "sk", onto: "post"), "a body behind: against it")
    }

    @Test func theHeightHandleSitsOnTheSurface() async throws {
        let model = try await postModel()
        model.run(.project)
        try pickLetter(model)
        model.confirmTool()
        try await settle(model)
        let h = try #require(model.dragHandles.first)
        #expect(h.label == "Height" && h.direction.x > 0.9, "out of the +x side of the post: \(h.direction)")
        #expect(h.base.x > 15)
        let id = try #require(model.document.features.last?.id)
        model.updateFeature(id, "Deboss") { f in
            if case .project(var p) = f.kind { p.mode = .deboss; f.kind = .project(p) }
        }
        try await settle(model)
        // A deboss keeps the same handle on the surface: its size is negative, so it sinks in, and typing a negative one keeps it a deboss.
        let d = try #require(model.dragHandles.first)
        #expect(d.label == "Height" && d.direction.x > 0.9 && d.value < 0, "into the surface: \(d.value)")
        #expect(model.commitHandle("-2", slot: 0))
        try await settle(model)
        #expect(project(model)?.height == "2 mm" && project(model)?.mode == .deboss)
        #expect(model.commitHandle("3", slot: 0))
        try await settle(model)
        #expect(project(model)?.height == "3 mm" && project(model)?.mode == .emboss)
    }

    @Test func theProfilesCanBePickedAgain() async throws {
        let model = try await postModel()
        model.run(.project)
        try pickLetter(model)
        model.confirmTool()
        try await settle(model)
        let id = try #require(model.document.features.last?.id)
        model.reselectProfiles(id)
        #expect(model.pendingTool == .project && model.reselecting == id)
        #expect(!model.selection.isEmpty, "the profiles it uses are selected")
    }

    @Test func theSketchIsHiddenOnceUsed() async throws {
        let model = try await postModel()
        model.run(.project)
        try pickLetter(model)
        model.confirmTool()
        let feature = try #require(model.document.features.last)
        #expect(feature.sketchesUsed == ["sk"])
    }
}

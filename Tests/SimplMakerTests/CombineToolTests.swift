// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Combine tool, and moving a whole sketch.
@Suite @MainActor struct CombineToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func combineCutsTheSecondBodyOutOfTheFirst() async throws {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
            Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "20"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        #expect(model.result?.bodies.count == 2)
        model.run(.combine)
        #expect(model.pendingTool == .combine && model.toolPrompt == "Click the body to cut from, join to or intersect with")
        model.toolClick(.combine, PickID(body: 0, face: 0))
        model.toolClick(.combine, PickID(body: 1, face: 0))
        #expect(model.pendingTool == .combine, "waits for more tools until Return")
        model.confirmTool()
        guard case .combine(let c)? = model.document.features.last?.kind else { Issue.record("expected a combine"); return }
        #expect(c.target == "a" && c.tools == ["b"] && c.operation == .cut)
        try await settle(model)
        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let volume = try #require(r.body("a")).volume
        #expect(r.bodies.map(\.id) == ["a"] && abs(volume - (4000 - 1000)) < 1e-6, "\(volume)")
    }

    @Test func aSketchMovesWithAHandle() async throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 5)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.move(sketches: ["sk"])
        guard case .move(let m)? = model.document.features.last?.kind else { Issue.record("expected a move"); return }
        #expect(m.sketches == ["sk"] && m.bodies.isEmpty)
        try await settle(model)
        #expect(model.dragHandle?.label == "Move X")
        #expect(model.commitHandle("15"))
        try await settle(model)
        let frame = try #require(model.result?.sketches["sk"]?.frame)
        #expect(abs(frame.origin.x - 15) < 1e-9)
    }
}

/// Fillet and Chamfer take a face, for every edge around it.
@Suite @MainActor struct FaceFilletToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aSelectedFaceIsFilletedAllRound() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        let m = try #require(model.meshes.first)
        let top = try #require(m.mesh.faceNames.firstIndex(of: "b.top"))
        model.click(PickID(body: 0, face: top), additive: false)
        model.run(.fillet)
        guard case .fillet(let f)? = model.document.features.last?.kind else { Issue.record("expected a fillet"); return }
        #expect(f.faces == [FaceRef(body: "b", face: "b.top")] && f.edges.isEmpty)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.dragHandle?.label == "Radius", "the handle sits on one of the face's edges")
    }
}

/// Double-click selects connected geometry: an edge loop on a body, a chain of curves in a sketch.
@Suite @MainActor struct DoubleClickSelectTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func anEdgeLoopAroundTheFaceYouSee() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        let m = try #require(model.meshes.first)
        let body = try #require(model.result?.body("b"))
        let topEdges = try body.faceEdges("b.top")
        let edge = try #require(m.mesh.edgeNames.firstIndex(of: topEdges[0]))
        model.doubleClick(PickID(body: 0, edge: edge), viewDirection: SIMD3(0.3, 0.2, -1))  // looking down on it
        #expect(Set(model.selection.compactMap { model.name(of: $0) }) == Set(topEdges))
        model.doubleClick(PickID(body: 0, edge: edge), viewDirection: simd_normalize(SIMD3(0.1, 1, -0.05)), additive: true)
        #expect(model.selection.count > 4, "shift adds the side face's loop too")
    }

    @Test func aChainOfCurvesInASketch() throws {
        var s = Sketch()
        let rect = s.addRectangle(0, 0, 40, 20)
        s.addLine(s.addPoint(0, 50), s.addPoint(10, 50))
        let session = SketchSession(featureID: IDs.make(), frame: .xy, sketch: s, parameters: ParameterEvaluator.evaluate([]))
        session.setTool(.select)
        _ = session.handle(SketchMouse(phase: .moved, uv: SIMD2(20, 0.01), pick: nil, tolerance: 0.5))
        session.selectConnected(additive: false)
        #expect(Set(session.selection) == Set(rect.lines))
    }
}

/// A failed extrude (its profile is gone) gets its profiles picked again from the timeline.
@Suite @MainActor struct ReselectProfilesTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func doubleClickAFailedExtrudeToPickAgain() async throws {
        var s = Sketch()
        s.addRectangle(0, 0, 40, 20)
        var d = CADDocument()
        d.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: ["gone"])], extent: .distance("5 mm")))),
        ]
        d.hidden = ["sk"]
        let model = DocumentModel(document: d)
        try await settle(model)
        #expect(model.result?.errors["e"]?.contains("double-click it in the timeline") == true)

        model.editFeature("e")  // what a double-click in the timeline does
        #expect(model.reselecting == "e" && model.pendingTool == .extrude && model.selection.isEmpty)
        #expect(model.isSketchShown("sk"), "its sketch shows while picking, though it's hidden")
        #expect(model.toolPrompt?.hasPrefix("Click the profiles for Extrude1") == true)

        model.toolClick(.extrude, PickID(region: 0, slot: 1))
        #expect(model.pendingTool == .extrude, "waits for Return, so more profiles can be picked")
        model.confirmTool()
        #expect(model.reselecting == nil && model.pendingTool == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(abs((model.result?.body("e")?.volume ?? 0) - 4000) < 1e-6)
        #expect(!model.isSketchShown("sk") || model.selectedFeature == "sk")

        // A working one can be re-picked too; its profile starts selected, and Esc changes nothing.
        let before = model.document
        model.reselectProfiles("e")
        #expect(model.selection.count == 1)
        model.cancelTool()
        #expect(model.reselecting == nil && model.document == before)
    }
}

/// The Plane, Mirror, Pattern and Shell tools, driven the way the viewport does.
@Suite @MainActor struct ConstructToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func boxModel() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "20 mm", v: "0 mm",
                                                                                width: "10", length: "10", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    private func face(_ model: DocumentModel, _ name: String) throws -> PickID {
        let m = try #require(model.meshes.first)
        return PickID(body: 0, face: try #require(m.mesh.faceNames.firstIndex(of: name)))
    }

    @Test func aPlaneOffsetFromXYToSketchOn() async throws {
        let model = try await boxModel()
        model.run(.plane)
        #expect(model.pendingTool == .plane && model.showsOriginPlanes)
        model.toolClick(.plane, OriginPlane.xy.pickID)
        guard case .plane(let p)? = model.document.features.last?.kind, let id = model.document.features.last?.id else {
            Issue.record("expected a plane"); return
        }
        #expect(p.base == .xy)
        try await settle(model)
        #expect(model.dragHandle?.label == "Offset")
        #expect(model.commitHandle("25"))
        try await settle(model)
        #expect(abs((model.result?.planes[id]?.origin.z ?? 0) - 25) < 1e-9)

        // It shows and picks as plane 3 (after XY, XZ, YZ): a click selects it, and it takes sketches.
        model.finishFeatureEdit()
        let pick = PickID(plane: 3)
        #expect(model.constructionPlane(of: pick) == id && model.name(of: pick) == "Plane1")
        model.click(pick, additive: false)
        #expect(model.selectedFeature == id)
        model.startSketch()  // with the plane selected, the Sketch button sketches on it
        guard case .sketch(let sf)? = model.document.features.last?.kind else { Issue.record("expected a sketch"); return }
        #expect(sf.plane == .plane(id) && abs((model.sketchSession?.frame.origin.z ?? 0) - 25) < 1e-9)
    }

    @Test func mirrorPatternAndShell() async throws {
        let model = try await boxModel()
        let one = try #require(model.result?.body("b")).volume

        model.run(.mirror)
        model.toolClick(.mirror, try face(model, "b.top"))
        #expect(model.pendingTool == .mirror, "waits for the plane")
        model.toolClick(.mirror, OriginPlane.yz.pickID)
        guard case .mirror(let m)? = model.document.features.last?.kind else { Issue.record("expected a mirror"); return }
        #expect(m.bodies == ["b"] && m.plane == .yz)
        try await settle(model)
        #expect(abs((model.result?.body("b")?.volume ?? 0) - 2 * one) < 1e-6)
        model.deleteFeature(try #require(model.document.features.last?.id))
        try await settle(model)

        model.run(.pattern)
        model.toolClick(.pattern, try face(model, "b.top"))
        model.confirmTool()
        guard case .pattern(let p)? = model.document.features.last?.kind else { Issue.record("expected a pattern"); return }
        #expect(p.kind == .linear && p.bodies == ["b"] && p.axis == .x)
        try await settle(model)
        #expect(model.dragHandle?.label == "Spacing" && abs((model.result?.body("b")?.volume ?? 0) - 3 * one) < 1e-6)
        model.deleteFeature(try #require(model.document.features.last?.id))
        try await settle(model)

        model.run(.shell)
        model.toolClick(.shell, try face(model, "b.top"))
        model.confirmTool()
        guard case .shell(let s)? = model.document.features.last?.kind else { Issue.record("expected a shell"); return }
        #expect(s.body == "b" && s.faces == [FaceRef(body: "b", face: "b.top")])
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(abs((model.result?.body("b")?.volume ?? 0) - (1000 - 6 * 6 * 8)) < 1e-3)
    }
}

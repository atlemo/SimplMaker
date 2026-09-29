// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The Design toolbar's tools, the browser's visibility toggles, and the new drag handles.
@Suite @MainActor struct DesignToolTests {
    private func loaded(_ doc: CADDocument) async throws -> DocumentModel {
        let model = DocumentModel(document: doc)
        try await settle(model)
        return model
    }

    /// Waits for background rebuilds: a kernel call still running when the test process exits crashes it.
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func lastFeature(_ model: DocumentModel) throws -> Feature { try #require(model.document.features.last) }

    private func slot(_ model: DocumentModel, _ sketch: FeatureID) throws -> Int {
        try #require(model.sketchSlots.firstIndex(of: sketch)) + 1
    }

    /// A square on XZ, right of the Z axis, with a construction line along the axis.
    private func revolveDoc() -> CADDocument {
        var s = Sketch()
        let r = s.addRectangle(5, 0, 15, 20, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: 5, y: 0)); s.constrain(.fix(r.corners[2], x: 15, y: 20))
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30)
        s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 0, y: 30))
        s.addLine(a, b, id: "AX", construction: true)
        var doc = CADDocument()
        doc.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: s)))]
        return doc
    }

    @Test func extrudeWaitsForAProfileThenHidesItsSketch() async throws {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(1))  // just the base sketch
        let model = try await loaded(doc)
        model.run(.extrude)
        #expect(model.pendingTool == .extrude && model.cursorPrompt == "Select a profile or a flat face to extrude")
        model.click(PickID(body: 0, face: 0), additive: false)  // not a profile: ignored
        #expect(model.pendingTool == .extrude)

        let region = PickID(region: 0, slot: try slot(model, "base"))
        #expect(model.profile(of: region) != nil)
        model.click(region, additive: false)
        #expect(model.pendingTool == nil)
        let f = try lastFeature(model)
        guard case .extrude(let e) = f.kind else { Issue.record("expected an extrude"); return }
        #expect(e.sketch == "base" && e.operation == .newBody)
        #expect(model.isHidden("base"), "a sketch is hidden once a feature uses it")
        #expect(model.selectedFeature == f.id && model.handleFocusRequest == 1)
        try await settle(model)
        #expect(model.dragHandle?.label == "Distance")
    }

    @Test func revolveAsksForAnAxisAndReturnUsesTheDefault() async throws {
        let model = try await loaded(revolveDoc())
        let s = try slot(model, "sk")
        model.run(.revolve)
        let profile = try #require((0..<10).map { PickID(region: $0, slot: s) }.first { model.profile(of: $0) != nil })
        model.click(profile, additive: false)
        #expect(model.pendingTool == .revolve, "still waiting for the axis")
        #expect(model.toolPrompt?.contains("axis") == true)
        model.confirmTool()
        #expect(model.pendingTool == nil)
        guard case .revolve(let r) = try lastFeature(model).kind else { Issue.record("expected a revolve"); return }
        #expect(r.axis == .line("AX"), "the sketch's construction line is the default axis")
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let h = try #require(model.dragHandle)
        #expect(h.label == "Angle" && h.unit == .angle)
        #expect(!model.commitHandle("400"), "more than a full turn")
        #expect(model.commitHandle("90"))
        guard case .revolve(let r2) = try lastFeature(model).kind else { return }
        #expect(r2.angle == "90 deg")
        try await settle(model)
    }

    @Test func primitivesArePlacedWhereThePlaneIsClicked() async throws {
        let model = try await loaded(CADDocument())
        model.run(.box)
        #expect(model.pendingTool == .box && model.showsOriginPlanes)
        #expect(model.dimensionLabels().count == 3, "the origin planes are labelled")
        model.clickRay = (SIMD3(12, 7, 50), SIMD3(0, 0, -1))
        model.click(OriginPlane.xy.pickID, additive: false)
        #expect(model.pendingTool == nil && !model.showsOriginPlanes)
        guard case .primitive(let p) = try lastFeature(model).kind else { Issue.record("expected a box"); return }
        #expect(p.kind == .box && p.plane == .xy && p.u == "12 mm" && p.v == "7 mm" && p.operation == .newBody)
        try await settle(model)
        let body = try #require(model.result?.bodies.first)
        #expect(abs(body.body.volume - 8000) < 1e-6)
        #expect(model.dragHandle?.label == "Height")
        #expect(model.commitHandle("30"))
        try await settle(model)
        #expect(abs((model.result?.bodies.first?.body.volume ?? 0) - 12000) < 1e-6)
    }

    @Test func holeOnTheSelectedFace() async throws {
        // The front side: the middle of the top face is inside the plate's centre hole.
        let model = try await loaded(.demo())
        let side = try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "plate.side.L0"))
        model.click(PickID(body: 0, face: side), additive: false)
        let before = try #require(model.result?.body("plate")).volume
        model.run(.hole)
        #expect(model.pendingTool == nil, "a selected flat face is enough")
        guard case .hole(let h) = try lastFeature(model).kind else { Issue.record("expected a hole"); return }
        #expect(h.face == FaceRef(body: "plate", face: "plate.side.L0"))
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(try #require(model.result?.body("plate")).volume < before)
        #expect(model.dragHandle?.label == "Depth")
    }

    @Test func pipeFollowsAChainOfCurves() async throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30), c = s.addPoint(20, 30), d = s.addPoint(50, 50)
        for (p, x, y) in [(a, 0.0, 0.0), (b, 0, 30), (c, 20, 30), (d, 50, 50)] { s.constrain(.fix(p, x: x, y: y)) }
        s.addLine(a, b, id: "P1")
        s.addLine(b, c, id: "P2")
        s.addLine(d, s.addPoint(60, 50), id: "Other")
        #expect(Set(DocumentModel.chain(from: "P2", in: s)) == ["P1", "P2"])

        var doc = CADDocument()
        doc.features = [Feature(id: "path", name: "Path", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = try await loaded(doc)
        let p2 = try #require(model.result?.sketches["path"]?.solved.curves.firstIndex { $0.id == "P2" })
        model.run(.pipe)
        model.click(PickID(sketchCurve: p2, slot: try slot(model, "path")), additive: false)
        guard case .pipe(let pipe) = try lastFeature(model).kind else { Issue.record("expected a pipe"); return }
        #expect(Set(pipe.path.curves) == ["P1", "P2"])
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.dragHandle?.label == "Diameter")
    }

    @Test func hidingChangesTheViewNotTheModel() async throws {
        let model = try await loaded(.demo())
        let revision = model.sceneRevision
        model.setHidden(["plate"], true)
        #expect(model.isHidden("plate") && model.visibleMeshes.isEmpty && model.meshes.count == 1)
        #expect(!model.isRegenerating && model.sceneRevision == revision + 1, "no rebuild for a visibility change")
        model.setHidden(["plate"], false)
        #expect(model.visibleMeshes.count == 1)

        #expect(model.sketchOverlay().regionIndices.isEmpty == false, "unhidden sketches show their profiles")
        model.setHidden(model.sketches.map(\.id), true)
        #expect(model.sketchOverlay().regionIndices.isEmpty && model.sketchOverlay().inactive.isEmpty)
        model.selectedFeature = "base"
        #expect(model.sketchOverlay().regionIndices.isEmpty && model.sketchOverlay().inactive.isEmpty,
                "a hidden sketch stays hidden when selected")
        try await settle(model)
    }

    @Test func escapeCancelsAWaitingTool() async throws {
        let model = try await loaded(.demo())
        model.run(.fillet)
        #expect(model.pendingTool == .fillet && model.dragHandle == nil)
        model.cancelTool()
        #expect(model.pendingTool == nil)
        model.run(.loft)
        model.run(.loft)  // pressing it again with nothing picked cancels it
        #expect(model.pendingTool == nil)
        try await settle(model)
    }
}

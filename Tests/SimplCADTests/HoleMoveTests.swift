// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import simd
import Testing
@testable import SimplCAD

/// Placing a hole snaps to the middle of the face; the dot at a selected hole's centre moves it.
@Suite @MainActor struct HoleMoveTests {
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

    /// The demo plate before its fillets and chamfer: a 60 × 40 rectangle whose top face has two
    /// holes, the centre one and the pin hole at (12, 20).
    private func plate() -> CADDocument {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(4))
        return doc
    }

    private func top(_ model: DocumentModel) throws -> PickID {
        PickID(body: 0, face: try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "plate.end")))
    }

    /// Clicks the plate's top face straight down at (x, y), where a screen point is 0.1 mm.
    private func placeHole(_ model: DocumentModel, x: Double, y: Double) throws {
        model.clickRay = (SIMD3(x, y, 100), SIMD3(0, 0, -1))
        model.clickRayNext = (SIMD3(x + 0.1, y, 100), SIMD3(0, 0, -1))
        #expect(model.place(.hole, on: try top(model)))
    }

    private func holeCenter(_ model: DocumentModel) throws -> SIMD3<Double> {
        guard case .hole(let h)? = model.document.features.last?.kind else { throw HoleMissing() }
        return try Regenerator.holeFrame(h, try #require(model.result)).origin
    }
    private struct HoleMissing: Error {}

    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_length(a - b) < 1e-6 }

    @Test func snappingPicksTheCentreOrALineThroughIt() {
        let c = SIMD2(30.0, 20.0)
        #expect(DocumentModel.snap(SIMD2(30.5, 19.4), to: c, tolerance: 1) == c)
        #expect(DocumentModel.snap(SIMD2(30.5, 12), to: c, tolerance: 1) == SIMD2(30, 12))
        #expect(DocumentModel.snap(SIMD2(10, 12), to: c, tolerance: 1) == SIMD2(10, 12))
    }

    @Test func aClickNearTheMiddleOfAFaceLandsOnIt() async throws {
        // The pin hole pulls the face's own centroid aside; the middle of its outline stays at (30, 20).
        let model = try await loaded(plate())
        let face = try #require(model.result?.body("plate"))
        #expect(try face.faceCenter("plate.end").x > 30.1)
        #expect(near(try face.faceOutlineCenter("plate.end"), SIMD3(30, 20, 10)))
        try placeHole(model, x: 30.6, y: 19.5)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let c = try holeCenter(model)
        #expect(near(c, SIMD3(30, 20, 10)), "\(c)")
    }

    @Test func aClickAwayFromTheMiddleStaysPut() async throws {
        let model = try await loaded(plate())
        try placeHole(model, x: 12, y: 30)
        try await settle(model)
        let c = try holeCenter(model)
        #expect(near(c, SIMD3(12, 30, 10)), "\(c)")
    }

    @Test func theDotSlidesAHoleOverItsFace() async throws {
        let model = try await loaded(plate())
        try placeHole(model, x: 12, y: 30)
        try await settle(model)
        let id = try #require(model.document.features.last?.id)
        model.selectedFeature = id
        #expect(model.holeMoveDot.map { near($0, SIMD3(12, 30, 10)) } == true)
        #expect(model.dragHandle?.label == "Depth")

        model.beginHoleMove()
        #expect(model.dragHandle == nil, "the depth arrow steps aside while the hole moves")
        // 10 points per mm: 1 mm steps, and within 1 mm of a centre line lands on it.
        model.moveHole(rayOrigin: SIMD3(44.8, 20.7, 100), direction: SIMD3(0, 0, -1), pointsPerMM: 10)
        #expect(model.holeMoveDot.map { near($0, SIMD3(45, 20, 10)) } == true, "\(String(describing: model.holeMoveDot))")
        model.endHoleMove()
        try await settle(model)
        let c = try holeCenter(model)
        #expect(near(c, SIMD3(45, 20, 10)), "\(c)")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.holeMovePreview == nil && model.dragHandle?.label == "Depth", "the arrow is back")
    }
}

/// Picking a feature the timeline marker has rolled back builds it again, so its handle has a hole to show.
@Suite @MainActor struct RolledBackEditTests {
    @Test func editingARolledBackHoleMovesTheMarkerPastIt() async throws {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(4))
        let holeID = doc.features[3].id
        doc.rollback = 3  // the last hole is rolled back
        let model = DocumentModel(document: doc)
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
        let before = try #require(model.result?.body("plate")).volume
        model.editFeature(holeID)
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.markerPosition == 4 && model.document.rollback == nil)
        #expect(try #require(model.result?.body("plate")).volume < before, "the hole is cut")
        #expect(model.selectedFeature == holeID)
    }
}

/// A thread running the full length has no drag handle; its OK and Cancel come from the bar instead.
@Suite @MainActor struct FeatureWithoutHandleTests {
    private func loaded() async throws -> DocumentModel {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(4))
        let model = DocumentModel(document: doc)
        try await settle(model)
        return model
    }
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }
    private func addThread(_ model: DocumentModel) throws -> FeatureID {
        let wall = try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "plate.side.C0"))
        #expect(model.addThread(on: PickID(body: 0, face: wall)))
        return try #require(model.document.features.last?.id)
    }

    @Test func aNewThreadHasNoHandleButCanBeFinished() async throws {
        let model = try await loaded()
        let id = try addThread(model)
        try await settle(model)
        #expect(model.dragHandle == nil)
        #expect(model.featureWithoutHandle == id)
        model.finishFeatureEdit()
        #expect(model.featureWithoutHandle == nil && model.selectedFeature == nil && model.newFeature == nil)
        #expect(model.document.features.last?.id == id, "OK keeps the thread")
    }

    @Test func cancelTakesTheNewThreadOut() async throws {
        let model = try await loaded()
        let before = model.document.features.count
        _ = try addThread(model)
        try await settle(model)
        model.cancelNewFeature()
        try await settle(model)
        #expect(model.document.features.count == before && model.featureWithoutHandle == nil)
    }

    @Test func aSketchOrAHandleFeatureDoesNotGetTheBar() async throws {
        let model = try await loaded()
        model.selectedFeature = model.document.features.first?.id  // the sketch
        #expect(model.featureWithoutHandle == nil)
    }
}

/// Shell has a thickness handle, so it previews live, and a wall that can't be built says why.
@Suite @MainActor struct ShellHandleTests {
    private func loaded(thickness: String = "2 mm") async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm"))),
            Feature(id: "s", name: "Shell1", .shell(ShellFeature(body: "b", faces: [FaceRef(body: "b", face: "b.top")], thickness: thickness))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theHandleSitsOnTheOpenFacePointingIntoTheWall() async throws {
        let model = try await loaded()
        model.selectedFeature = "s"
        let h = try #require(model.dragHandle)
        #expect(h.label == "Thickness" && h.value == 2)
        #expect(h.base.z == 20 && h.direction.z == -1, "on the top face, pointing down into the box")
        #expect(model.featureWithoutHandle == nil, "the handle carries OK and Cancel")
    }

    @Test func typingAThicknessPreviewsItAndAnImpossibleOneSaysWhy() async throws {
        let model = try await loaded()
        model.selectedFeature = "s"
        let before = try #require(model.result?.body("b")).volume
        #expect(model.previewHandle("3 mm"))
        try await settle(model)
        let after = try #require(model.result?.body("b")).volume
        #expect(after > 0 && after != before, "the walls changed")
        #expect(!model.previewInvalid)
        _ = model.previewHandle("11 mm")
        try await settle(model)
        #expect(model.previewInvalid)
        #expect(model.handleProblem?.contains("at most 10 mm") == true, "\(model.handleProblem ?? "no reason")")
    }

    @Test func aShellThatFailsOnLoadShowsItsReasonInTheViewport() async throws {
        let model = try await loaded(thickness: "11 mm")
        model.selectedFeature = "s"
        #expect(model.errorText(of: "s")?.contains("at most 10 mm") == true, "\(model.errorText(of: "s") ?? "none")")
        #expect(model.dragHandle != nil, "the handle is still there to type a smaller wall")
    }

    @Test func committingAThicknessKeepsItAsOneStep() async throws {
        let model = try await loaded()
        model.selectedFeature = "s"
        #expect(model.commitHandle("4 mm"))
        try await settle(model)
        guard case .shell(let s)? = model.document.features.last?.kind else { Issue.record("no shell"); return }
        #expect(s.thickness == "4 mm")
    }
}

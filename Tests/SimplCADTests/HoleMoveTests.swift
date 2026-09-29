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

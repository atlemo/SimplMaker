// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// A sketch on a face has level, upward axes, so text written level in Sketch mode lies level on
/// the model; sketches from before keep the face's own axes until straightened.
@Suite @MainActor struct SketchAxesTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { ((a - b) * (a - b)).sum() < 1e-12 }

    @Test func uprightAxesRunLevelAndUp() {
        let side = Frame(origin: .zero, normal: SIMD3(1, 0, 0), xAxis: SIMD3(0, 0, 1)).upright
        #expect(near(side.xAxis, SIMD3(0, 1, 0)) && near(side.yAxis, SIMD3(0, 0, 1)))
        let front = Frame(origin: .zero, normal: SIMD3(0, -1, 0), xAxis: SIMD3(0, 0, -1)).upright
        #expect(near(front.xAxis, SIMD3(1, 0, 0)) && near(front.yAxis, SIMD3(0, 0, 1)))
        let top = Frame(origin: .zero, normal: SIMD3(0, 0, 1), xAxis: SIMD3(0, 1, 0)).upright
        #expect(near(top.xAxis, SIMD3(1, 0, 0)) && near(top.yAxis, SIMD3(0, 1, 0)))
        for origin in [Frame.xy, .xz, .yz] {
            #expect(near(origin.upright.xAxis, origin.xAxis), "the origin planes are upright already")
        }
    }

    /// The demo plate with a sketch on its right side (square to X): a point at sketch (5, 0).
    private func sideSketch(upright: Bool?) -> CADDocument {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(2))
        var s = Sketch()
        let p = s.addPoint(5, 0)
        s.constrain(.fix(p, x: 5, y: 0))
        doc.features.append(Feature(id: "side", name: "Side", .sketch(SketchFeature(
            plane: .face(FaceRef(body: "plate", face: "plate.side.L1")), sketch: s, uprightAxes: upright))))
        return doc
    }

    @Test func aNewSideSketchRunsLevelAnOldOneKeepsItsAxesUntilStraightened() async throws {
        let model = DocumentModel(document: sideSketch(upright: true))
        try await settle(model)
        let frame = try #require(model.result?.sketches["side"]?.frame)
        #expect(near(frame.xAxis, SIMD3(0, 1, 0)) && near(frame.yAxis, SIMD3(0, 0, 1)), "\(frame)")

        let old = DocumentModel(document: sideSketch(upright: nil))
        try await settle(old)
        let kept = try #require(old.result?.sketches["side"]?.frame)
        let face = try #require(old.result?.body("plate")).faceFrame("plate.side.L1")
        #expect(near(kept.xAxis, face.xAxis), "a sketch from before keeps the face's own axes")

        old.straightenAxes(of: "side")
        try await settle(old)
        guard case .sketch(let sf)? = old.document.features.last?.kind else { Issue.record("expected the sketch"); return }
        #expect(sf.uprightAxes == true)
        #expect(near(try #require(old.result?.sketches["side"]?.frame).xAxis, SIMD3(0, 1, 0)))
    }

    @Test func filesFromBeforeReadAsTheFacesOwnAxes() throws {
        let json = #"{"plane":{"xy":{}},"sketch":\#(String(decoding: try JSONEncoder().encode(Sketch()), as: UTF8.self))}"#
        let sf = try JSONDecoder().decode(SketchFeature.self, from: Data(json.utf8))
        #expect(sf.uprightAxes == nil)
        #expect(SketchFeature(plane: .xy, sketch: Sketch()).uprightAxes == true, "new sketches are upright")
    }
}

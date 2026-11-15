// Opening a sketch frames all of it, wherever it lies.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite(.serialized) @MainActor struct SketchOpenFramingTests {
    @Test func openingASketchFramesItsWholeOutline() async throws {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "far_sk"),
            EditSketchOperation(sketchID: "far_sk", add: [.circle(id: "c", center: SketchPoint2(x: "-200 mm", y: "50 mm"), diameter: "40", radius: nil)]),
        ]
        _ = try await rig.service.batch(documentID: id, expectedRevision: nil, label: "Far sketch", steps)
        let feature = try #require(model.document.features.first { $0.name.hasPrefix("Sketch") })
        let built = try #require(model.result?.sketches[feature.id])
        let box = try #require(DocumentModel.sketchExtent(built))
        #expect(abs(box.min.x - -220) < 0.5 && abs(box.max.x - -180) < 0.5)  // the circle's own extent, not just its centre
        #expect(abs(box.min.y - 30) < 0.5 && abs(box.max.y - 70) < 0.5)

        model.editSketch(feature.id)
        guard case .lookFit(let lo, let hi, _)? = model.cameraCommand?.command else {
            Issue.record("opening the sketch did not frame it"); return
        }
        #expect(lo.x < -219 && hi.x > -181 && lo.y < 31 && hi.y > 69)
    }

    @Test func aNewSketchFramesThePartSeenFaceOn() async throws {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        _ = try await rig.service.createBox(documentID: id, CADService.BoxRequest(width: "100", length: "60", height: "20", id: "slab"))
        model.beginSketch(on: .xy)
        guard case .lookFit(let lo, let hi, let n)? = model.cameraCommand?.command else {
            Issue.record("a new sketch did not frame the part"); return
        }
        #expect(n.z > 0.99 && hi.x - lo.x >= 99 && hi.y - lo.y >= 59)
    }
}

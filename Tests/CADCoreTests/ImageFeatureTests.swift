// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Reference images (Canvas): what is saved, and what a change to them rebuilds.
@Suite struct ImageFeatureTests {
    private func canvas(opacity: Double = 0.5) -> Feature {
        Feature(id: "img", name: "Canvas1", .image(ImageFeature(
            plane: .xy, fileName: "plan.png", data: Data([1, 2, 3]), pixelWidth: 200, pixelHeight: 100, width: "w", opacity: opacity)))
    }

    @Test func savesAndReadsBack() throws {
        var doc = CADDocument(parameters: [Parameter("w", "80 mm")])
        doc.features = [canvas()]
        let back = try CADDocument.decode(try doc.encoded())
        #expect(back == doc)
        guard case .image(let i) = back.features[0].kind else { Issue.record("expected an image"); return }
        #expect(i.fileName == "plan.png" && i.data == Data([1, 2, 3]) && i.aspect == 0.5)
    }

    @Test func opacityIsKeptInRange() {
        let a = ImageFeature(plane: .xy, fileName: "a", data: Data(), pixelWidth: 1, pixelHeight: 1, opacity: 3)
        let b = ImageFeature(plane: .xy, fileName: "b", data: Data(), pixelWidth: 1, pixelHeight: 1, opacity: -1)
        #expect(a.opacity == 1 && b.opacity == 0)
    }

    @Test func changingOpacityNeedsNoRebuild() {
        var a = CADDocument(), b = CADDocument()
        a.features = [canvas(opacity: 0.2)]
        b.features = [canvas(opacity: 0.9)]
        #expect(a != b)
        #expect(a.ignoringPresentation == b.ignoringPresentation)
    }

    @Test func parametersRenameInsideACanvas() throws {
        var doc = CADDocument(parameters: [Parameter("w", "80 mm")])
        doc.features = [canvas()]
        try doc.renameParameter("w", to: "plan_width")
        guard case .image(let i) = doc.features[0].kind else { Issue.record("expected an image"); return }
        #expect(i.width == "plan_width")
        #expect(doc.features(using: "plan_width").map(\.id) == ["img"])
    }

    @Test func aCanvasIsBuiltFromItsPlaneAndMakesNoBody() {
        let onFace = Feature(id: "c2", name: "Canvas2", .image(ImageFeature(
            plane: .face(FaceRef(body: "plate", face: "plate.end")), fileName: "x", data: Data(), pixelWidth: 1, pixelHeight: 1)))
        #expect(onFace.references == ["plate"])
        #expect(!onFace.createsBody && onFace.changedBodies.isEmpty && onFace.sketchesUsed.isEmpty)
        #expect(onFace.typeName == "Canvas")
    }
}

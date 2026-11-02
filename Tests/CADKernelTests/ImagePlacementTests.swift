// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

/// Where a reference image lands on a plane or face.
@Suite struct ImagePlacementTests {
    private func canvas(_ plane: PlaneRef, u: String = "0 mm", v: String = "0 mm", width: String = "40 mm", angle: String = "0 deg",
                        pixels: (Int, Int) = (400, 200)) -> Feature {
        Feature(id: "img", name: "Canvas1", .image(ImageFeature(
            plane: plane, fileName: "a.png", data: Data(), pixelWidth: pixels.0, pixelHeight: pixels.1,
            u: u, v: v, width: width, angle: angle)))
    }

    private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_length(a - b) < 1e-6 }

    @Test func liesOnAnOriginPlaneWithItsProportions() throws {
        let r = Regenerator.regenerate(CADDocument(features: [canvas(.xy, u: "10 mm", v: "5 mm")]))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let p = try #require(r.images["img"])
        #expect(p.width == 40 && p.height == 20)
        let c = p.corners  // top left, top right, bottom right, bottom left
        #expect(near(c[0], SIMD3(-10, 15, 0)) && near(c[1], SIMD3(30, 15, 0)))
        #expect(near(c[2], SIMD3(30, -5, 0)) && near(c[3], SIMD3(-10, -5, 0)))
    }

    @Test func turnsAboutItsCentre() throws {
        let r = Regenerator.regenerate(CADDocument(features: [canvas(.xy, angle: "90 deg")]))
        let c = try #require(r.images["img"]).corners
        // A quarter turn counter-clockwise: the top edge now runs up the page's left side.
        #expect(near(c[0], SIMD3(-10, -20, 0)) && near(c[1], SIMD3(-10, 20, 0)))
    }

    @Test func followsAFaceAndItsParameters() throws {
        var doc = CADDocument.demo()
        doc.features.append(canvas(.face(FaceRef(body: "plate", face: "plate.end")), width: "thickness * 2"))
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let p = try #require(r.images["img"])
        #expect(abs(p.width - 20) < 1e-9)
        // The plate's top face is at z = thickness; the picture lies flat on it, upright.
        for corner in p.corners { #expect(abs(corner.z - 10) < 1e-6) }
        #expect(abs(p.frame.normal.z) > 0.99)
        #expect(abs(p.frame.xAxis.z) < 1e-9)
    }

    @Test func reportsAWidthThatIsNotPositive() {
        let r = Regenerator.regenerate(CADDocument(features: [canvas(.xy, width: "0 mm")]))
        #expect(r.errors["img"] != nil && r.images["img"] == nil)
    }

    @Test func aMissingFaceIsReportedAndLaterFeaturesStillBuild() {
        let missing = canvas(.face(FaceRef(body: "gone", face: "gone.end")))
        let r = Regenerator.regenerate(CADDocument(features: [missing, canvas(.xy).withID("img2")]))
        #expect(r.errors["img"] != nil && r.images["img2"] != nil)
    }
}

private extension Feature {
    func withID(_ id: FeatureID) -> Feature { var f = self; f.id = id; return f }
}

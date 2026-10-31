// Extruding several flat faces of a body together, as one feature.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
import simd
@testable import CADCore
@testable import CADKernel

@Suite struct ExtrudeFacesTests {
    private func box() -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        return d
    }

    /// The face of the box whose outward normal is `n`.
    private func face(_ n: SIMD3<Double>, of d: CADDocument) throws -> FaceRef {
        let body = try #require(Regenerator.regenerate(d).body("b"))
        let name = try #require(body.faceNames.first { (try? body.faceFrame($0))?.normal == n })
        return FaceRef(body: "b", face: name)
    }

    @Test func twoFacesArePulledOutTogetherByOneDistance() throws {
        var d = box()
        let top = try face(SIMD3(0, 0, 1), of: d), side = try face(SIMD3(1, 0, 0), of: d)
        d.features.append(Feature(id: "x", name: "Extrude1", .extrude(ExtrudeFeature(face: top, more: [side], extent: .distance("3 mm")))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let grown = try #require(r.body("b"))
        #expect(abs(grown.volume - (4000 + 20 * 20 * 3 + 20 * 10 * 3)) < 1e-6, "\(grown.volume)")
        #expect(ExtrudeFeature(face: top, more: [side]).allFaces == [top, side])
    }

    @Test func aSingleFaceStillWorksAndTheOldFileFormatReads() throws {
        var d = box()
        let top = try face(SIMD3(0, 0, 1), of: d)
        let feature = ExtrudeFeature(face: top, extent: .distance("3 mm"))
        #expect(feature.moreFaces == nil && feature.allFaces == [top])
        d.features.append(Feature(id: "x", name: "Extrude1", .extrude(feature)))
        let r = Regenerator.regenerate(d)
        #expect(abs((r.body("b")?.volume ?? 0) - (4000 + 1200)) < 1e-6)
        // Saved without the extra faces: decodes with none.
        let data = try JSONEncoder().encode(feature)
        #expect(!String(decoding: data, as: UTF8.self).contains("moreFaces"))
        #expect(try JSONDecoder().decode(ExtrudeFeature.self, from: data) == feature)
    }
}

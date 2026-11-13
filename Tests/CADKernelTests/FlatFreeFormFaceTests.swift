// Faces that are flat but stored as free-form surfaces (what STEP files from other CAD programs often hold)
// are treated as flat: they have a frame, a profile, and can be extruded.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct FlatFreeFormFaceTests {
    typealias T = NewFeatureTests

    /// Two squares 40 mm apart blended by a loft: its side faces are flat, but the kernel builds them as free-form surfaces.
    static func loftOfTwoSquares() -> [Feature] {
        let a = LoftSection(sketch: "lo", profile: ProfileRef(curves: ["A", "B", "C", "D"]))
        let b = LoftSection(sketch: "hi", profile: ProfileRef(curves: ["E", "F", "G", "H"]))
        return [T.sketch("lo") { T.rect(&$0, -10, -10, 10, 10, ids: ["A", "B", "C", "D"]) },
                Feature(id: "up", name: "up", .plane(PlaneFeature(base: .xy, offset: "40 mm"))),
                T.sketch("hi", on: .plane("up")) { T.rect(&$0, -5, -5, 5, 5, ids: ["E", "F", "G", "H"]) },
                Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [a, b])))]
    }

    @Test func aFlatFreeFormFaceHasAFrameAndAProfile() throws {
        let body = try #require(try T.regen(Self.loftOfTwoSquares()).body("lf"))
        let sides = body.faceNames.filter { $0.hasPrefix("lf.side") }
        #expect(sides.count == 4, "\(body.faceNames)")
        for side in sides {
            let frame = try body.faceFrame(side)
            #expect(abs(simd_length(frame.normal) - 1) < 1e-9)
            // The sides lean in (10 -> 5 over 40 mm), so a side normal is mostly horizontal and a little upward.
            #expect(abs(frame.normal.z) > 0.05 && abs(frame.normal.z) < 0.2, "\(frame.normal)")
            _ = try body.faceProfile(side)
        }
    }

    @Test func aFlatFreeFormFaceCanBeExtruded() throws {
        let features = Self.loftOfTwoSquares()
        let before = try #require(try T.regen(features).body("lf"))
        let side = try #require(before.faceNames.first { $0.hasPrefix("lf.side") })
        let extrude = Feature(id: "ex", name: "ex", .extrude(ExtrudeFeature(face: FaceRef(body: "lf", face: side), extent: .distance("3"))))
        let r = try T.regen(features + [extrude])
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("lf"))
        #expect(body.isValid)
        #expect(body.volume > before.volume + 1, "\(body.volume) against \(before.volume)")
    }
}

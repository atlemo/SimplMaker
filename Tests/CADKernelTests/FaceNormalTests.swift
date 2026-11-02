// A planar face's frame normal points out of the solid, also for the faces a chamfer makes.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

@Suite struct FaceNormalTests {
    /// A chamfer's plane can have a left-handed coordinate system; its axis then points into the solid, and a
    /// sketch opened on the face looked at it from behind. The tessellation's normals are the reference.
    @Test func everyFaceFrameFacesOutward() throws {
        let body = try #require(Regenerator.regenerate(.demo()).body("plate"))
        #expect(body.hasFace("topedge.chamfer.plate.end|plate.side.L3"))
        let mesh = try body.tessellate()
        var checked = 0
        for (index, name) in mesh.faceNames.enumerated() {
            guard let frame = try? body.faceFrame(name) else { continue }  // curved faces have none
            var sum = SIMD3<Double>.zero
            for (t, face) in mesh.triangleFace.enumerated() where Int(face) == index {
                let v = Int(mesh.indices[t * 3]) * 3
                sum += SIMD3(Double(mesh.normals[v]), Double(mesh.normals[v + 1]), Double(mesh.normals[v + 2]))
            }
            #expect(simd_dot(sum, frame.normal) > 0, "\(name) faces into the body")
            checked += 1
        }
        #expect(checked >= 6)
    }
}

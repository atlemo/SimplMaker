// Holes drilled into curved faces.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct CurvedHoleTests {
    static func side(of body: KBody, besides: [String]) -> String? {
        body.faceNames.first { !besides.contains($0) }
    }

    @Test func holeThroughTheSideOfACylinder() throws {
        let cyl = Feature(id: "c", name: "c", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "20", diameter: "30")))
        var doc = CADDocument()
        doc.features = [cyl]
        let before = Regenerator.regenerate(doc)
        let body = try #require(before.body("c"))
        let side = try #require(Self.side(of: body, besides: ["c.top", "c.bottom"]))
        let hole = HoleFeature(face: FaceRef(body: "c", face: side), u: "5", v: "3", diameter: "4", depth: nil)
        doc.features.append(Feature(id: "h", name: "h", .hole(hole)))
        let after = Regenerator.regenerate(doc)
        #expect(after.errors.isEmpty, "\(after.errors)")
        let drilled = try #require(after.body("c"))
        let removed = body.volume - drilled.volume
        // Through all, across the whole diameter: about a 4 mm bore, 30 mm long.
        #expect(removed > 0.9 * .pi * 4 * 30 && removed < 1.05 * .pi * 4 * 30, "removed \(removed)")
        #expect(drilled.isValid)
    }

    @Test func blindHoleInASphere() throws {
        var doc = CADDocument()
        doc.features = [Feature(id: "s", name: "s", .primitive(PrimitiveFeature(kind: .sphere, plane: .xy, diameter: "40")))]
        let body = try #require(Regenerator.regenerate(doc).body("s"))
        let face = try #require(body.faceNames.first)
        var hole = HoleFeature(face: FaceRef(body: "s", face: face), u: "3", v: "2", diameter: "6")
        hole.depth = "8"
        doc.features.append(Feature(id: "h", name: "h", .hole(hole)))
        let after = Regenerator.regenerate(doc)
        #expect(after.errors.isEmpty, "\(after.errors)")
        let drilled = try #require(after.body("s"))
        #expect(body.volume - drilled.volume > 0.8 * .pi * 9 * 8)
        #expect(drilled.isValid)
    }
}

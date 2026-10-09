// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// Lay on Floor: turning a body so a flat face looks down, and dropping it until that face sits on z = 0.
@Suite struct LayOnFloorTests {
    /// A 20 × 10 × 5 box "e" standing on the XY plane, then `extra` features, then the lay-on-floor "l" (if `face`).
    private func laid(face: String?, extra: [Feature] = []) -> RegenResult {
        var d = CADDocument()
        d.features = [Feature(id: "e", name: "Box1", .primitive(PrimitiveFeature(
            kind: .box, plane: .xy, u: "12 mm", v: "-7 mm", width: "20 mm", length: "10 mm", height: "5 mm")))]
        d.features += extra
        if let face {
            d.features.append(Feature(id: "l", name: "Lay on Floor1", .layOnFloor(LayOnFloorFeature(face: FaceRef(body: "e", face: face)))))
        }
        return Regenerator.regenerate(d)
    }

    private func floating(_ move: MoveFeature) -> [Feature] { [Feature(id: "m", name: "Move1", .move(move))] }

    /// The face's plane must be the floor, looking down.
    private func expectOnFloor(_ r: RegenResult, face: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(r.errors.isEmpty, "\(r.errors)", sourceLocation: sourceLocation)
        let body = try #require(r.body("e"), sourceLocation: sourceLocation)
        let frame = try body.faceFrame(face)
        #expect(abs(frame.normal.z + 1) < 1e-9 && abs(frame.normal.x) < 1e-9 && abs(frame.normal.y) < 1e-9, "\(frame.normal)",
                sourceLocation: sourceLocation)
        #expect(abs(frame.origin.z) < 1e-9, "\(frame.origin)", sourceLocation: sourceLocation)
        #expect(abs(body.volume - 1000) < 1e-6, "\(body.volume)", sourceLocation: sourceLocation)
        // Nothing of the body is below the floor.
        let box = try #require(body.bounds, sourceLocation: sourceLocation)
        #expect(box.min.z > -1e-6, "\(box)", sourceLocation: sourceLocation)
    }

    @Test func aFloatingBodyDropsOntoItsBottomFace() throws {
        let r = laid(face: "e.bottom", extra: floating(MoveFeature(bodies: ["e"], dx: "5 mm", dy: "0 mm", dz: "30 mm")))
        try expectOnFloor(r, face: "e.bottom")
        // It only dropped: straight down, nothing turned or slid sideways.
        let box = try #require(r.body("e")?.bounds), before = try #require(laid(face: nil).body("e")?.bounds)
        #expect(simd_length(box.min - SIMD3(before.min.x + 5, before.min.y, 0)) < 1e-6, "\(box)")
        #expect(simd_length(box.max - SIMD3(before.max.x + 5, before.max.y, 5)) < 1e-6, "\(box)")
    }

    @Test func aBodyAlreadyOnTheFloorStaysPut() throws {
        let r = laid(face: "e.bottom")
        try expectOnFloor(r, face: "e.bottom")
        let box = try #require(r.body("e")?.bounds), before = try #require(laid(face: nil).body("e")?.bounds)
        #expect(simd_length(box.min - before.min) < 1e-6 && simd_length(box.max - before.max) < 1e-6, "\(box) \(before)")
    }

    @Test func theTopFaceTurnsAllTheWayOver() throws {
        let r = laid(face: "e.top")
        try expectOnFloor(r, face: "e.top")
        // Turned about the middle of the face: it stays where it was sideways, and rises to its old height.
        let box = try #require(r.body("e")?.bounds), before = try #require(laid(face: nil).body("e")?.bounds)
        #expect(simd_length(box.min - before.min) < 1e-6 && simd_length(box.max - before.max) < 1e-6, "\(box) \(before)")
    }

    @Test func aSideFaceLaysTheBodyOnItsSide() throws {
        let sides = try #require(laid(face: nil).body("e")).faceNames.filter { $0 != "e.top" && $0 != "e.bottom" }
        #expect(sides.count == 4, "\(sides)")
        for side in sides {
            let r = laid(face: side)
            try expectOnFloor(r, face: side)
            // Standing on a side, the box is 10 or 20 high (its width or its length).
            let box = try #require(r.body("e")?.bounds)
            let size = box.max - box.min
            #expect(abs(size.z - 10) < 1e-6 || abs(size.z - 20) < 1e-6, "\(side): \(size)")
        }
    }

    @Test func aTippedBodyLaysFlatOnATiltedFace() throws {
        let tipped = floating(MoveFeature(bodies: ["e"], dz: "40 mm", rx: "0 deg", ry: "30 deg", rz: "20 deg"))
        for face in ["e.bottom", "e.top"] {
            let r = laid(face: face, extra: tipped)
            try expectOnFloor(r, face: face)
        }
    }

    @Test func aCurvedFaceCannotLieOnTheFloor() throws {
        var d = CADDocument()
        d.features = [Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "20", diameter: "10")))]
        let cylinder = try #require(Regenerator.regenerate(d).body("c"))
        let round = try #require(cylinder.faceNames.first { (try? cylinder.faceFrame($0)) == nil })
        d.features.append(Feature(id: "l", name: "Lay on Floor1", .layOnFloor(LayOnFloorFeature(face: FaceRef(body: "c", face: round)))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors["l"]?.contains("flat face") == true, "\(r.errors)")
    }

    @Test func aMissingBodyIsAnError() {
        var d = CADDocument()
        d.features = [Feature(id: "l", name: "Lay on Floor1", .layOnFloor(LayOnFloorFeature(face: FaceRef(body: "gone", face: "gone.top"))))]
        #expect(Regenerator.regenerate(d).errors["l"] != nil)
    }

    @Test func theTurnToFaceDown() throws {
        #expect(Regenerator.turnToFaceDown(SIMD3(0, 0, -1)) == nil)
        let flip = try #require(Regenerator.turnToFaceDown(SIMD3(0, 0, 1)))
        #expect(abs(flip.angle - .pi) < 1e-12 && flip.axis == SIMD3(1, 0, 0))
        let side = try #require(Regenerator.turnToFaceDown(SIMD3(1, 0, 0)))
        #expect(abs(side.angle - .pi / 2) < 1e-12)
        // Turning the normal by that much does bring it down.
        for n in [SIMD3(1.0, 0, 0), SIMD3(0.3, -0.5, 0.8), SIMD3(0, 1, 0.001)] {
            let unit = n / (n * n).sum().squareRoot()
            let t = try #require(Regenerator.turnToFaceDown(n))
            let q = simd_quatd(angle: t.angle, axis: t.axis)
            let turned = q.act(unit)
            #expect(abs(turned.z + 1) < 1e-9, "\(n) -> \(turned)")
        }
    }
}

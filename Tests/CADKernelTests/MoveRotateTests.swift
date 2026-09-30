// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// A Move feature also turns what it moves, about X, Y and Z through its middle.
@Suite struct MoveRotateTests {
    private func boxDoc(_ move: MoveFeature) -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "10", height: "5"))),
            Feature(id: "m", name: "Move1", .move(move)),
        ]
        return d
    }

    @Test func aQuarterTurnAboutZSwapsWidthAndLengthAroundTheMiddle() throws {
        let r = Regenerator.regenerate(boxDoc(MoveFeature(bodies: ["b"], rz: "90 deg")))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let box = try #require(r.body("b")?.bounds)
        #expect(abs((box.max.x - box.min.x) - 10) < 1e-6 && abs((box.max.y - box.min.y) - 20) < 1e-6)
        #expect(abs((box.max.x + box.min.x) / 2) < 1e-6 && abs((box.max.z + box.min.z) / 2 - 2.5) < 1e-6, "about its own middle")
    }

    @Test func turnsComeBeforeTheMove() throws {
        let r = Regenerator.regenerate(boxDoc(MoveFeature(bodies: ["b"], dx: "100 mm", rx: "90 deg")))
        let box = try #require(r.body("b")?.bounds)
        // Turned about X: height 5 and length 10 trade places; then 100 mm along X.
        #expect(abs((box.max.y - box.min.y) - 5) < 1e-6 && abs((box.max.z - box.min.z) - 10) < 1e-6, "\(box)")
        #expect(abs((box.max.x + box.min.x) / 2 - 100) < 1e-6)
        #expect(abs((r.body("b")?.volume ?? 0) - 1000) < 1e-6)
    }

    @Test func aTurnedSketchTurnsItsFrameAndWhatIsBuiltOnIt() throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 4)
        var d = CADDocument()
        d.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: [], sketches: ["sk"], rx: "90 deg"))),
        ]
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let frame = try #require(r.sketches["sk"]?.frame)
        // The XY plane stood up about its middle (5, 2, 0): normal Z → -Y, the sketch's y axis → Z.
        #expect(simd_length(frame.normal - SIMD3(0, -1, 0)) < 1e-9, "\(frame.normal)")
        #expect(simd_length(frame.yAxis - SIMD3(0, 0, 1)) < 1e-9, "\(frame.yAxis)")
        #expect(simd_length(frame.point(5, 2) - SIMD3(5, 2, 0)) < 1e-9, "the middle stays where it was: \(frame.point(5, 2))")
    }

    @Test func parametersDriveTheTurn() throws {
        var d = boxDoc(MoveFeature(bodies: ["b"], rz: "turn"))
        d.parameters = [Parameter("turn", "90 deg", unit: .angle)]
        let box = try #require(Regenerator.regenerate(d).body("b")?.bounds)
        #expect(abs((box.max.x - box.min.x) - 10) < 1e-6)
    }

    @Test func oldFilesWithoutTurnsStillReadAndStayReadable() throws {
        let old = #"{"bodies":["b"],"dx":"5 mm","dy":"0 mm","dz":"0 mm","arrow":"X"}"#
        let m = try JSONDecoder().decode(MoveFeature.self, from: Data(old.utf8))
        #expect(m.rx == "0 deg" && m.rotating == false && m.dx == "5 mm")
        // A move that doesn't turn writes what older versions understand.
        let text = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!text.contains("rx") && !text.contains("rotating"))
        var turned = m
        turned.rz = "30 deg"; turned.rotating = true
        #expect(try JSONDecoder().decode(MoveFeature.self, from: try JSONEncoder().encode(turned)) == turned)
    }

    @Test func theRotationMatrixTurnsXFirst() {
        let m = Regenerator.rotationMatrix(SIMD3(.pi / 2, 0, .pi / 2))
        // Y → (X turn) Z → (Z turn) Z.
        #expect(simd_length(m * SIMD3(0, 1, 0) - SIMD3(0, 0, 1)) < 1e-12)
        // X → (X turn) X → (Z turn) Y.
        #expect(simd_length(m * SIMD3(1, 0, 0) - SIMD3(0, 1, 0)) < 1e-12)
    }
}

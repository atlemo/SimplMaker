// End-to-end: document -> parameters -> solver -> OpenCASCADE -> named bodies.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct RegeneratorTests {
    static func plateVolume(w: Double, d: Double, t: Double, hole: Double, pin: Double, r: Double) -> Double {
        (w * d - .pi * (hole * hole + pin * pin) / 4) * t - 2 * (r * r - .pi * r * r / 4) * t
    }

    @Test func demoRegeneratesWithoutErrors() throws {
        let r = Regenerator.regenerate(.demo())
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 1)
        let body = try #require(r.body("plate"))
        #expect(body.isValid)
        #expect(body.hasFace("corners.fillet.plate.side.L0|plate.side.L1"))
        #expect(body.hasFace("topedge.chamfer.plate.end|plate.side.L3"))
        #expect(body.hasFace("pin.side.C1"))
        // Chamfer removes a little more than the analytic plate-with-fillets volume.
        let v = Self.plateVolume(w: 60, d: 40, t: 10, hole: 10, pin: 6, r: 5)
        #expect(body.volume < v && body.volume > v * 0.98)
    }

    @Test func editingParametersRebuildsEverything() throws {
        var doc = CADDocument.demo()
        doc.features.removeLast()  // drop the chamfer so the volume is exact
        let before = Regenerator.regenerate(doc)
        let names = Set(try #require(before.body("plate")).faceNames)

        for i in doc.parameters.indices {
            switch doc.parameters[i].name {
            case "width": doc.parameters[i].expression = "90 mm"
            case "depth": doc.parameters[i].expression = "50 mm"
            case "thickness": doc.parameters[i].expression = "1 in"
            case "corner_r": doc.parameters[i].expression = "8"
            default: break
            }
        }
        let after = Regenerator.regenerate(doc)
        #expect(after.errors.isEmpty, "\(after.errors)")
        let body = try #require(after.body("plate"))
        let expected = Self.plateVolume(w: 90, d: 50, t: 25.4, hole: 12.5, pin: 6, r: 8)
        #expect(abs(body.volume - expected) < 1e-6 * expected)
        #expect(Set(body.faceNames) == names, "persistent names must survive the edit")
        let top = try body.faceFrame("plate.end")
        #expect(abs(top.origin.z - 25.4) < 1e-9)
    }

    @Test func brokenReferenceIsReportedNotFatal() throws {
        var doc = CADDocument.demo()
        if case .fillet(var f) = doc.features[4].kind {
            f.edges = [EdgeRef(body: "plate", edge: "no.such|edge")]
            doc.features[4].kind = .fillet(f)
        }
        let r = Regenerator.regenerate(doc)
        #expect(r.errors["corners"]?.contains("edge not found") == true)
        #expect(r.errors["topedge"] == nil, "later features still regenerate")
        #expect(r.body("plate") != nil)
    }

    @Test func tessellationAndExport() throws {
        let r = Regenerator.regenerate(.demo())
        let body = try #require(r.body("plate"))
        let mesh = try body.tessellate()
        #expect(mesh.indices.count == mesh.triangleFace.count * 3)
        #expect(mesh.positions.count == mesh.normals.count)
        #expect(Set(mesh.triangleFace).count == mesh.faceNames.count)
        let dir = FileManager.default.temporaryDirectory
        try KBody.exportSTEP([body], to: dir.appendingPathComponent("demo.step"))
        try KBody.exportSTL([body], to: dir.appendingPathComponent("demo.stl"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("demo.step").path))
    }
}

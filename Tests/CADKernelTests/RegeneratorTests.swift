// End-to-end: document -> parameters -> solver -> OpenCASCADE -> named bodies.
// Copyright © 2026 Atle Mo
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

    @Test func sketchDrawnWithToolsExtrudes() throws {
        // An L-shaped outline drawn as a line chain from the origin and closed back onto it, plus a hole.
        var s = Sketch()
        let corners: [SIMD2<Double>] = [SIMD2(40, 0), SIMD2(40, 10), SIMD2(10, 10), SIMD2(10, 30), SIMD2(0, 30)]
        var prev = s.addLine(from: SketchSnap(.zero, point: "origin"), to: SketchSnap(corners[0]))
        for c in corners.dropFirst() { prev = s.addLine(from: SketchSnap(.zero), to: SketchSnap(c), startPoint: prev.end) }
        s.addLine(from: SketchSnap(.zero), to: SketchSnap(.zero, point: "origin"), startPoint: prev.end)
        s.addCircle(center: SketchSnap(SIMD2(5, 20)), through: SketchSnap(SIMD2(7, 20)))
        #expect(s.constraints.count == 6)  // every segment got horizontal/vertical inferred

        var doc = CADDocument(parameters: [Parameter("h", "8 mm")])
        let sketch = Feature(name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))
        doc.features = [sketch]
        var r = Regenerator.regenerate(doc)
        let result = try #require(r.sketches[sketch.id])
        #expect(result.regions.count == 2)  // L minus the hole, and the hole
        #expect(result.regionMeshes.allSatisfy { !$0.indices.isEmpty })
        let outer = try #require(result.regions.max { $0.area < $1.area })

        let profile = ProfileRef(curves: outer.tags.split(separator: ",").map(String.init),
                                 hintU: outer.sample.x, hintV: outer.sample.y)
        let extrude = Feature(name: "Extrude1", .extrude(ExtrudeFeature(sketch: sketch.id, profiles: [profile],
                                                                         extent: .distance("h"))))
        doc.features.append(extrude)
        r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body(extrude.id))
        let expected = (40 * 10 + 10 * 20 - Double.pi * 4) * 8
        #expect(abs(body.volume - expected) < 1e-6 * expected)
    }

    @Test func filletHandleSitsOnTheEdgeBeforeRounding() throws {
        let r = Regenerator.regenerate(.demo())
        let input = try #require(r.edgeFeatureInputs["corners"]?["plate"])
        #expect(!input.hasFace("corners.fillet.plate.side.L0|plate.side.L1"))  // the body before the fillet
        let h = try input.edgeHandle("plate.side.L0|plate.side.L1")
        // Vertical corner edge at (60, 0), halfway up the 10 mm plate; rounding grows into the material.
        #expect(abs(h.origin.x - 60) < 1e-6 && abs(h.origin.y) < 1e-6 && abs(h.origin.z - 5) < 1e-6)
        #expect(abs(h.direction.x + 0.5.squareRoot()) < 1e-6 && abs(h.direction.y - 0.5.squareRoot()) < 1e-6)

        // A size that can't be built still leaves the input, so the handle stays usable.
        var doc = CADDocument.demo()
        if case .fillet(var f) = doc.features[4].kind {
            f.size = "100 mm"
            doc.features[4].kind = .fillet(f)
        }
        let bad = Regenerator.regenerate(doc)
        #expect(bad.errors["corners"] != nil)
        #expect(bad.edgeFeatureInputs["corners"]?["plate"] != nil)
    }
}

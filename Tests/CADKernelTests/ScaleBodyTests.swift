// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// The Scale feature on bodies: even growth about the middle of what is scaled.
@Suite struct ScaleBodyTests {
    /// A 20 × 10 × 5 box "b" about the origin, standing on the XY plane.
    private func boxDoc(_ scale: ScaleFeature?) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "10", height: "5")))]
        if let scale { d.features.append(Feature(id: "s", name: "Scale1", .scale(scale))) }
        return d
    }

    @Test func aBoxGrowsAboutItsMiddle() throws {
        let r = Regenerator.regenerate(boxDoc(ScaleFeature(bodies: ["b"], factor: "2")))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("b"))
        #expect(abs(body.volume - 8000) < 1e-6, "\(body.volume)")
        let box = try #require(body.bounds)
        #expect(simd_length((box.max - box.min) - SIMD3(40, 20, 10)) < 1e-6, "\(box)")
        #expect(simd_length((box.max + box.min) / 2 - SIMD3(0, 0, 2.5)) < 1e-6, "the middle stays where it was")
        let before = try #require(r.featureInputs["s"]?["b"])
        #expect(abs(before.volume - 1000) < 1e-6, "the drag handle starts from the body as it was")
    }

    @Test func aFactorBelowOneShrinksAndMayBeAParameter() throws {
        var d = boxDoc(ScaleFeature(bodies: ["b"], factor: "k / 4"))
        d.parameters = [Parameter("k", "2", unit: .none)]
        let r = Regenerator.regenerate(d)
        #expect(abs((r.body("b")?.volume ?? 0) - 125) < 1e-6, "half the size is an eighth of the volume")
    }

    @Test func severalBodiesScaleTogetherAboutTheirCommonMiddle() throws {
        var d = boxDoc(nil)
        d.features.append(Feature(id: "c", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "5"))))
        d.features.append(Feature(id: "m", name: "Move1", .move(MoveFeature(bodies: ["c"], dx: "50 mm"))))
        d.features.append(Feature(id: "s", name: "Scale1", .scale(ScaleFeature(bodies: ["b", "c"], factor: "2"))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        // Before: b spans x -10…10, c spans 45…55, so the middle is x = 22.5. After: spacing doubles about it.
        let b = try #require(r.body("b")?.bounds), c = try #require(r.body("c")?.bounds)
        #expect(abs(b.min.x - (22.5 - 2 * 32.5)) < 1e-6 && abs(b.max.x - (22.5 - 2 * 12.5)) < 1e-6, "\(b)")
        #expect(abs(c.min.x - (22.5 + 2 * 22.5)) < 1e-6 && abs(c.max.x - (22.5 + 2 * 32.5)) < 1e-6, "\(c)")
    }

    @Test func faceNamesSurviveSoLaterFeaturesHold() throws {
        let plain = Regenerator.regenerate(boxDoc(nil))
        let names = try #require(plain.body("b")).faceNames
        var d = boxDoc(ScaleFeature(bodies: ["b"], factor: "3"))
        let scaled = try #require(Regenerator.regenerate(d).body("b"))
        #expect(Set(scaled.faceNames) == Set(names))
        d.features.append(Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: "b", edge: try #require(scaled.edgeNames.first))], size: "1 mm"))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect((r.body("b")?.volume ?? 0) < 27000)
    }

    @Test func bodiesAndSketchesScaleInOneFeature() throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 5)
        var d = boxDoc(nil)
        d.features.insert(Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))), at: 0)
        d.features.append(Feature(id: "s", name: "Scale1", .scale(ScaleFeature(sketches: ["sk"], bodies: ["b"], factor: "2"))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs((r.body("b")?.volume ?? 0) - 8000) < 1e-6)
        #expect(abs((r.sketches["sk"]?.bounds?.max.x ?? 0) - 20) < 1e-6)
    }

    @Test func aBadFactorOrAMissingBodyIsAnError() {
        #expect(Regenerator.regenerate(boxDoc(ScaleFeature(bodies: ["b"], factor: "0"))).errors["s"]?.contains("more than zero") == true)
        #expect(Regenerator.regenerate(boxDoc(ScaleFeature(bodies: ["gone"], factor: "2"))).errors["s"]?.contains("scales is missing") == true)
        #expect(Regenerator.regenerate(boxDoc(ScaleFeature(factor: "2"))).errors["s"]?.contains("nothing to scale") == true)
    }

    @Test func anImportedMeshScalesToo() throws {
        let box = try KBody.primitive(.box(width: 20, length: 10, height: 5), on: .xy, featureID: "x")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }
        try KBody.exportSTL([box], to: url)
        var d = CADDocument()
        d.features = [Feature(id: "imp", name: "Import1", .importBody(ImportFeature(fileName: "box.stl", data: try Data(contentsOf: url)))),
                      Feature(id: "s", name: "Scale1", .scale(ScaleFeature(bodies: ["imp"], factor: "1.5")))]
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs((r.body("imp")?.volume ?? 0) - 1000 * 3.375) < 1e-3, "\(r.body("imp")?.volume ?? 0)")
    }

    @Test func itSavesDependsOnItsBodiesAndReadsOlderFiles() throws {
        let d = boxDoc(ScaleFeature(bodies: ["b"], factor: "2"))
        #expect(try CADDocument.decode(try d.encoded()) == d)
        #expect(d.features[1].references.contains("b"))
        // A file from before bodies could be scaled has none in it.
        let old = Data(#"{"sketches":["sk"],"factor":"2"}"#.utf8)
        let f = try JSONDecoder().decode(ScaleFeature.self, from: old)
        #expect(f.sketches == ["sk"] && f.bodies.isEmpty && f.factor == "2")
        let sketchOnly = try String(decoding: JSONEncoder().encode(ScaleFeature(sketches: ["sk"])), as: UTF8.self)
        #expect(!sketchOnly.contains("bodies"), "files that scale only sketches stay as they were: \(sketchOnly)")
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A rebuild that reuses the unchanged start of the timeline gives exactly what a full one does.
@Suite struct RegenCacheTests {
    private func doc(height: String = "10 mm", fillet: String = "2 mm", width: String = "w") -> CADDocument {
        var d = CADDocument(parameters: [Parameter("w", "20 mm")])
        d.features = [
            Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: width, length: "20", height: height))),
            Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [FaceRef(body: "b", face: "b.top")], size: fillet))),
        ]
        return d
    }

    private func volume(_ d: CADDocument, _ cache: RegenCache? = nil) throws -> Double {
        let r = Regenerator.regenerate(d, cache: cache)
        #expect(r.errors.isEmpty, "\(r.errors)")
        return try #require(r.body("b")).volume
    }

    @Test func cachedRebuildsMatchFullOnes() throws {
        let cache = RegenCache()
        for d in [doc(), doc(fillet: "3 mm"), doc(fillet: "1 mm"), doc(height: "12 mm", fillet: "1 mm"), doc()] {
            #expect(abs(try volume(d, cache) - (try volume(d))) < 1e-9)
        }
        var changed = doc()
        changed.parameters[0].expression = "30 mm"  // a parameter change reaches the first feature
        #expect(abs(try volume(changed, cache) - (try volume(changed))) < 1e-9)
        #expect(try volume(changed, cache) > (try volume(doc())) + 100)
    }

    @Test func separateLettersNeedNoMerge() throws {
        var s = Sketch()
        let p = s.addPoint(0, 0)
        s.constrain(.fix(p, x: 0, y: 0))
        s.texts = [SketchText(id: "T", text: "Hi", position: p, height: "10 mm")]
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: sk.regions.map { ProfileRef(curves: $0.tags.split(separator: ",").map(String.init), hintU: $0.sample.x, hintV: $0.sample.y) },
            extent: .distance("2 mm")))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let area = sk.regions.reduce(0) { $0 + $1.area }
        #expect(abs(try #require(r.body("e")).volume - 2 * area) < 1e-6)
    }
}

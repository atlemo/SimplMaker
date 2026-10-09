// Copyright © 2026 Atle Mo. All rights reserved.
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

    private final class Built: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    /// Rebuilds with the cache and reports which features had to be built.
    private func rebuilt(_ d: CADDocument, _ cache: RegenCache) -> (RegenResult, [String]) {
        let built = Built()
        let r = Regenerator.regenerate(d, cache: cache) { _, _, f in built.add(f.id) }
        return (r, built.all)
    }

    private func paramDoc() -> CADDocument {
        var d = CADDocument(parameters: [
            Parameter("w", "20 mm"), Parameter("h", "10 mm"), Parameter("r", "1 mm"),
            Parameter("d", "r * 2", comment: "built from r"), Parameter("unused", "5 mm"),
        ])
        d.features = [
            Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "w", length: "w", height: "h"))),
            Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [FaceRef(body: "b", face: "b.top")], size: "d"))),
        ]
        return d
    }

    @Test func aParameterNothingReadsRebuildsNothing() throws {
        let cache = RegenCache()
        var d = paramDoc()
        _ = rebuilt(d, cache)
        d.parameters[4].expression = "7 mm"
        let (r, built) = rebuilt(d, cache)
        #expect(built.isEmpty, "\(built)")
        // The values on the result are the new ones, not those the cache held.
        #expect(abs(try #require(r.parameters.values["unused"]).value - 7) < 1e-9)
    }

    @Test func aParameterRebuildsFromTheFirstFeatureThatReadsIt() throws {
        let cache = RegenCache()
        var d = paramDoc()
        _ = rebuilt(d, cache)
        // Only the fillet reads d, which is built from r.
        d.parameters[2].expression = "1.5 mm"
        var (r, built) = rebuilt(d, cache)
        #expect(built == ["f"], "\(built)")
        #expect(abs(try #require(r.body("b")).volume - (try volume(d))) < 1e-9)
        // The box reads h, and the fillet follows it.
        d.parameters[1].expression = "12 mm"
        (r, built) = rebuilt(d, cache)
        #expect(built == ["b", "f"], "\(built)")
        #expect(abs(try #require(r.body("b")).volume - (try volume(d))) < 1e-9)
        // And back again: the same document is the same result.
        d.parameters[1].expression = "10 mm"
        d.parameters[2].expression = "1 mm"
        let (back, _) = rebuilt(d, cache)
        #expect(abs(try #require(back.body("b")).volume - (try volume(paramDoc()))) < 1e-9)
    }

    @Test func aNewParameterThatAFeatureNamesRebuildsIt() throws {
        let cache = RegenCache()
        var d = paramDoc()
        d.features[1] = Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [FaceRef(body: "b", face: "b.top")], size: "late")))
        var (r, _) = rebuilt(d, cache)
        #expect(r.errors["f"] != nil)  // no parameter "late" yet
        d.parameters.append(Parameter("late", "1 mm"))
        var built: [String]
        (r, built) = rebuilt(d, cache)
        #expect(built == ["f"], "\(built)")
        #expect(r.errors.isEmpty, "\(r.errors)")
    }

    @Test func aSketchDimensionReadsParameters() throws {
        var s = Sketch()
        let rect = s.addRectangle(0, 0, 10, 10)
        s.dimension(.horizontalDistance(rect.corners[0], rect.corners[2]), "side")
        var d = CADDocument(parameters: [Parameter("side", "10 mm"), Parameter("unused", "1 mm")])
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let cache = RegenCache()
        _ = rebuilt(d, cache)
        d.parameters[1].expression = "2 mm"
        #expect(rebuilt(d, cache).1.isEmpty)
        d.parameters[0].expression = "14 mm"
        let (r, built) = rebuilt(d, cache)
        #expect(built == ["sk"])
        #expect(abs((try #require(r.sketches["sk"]).regions.first?.area ?? 0) - 14 * 10) < 1e-6)
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

// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Sketch text becomes letter profiles that extrude like any other.
@Suite struct TextTests {
    private func doc(_ text: String, height: String = "10 mm") -> CADDocument {
        var s = Sketch()
        let p = s.addPoint(0, 0)
        s.constrain(.fix(p, x: 0, y: 0))
        s.texts = [SketchText(id: "T", text: text, position: p, height: height)]
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        return d
    }

    @Test func lettersBecomeProfiles() throws {
        let r = Regenerator.regenerate(doc("HO"))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let sk = try #require(r.sketches["sk"])
        // H is one region; O is a ring plus the hole inside it.
        #expect(sk.regions.count == 3, "\(sk.regions.map(\.tags))")
        let h = try #require(sk.regions.first { $0.tags == "T#0" })
        #expect(h.area > 20 && h.area < 100, "\(h.area)")
        let bounds = sk.regions.map(\.sample)
        #expect(bounds.allSatisfy { $0.y > -1 && $0.y < 11 }, "letters sit on the baseline, 10 mm tall")
    }

    @Test func theLettersOfATextAreItsInkWithoutTheInsides() throws {
        let r = Regenerator.regenerate(doc("HO"))
        let sk = try #require(r.sketches["sk"])
        let text = try #require(sk.text(ofRegion: 0))
        #expect(text.id == "T")
        let ink = sk.letterRegions(of: text, parameters: r.parameters)
        #expect(ink.count == 2, "H and the ring of O; not the inside of O: \(sk.regions.map(\.tags))")
        #expect(!ink.contains { sk.regions[$0].tags == "T#2" }, "the inside of the O is a region of its own, and not ink")
        // Nested ink: the dot-and-ring of ® and an @ have ink inside a counter.
        let nested = Regenerator.regenerate(doc("®"))
        let nsk = try #require(nested.sketches["sk"])
        let ntext = try #require(nsk.text(ofRegion: 0))
        let nink = nsk.letterRegions(of: ntext, parameters: nested.parameters)
        #expect(nink.count >= 2 && nink.count < nsk.regions.count, "the ring and the R are ink; the gaps round and in them are not")
    }

    /// Profiles whose boxes overlap are merged with each other, and those that stand apart are left alone: one pair of
    /// kerned letters must not make the whole line pay for a merge, and must not change what comes out.
    @Test func onlyProfilesThatTouchAreMergedWhenExtruding() throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 10, lineIDs: ["A1", "A2", "A3", "A4"])
        s.addRectangle(5, 0, 15, 10, lineIDs: ["B1", "B2", "B3", "B4"])  // overlaps the first: three regions that touch
        s.addRectangle(40, 0, 50, 10, lineIDs: ["C1", "C2", "C3", "C4"])  // stands apart
        for p in s.points { s.constrain(.fix(p.id, x: p.x, y: p.y)) }
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
        #expect(sk.regions.count == 4, "\(sk.regions.map(\.tags))")
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: sk.regions.map { r in
                ProfileRef(curves: r.tags.split(separator: ",").map(String.init), hintU: r.sample.x, hintV: r.sample.y)
            }, extent: .distance("2 mm")))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("e"))
        // 15 × 10 for the two rectangles together, 10 × 10 for the third; each 2 mm tall.
        #expect(abs(body.volume - (150 + 100) * 2) < 1e-6, "\(body.volume)")
        #expect(body.faceNames.contains { $0.hasPrefix("e.side.C") }, "the standalone rectangle keeps its named sides: \(body.faceNames)")
        let b = try #require(body.bounds)
        #expect(abs(b.min.x) < 1e-3 && abs(b.max.x - 50) < 1e-3, "\(b)")  // OCCT boxes carry a hair of tolerance
    }

    @Test func aRegionWithOtherCurvesIsNoLetter() throws {
        var s = Sketch()
        let p = s.addPoint(2, 2)
        s.constrain(.fix(p, x: 2, y: 2))
        s.texts = [SketchText(id: "T", text: "I", position: p, height: "6 mm")]
        let r = s.addRectangle(0, 0, 20, 10, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: 0, y: 0)); s.constrain(.fix(r.corners[2], x: 20, y: 10))
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let result = Regenerator.regenerate(d)
        let sk = try #require(result.sketches["sk"])
        let plate = try #require(sk.regions.indices.first { sk.regions[$0].tags.contains("A") })
        #expect(sk.text(ofRegion: plate) == nil, "the plate round the I has curves that are not the text's")
        let letter = try #require(sk.regions.indices.first { $0 != plate })
        #expect(sk.text(ofRegion: letter)?.id == "T")
    }

    @Test func aTurnedTextTurnsItsLetters() throws {
        var d = doc("HHHH")
        func extent(_ d: CADDocument) throws -> (w: Double, h: Double) {
            let sk = try #require(Regenerator.regenerate(d).sketches["sk"])
            let pts = sk.regions.map(\.sample)
            return (pts.map(\.x).max()! - pts.map(\.x).min()!, pts.map(\.y).max()! - pts.map(\.y).min()!)
        }
        let level = try extent(d)
        #expect(level.w > level.h, "a word runs along x")
        if case .sketch(var sf) = d.features[0].kind {
            sf.sketch.texts[0].angle = .pi / 2
            d.features[0].kind = .sketch(sf)
        }
        let turned = try extent(d)
        #expect(turned.h > turned.w, "a quarter turn runs it up y: \(turned)")
        #expect(abs(turned.h - level.w) < 0.5 && abs(turned.w - level.h) < 0.5)
    }

    @Test func aLetterExtrudesAndFollowsItsHeight() throws {
        var d = doc("I")
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(
            sketch: "sk", profiles: [ProfileRef(curves: ["T#0"])], extent: .distance("2 mm")))))
        let small = Regenerator.regenerate(d)
        #expect(small.errors.isEmpty, "\(small.errors)")
        let v1 = try #require(small.body("e")).volume
        #expect(v1 > 0)
        if case .sketch(var sf) = d.features[0].kind {
            sf.sketch.texts[0].height = "20 mm"
            d.features[0].kind = .sketch(sf)
        }
        let big = Regenerator.regenerate(d)
        let v2 = try #require(big.body("e")).volume
        #expect(abs(v2 / v1 - 4) < 0.05, "twice as tall, four times the area: \(v2 / v1)")
    }

    @Test func textSurvivesSavingAndOlderSketchesStillLoad() throws {
        let d = doc("Hi")
        let back = try CADDocument.decode(try d.encoded())
        guard case .sketch(let sf) = back.features[0].kind else { Issue.record("expected a sketch"); return }
        #expect(sf.sketch.texts.first?.text == "Hi")
        #expect(try String(data: CADDocument.demo().encoded(), encoding: .utf8)?.contains("texts") == false,
                "sketches without text don't write the key, so older versions can still read them")
    }
}

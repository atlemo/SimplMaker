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

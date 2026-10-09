// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// Draft: leaning faces over about a flat face that stays put.
@Suite struct DraftTests {
    /// A 20 × 10 × 5 block from x = 10 to 30, y = 0 to 10, z = 0 to 5.
    private func block(extra: [Feature] = []) -> CADDocument {
        var s = Sketch()
        s.addRectangle(10, 0, 30, 10)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: [], hintU: 20, hintV: 5)], extent: .distance("5 mm")))))
        d.features += extra
        return d
    }

    /// The side faces of the block, and the face at the sketch plane (z = 0) and at the top (z = 5).
    private func faces(_ body: KBody) throws -> (sides: [String], bottom: String, top: String) {
        var sides: [String] = [], bottom = "", top = ""
        for name in body.faceNames {
            let frame = try body.faceFrame(name)
            if frame.normal.z < -0.99 { bottom = name } else if frame.normal.z > 0.99 { top = name } else { sides.append(name) }
        }
        return (sides, bottom, top)
    }

    /// The block, its faces, and the result of drafting some sides of it about its bottom (or top) face.
    private func drafted(_ angle: String, sides: ([String]) -> [String] = { $0 },
                         fixedTop: Bool = false) throws -> (before: KBody, after: RegenResult) {
        let base = block()
        let before = try #require(Regenerator.regenerate(base).body("e"))
        let f = try faces(before)
        var d = base
        d.features.append(Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "e", faces: sides(f.sides).map { FaceRef(body: "e", face: $0) },
            fixed: FaceRef(body: "e", face: fixedTop ? f.top : f.bottom), angle: angle))))
        return (before, Regenerator.regenerate(d))
    }

    @Test func aPositiveAngleNarrowsTheBodyAwayFromTheFixedFace() throws {
        let (before, result) = try drafted("10 deg")
        #expect(result.errors.isEmpty, "\(result.errors)")
        let body = try #require(result.body("e"))
        let t = tan(10 * Double.pi / 180)
        // Every side leans in by 5 tan(10°) at the top; the bottom stays 20 × 10.
        var volume = 0.0
        for i in 0..<1000 {
            let z = (Double(i) + 0.5) * 5 / 1000
            volume += (20 - 2 * z * t) * (10 - 2 * z * t) * 5 / 1000
        }
        #expect(abs(body.volume - volume) < 1e-3, "volume \(body.volume), want \(volume) (was \(before.volume))")
        let box = try #require(body.bounds)
        #expect(abs(box.min.x - 10) < 1e-6 && abs(box.max.x - 30) < 1e-6 && abs(box.min.z) < 1e-6 && abs(box.max.z - 5) < 1e-6,
                "the fixed face keeps its outline: \(box)")
    }

    @Test func aNegativeAngleWidensIt() throws {
        let (before, result) = try drafted("-10 deg")
        #expect(result.errors.isEmpty, "\(result.errors)")
        let body = try #require(result.body("e"))
        #expect(body.volume > before.volume)
        let box = try #require(body.bounds)
        #expect(abs(box.max.x - (30 + 5 * tan(10 * Double.pi / 180))) < 1e-6, "\(box)")
    }

    @Test func theFixedFaceDecidesWhichEndStaysPut() throws {
        let (before, result) = try drafted("10 deg", fixedTop: true)
        #expect(result.errors.isEmpty, "\(result.errors)")
        let body = try #require(result.body("e"))
        let box = try #require(body.bounds)
        #expect(body.volume < before.volume && abs(box.max.x - 30) < 1e-6 && abs(box.min.x - 10) < 1e-6,
                "narrower going down, wide at the top: \(box)")
    }

    @Test func onlyThePickedFacesLean() throws {
        let (before, result) = try drafted("10 deg", sides: { Array($0.prefix(1)) })
        #expect(result.errors.isEmpty, "\(result.errors)")
        let body = try #require(result.body("e"))
        let t = tan(10 * Double.pi / 180)
        // One side of 20 × 5 gives up a wedge of 5 · 5t / 2 on its length (10 or 20).
        let lost = before.volume - body.volume
        #expect(lost > 5 * 5 * t / 2 * 10 - 1e-3 && lost < 5 * 5 * t / 2 * 20 + 1e-3, "lost \(lost)")
    }

    @Test func facesKeepTheirNamesSoLaterFeaturesStillFindThem() throws {
        let (before, result) = try drafted("5 deg")
        let body = try #require(result.body("e"))
        #expect(Set(before.faceNames) == Set(body.faceNames), "\(before.faceNames) -> \(body.faceNames)")
    }

    @Test func angleIsAnExpressionThatCanBeRenamedAndSetToNothing() throws {
        var d = block(extra: [Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "e", faces: [FaceRef(body: "e", face: "e.side.x")], fixed: FaceRef(body: "e", face: "e.start"), angle: "taper")))])
        d.parameters = [Parameter("taper", "3 deg")]
        #expect(d.features[2].kind.expressions == ["taper"])
        #expect(d.features[2].references == ["e"])
        #expect(d.features[2].changedBodies == ["e"])
        d.features[2].kind.mapExpressions { $0 == "taper" ? "draft_angle" : $0 }
        #expect(d.features[2].kind.expressions == ["draft_angle"])
        // Nothing to lean: the body is as it was.
        let (before, nothing) = try drafted("0 deg")
        #expect(nothing.errors.isEmpty && abs((nothing.body("e")?.volume ?? 0) - before.volume) < 1e-9)
    }

    @Test func problemsAreSaidInPlainWords() throws {
        let (_, tooSteep) = try drafted("90 deg")
        #expect(tooSteep.errors["d"]?.contains("less than 90") == true, "\(tooSteep.errors)")

        let base = block()
        let before = try #require(Regenerator.regenerate(base).body("e"))
        let f = try faces(before)
        var noFixed = base
        noFixed.features.append(Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "e", faces: f.sides.map { FaceRef(body: "e", face: $0) }, fixed: nil))))
        #expect(Regenerator.regenerate(noFixed).errors["d"]?.contains("stays put") == true)

        // A side can't lean about itself.
        var same = base
        same.features.append(Feature(id: "d", name: "Draft1", .draft(DraftFeature(
            body: "e", faces: [FaceRef(body: "e", face: f.sides[0])], fixed: FaceRef(body: "e", face: f.sides[0])))))
        #expect(Regenerator.regenerate(same).errors["d"] != nil)

        // An 80° lean over 5 mm of height would run the 10 mm wide block into itself.
        let (_, huge) = try drafted("80 deg")
        #expect(huge.errors["d"] != nil, "\(huge.errors)")
    }
}

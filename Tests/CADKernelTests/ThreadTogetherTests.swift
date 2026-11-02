// Threads on several faces of one feature are cut in one pass over the body, and must come out as if one after the other.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct ThreadTogetherTests {
    /// A 60 × 30 × 15 block (centred on the origin, base on z = 0) with a hole of each diameter at each x offset, drilled
    /// from `face`, and the holes' walls.
    static func block(holes: [(diameter: String, dx: Double)], from face: String = "b.top", depth: String? = nil,
                      tip: String = "118 deg", kind: HoleKind = .simple, headAngle: String = "90 deg",
                      id: FeatureID = "b") throws -> (features: [Feature], walls: [FaceRef]) {
        let box = NewFeatureTests.box(id, "60", "30", "15")
        var doc = CADDocument()
        doc.features = [box]
        let frame = try Regenerator.regenerate(doc).body(id)!.faceFrame(face.replacingOccurrences(of: "b.", with: "\(id)."))
        let centre = SIMD3<Double>(0, 0, face.hasSuffix("top") ? 15 : 0) - frame.origin
        let u = (centre * frame.xAxis).sum(), v = (centre * frame.yAxis).sum()
        let sign = frame.xAxis.x >= 0 ? 1.0 : -1.0  // the face's x axis may run against the world's
        let features = holes.enumerated().map { n, hole in
            Feature(id: "\(id)h\(n)", name: "hole \(n)",
                    .hole(HoleFeature(face: FaceRef(body: id, face: face.replacingOccurrences(of: "b.", with: "\(id).")),
                                      u: "\(u + sign * hole.dx)", v: "\(v)", kind: kind, diameter: hole.diameter, depth: depth,
                                      tipAngle: tip, headAngle: headAngle)))
        }
        doc.features = [box] + features
        let drilled = try #require(Regenerator.regenerate(doc).body(id))
        let walls = try holes.indices.map { n in
            FaceRef(body: id, face: try #require(drilled.faceNames.first { $0.hasPrefix("\(id)h\(n).hole.wall") }))
        }
        return ([box] + features, walls)
    }

    static func sizes(_ names: [String]) -> [ThreadSize] { names.map { ThreadStandard.metric.size($0)! } }

    /// The faces threaded one at a time through the kernel, named the way a feature on several faces names them.
    static func oneByOne(_ body: KBody, _ walls: [FaceRef], _ sizes: [ThreadSize], length: Double? = nil) throws -> KBody {
        var result = body
        for (n, wall) in walls.enumerated() {
            result = try result.thread(face: wall.face, majorDiameter: sizes[n].diameter, pitch: sizes[n].pitch, length: length,
                                       flipped: false, leftHanded: false, featureID: n == 0 ? "th" : "th.\(n + 1)")
        }
        return result
    }

    static func together(_ body: KBody, _ walls: [FaceRef], _ sizes: [ThreadSize], length: Double? = nil) throws -> KBody {
        try body.threads(faces: walls.map(\.face), majorDiameters: sizes.map(\.diameter), pitches: sizes.map(\.pitch), length: length,
                         flipped: false, leftHanded: false, featureID: "th")
    }

    static func sameBody(_ a: KBody, _ b: KBody) {
        #expect(a.isValid && b.isValid)
        #expect(abs(a.volume - b.volume) <= 1e-6 * b.volume, "volume \(a.volume) against \(b.volume)")
        #expect(a.faceNames.sorted() == b.faceNames.sorted())
    }

    @Test func holesOfDifferentSizesThreadedTogetherComeOutAsOneAfterTheOther() throws {
        let (features, walls) = try Self.block(holes: [("6.8", -24), ("5", -8), ("4.2", 8), ("6.8", 24)])
        let drilled = try #require(NewFeatureTests.regen(features).body("b"))
        let sizes = Self.sizes(["M8x1.25", "M6x1", "M5x0.8", "M8x1.25"])
        let both = try Self.together(drilled, walls, sizes)
        let single = try Self.oneByOne(drilled, walls, sizes)
        Self.sameBody(both, single)
        for prefix in ["th.thread", "th.2.thread", "th.3.thread", "th.4.thread"] {
            #expect(both.faceNames.contains { $0.hasPrefix(prefix) }, "\(prefix)")
        }
        #expect(both.volume < drilled.volume + 1)  // not the unthreaded hole
    }

    @Test func aFeatureOnSeveralHolesDoesNotChangeWhenTheyAreThreadedTogether() throws {
        // Through the regenerator, with a length, left-handed and a tolerance: the same as faces done one at a time.
        let (features, walls) = try Self.block(holes: [("6.8", -20), ("6.8", 0), ("6.8", 20)])
        let feature = Feature(id: "th", name: "th", .thread(ThreadFeature(face: walls[0], moreFaces: Array(walls.dropFirst()), size: "M8x1.25",
                                                                           length: "9 mm", leftHanded: true, tolerance: "2")))
        let r = try NewFeatureTests.regen(features + [feature])
        let body = try #require(r.body("b"))
        let drilled = try #require(NewFeatureTests.regen(features).body("b"))
        let m8 = ThreadStandard.metric.size("M8x1.25")!
        let grown = ThreadSize(name: m8.name, diameter: m8.diameter * 1.02, pitch: m8.pitch)
        var single = drilled
        for (n, wall) in walls.enumerated() {
            single = try single.thread(face: wall.face, majorDiameter: grown.diameter, pitch: grown.pitch, length: 9, flipped: false,
                                       leftHanded: true, featureID: n == 0 ? "th" : "th.\(n + 1)")
        }
        Self.sameBody(body, single)
        #expect(r.featureInputs["th"]?["b"] != nil)
    }

    @Test func threadsThatWouldReachEachOtherAreMadeOneAfterTheOther() throws {
        // Two Ø5 holes 7.8 mm apart: their M6 rings don't touch, but the cuts around them reach each other.
        let (features, walls) = try Self.block(holes: [("5", -3.9), ("5", 3.9)])
        let drilled = try #require(NewFeatureTests.regen(features).body("b"))
        let sizes = Self.sizes(["M6x1", "M6x1"])
        #expect(throws: KernelError.self) { try Self.together(drilled, walls, sizes) }
        let feature = Feature(id: "th", name: "th", .thread(ThreadFeature(face: walls[0], moreFaces: [walls[1]], size: "M6x1")))
        let r = try NewFeatureTests.regen(features + [feature])
        let body = try #require(r.body("b"))
        #expect(body.isValid)
        #expect(body.faceNames.contains { $0.hasPrefix("th.thread") } && body.faceNames.contains { $0.hasPrefix("th.2.thread") })
        Self.sameBody(body, try Self.oneByOne(drilled, walls, sizes))
    }

    @Test func theSameFaceTwiceIsNotThreadedTwiceInOnePass() throws {
        let (features, walls) = try Self.block(holes: [("6.8", 0)])
        let drilled = try #require(NewFeatureTests.regen(features).body("b"))
        #expect(throws: KernelError.self) { try Self.together(drilled, [walls[0], walls[0]], Self.sizes(["M8x1.25", "M8x1.25"])) }
    }

    @Test func shaftsAreThreadedTogetherToo() throws {
        let plate = NewFeatureTests.box("p", "40", "20", "5")
        let shafts = [("c1", "10", -10.0), ("c2", "8", 10.0)].map { id, d, u in
            ThreadTests.cylinder(id, d: d, h: "20", u: "\(u)", op: .join, on: .face(FaceRef(body: "p", face: "p.top")))
        }
        let features = [plate] + shafts
        let body = try #require(NewFeatureTests.regen(features).body("p"))
        let walls = try ["c1", "c2"].map { id in FaceRef(body: "p", face: try #require(body.faceNames.first { $0.hasPrefix("\(id).side") })) }
        let sizes = Self.sizes(["M10x1.5", "M8x1.25"])
        let both = try Self.together(body, walls, sizes)
        Self.sameBody(both, try Self.oneByOne(body, walls, sizes))
        #expect(both.volume < body.volume)
    }

    @Test func facesOnDifferentBodiesAreThreadedToo() throws {
        let one = try Self.block(holes: [("6.8", 0)], id: "b")
        let two = try Self.block(holes: [("5", 0)], id: "d")
        // The second block stands beside the first so that the two don't overlap.
        let move = Feature(id: "mv", name: "move", .move(MoveFeature(bodies: ["d"], dx: "80 mm")))
        let thread = Feature(id: "th", name: "th", .thread(ThreadFeature(face: one.walls[0], moreFaces: [two.walls[0]],
                                                                         moreSpecs: [ThreadSpec(standard: .metric, size: "M6x1")], size: "M8x1.25")))
        let r = try NewFeatureTests.regen(one.features + two.features + [move, thread])
        #expect(try #require(r.body("b")).faceNames.contains { $0.hasPrefix("th.thread") })
        #expect(try #require(r.body("d")).faceNames.contains { $0.hasPrefix("th.2.thread") })
        #expect(try #require(r.body("b")).isValid && #require(r.body("d")).isValid)
    }

    // MARK: where a thread starts: the end with air beyond it

    private func cylinder(_ wall: FaceRef, in features: [Feature], flipped: Bool = false) throws -> KCylinder {
        try #require(NewFeatureTests.regen(features).body(wall.body)).faceCylinder(wall.face, flipped: flipped)
    }

    @Test func aThroughHoleStartsAtItsTopAndFlippedAtItsBottom() throws {
        let (features, walls) = try Self.block(holes: [("6.8", 0)])
        let top = try cylinder(walls[0], in: features)
        #expect(abs(top.start.z - 15) < 1e-9 && top.direction.z < -0.999 && top.isHole)
        let bottom = try cylinder(walls[0], in: features, flipped: true)
        #expect(abs(bottom.start.z) < 1e-9 && bottom.direction.z > 0.999)
    }

    @Test(arguments: ["0 deg", "118 deg"])
    func aBlindHoleStartsAtItsMouthWhateverItsFloorIs(tip: String) throws {
        let (fromTop, topWalls) = try Self.block(holes: [("6.8", 0)], depth: "8 mm", tip: tip)
        let down = try cylinder(topWalls[0], in: fromTop)
        #expect(abs(down.start.z - 15) < 1e-9 && down.direction.z < -0.999, "from the top: \(down)")
        let (fromBottom, bottomWalls) = try Self.block(holes: [("6.8", 0)], from: "b.bottom", depth: "8 mm", tip: tip)
        let up = try cylinder(bottomWalls[0], in: fromBottom)
        #expect(abs(up.start.z) < 1e-9 && up.direction.z > 0.999, "from the bottom: \(up)")
    }

    @Test func aCountersunkHoleStartsAtItsMouth() throws {
        // The wall ends in a cone, not a flat face: the end is found by the probe, not by the face across the edge.
        let (features, walls) = try Self.block(holes: [("6.8", 0)], kind: .countersink, headAngle: "120 deg")
        let cyl = try cylinder(walls[0], in: features)
        #expect(cyl.start.z > 14 && cyl.start.z < 15 && cyl.direction.z < -0.999, "\(cyl)")
    }

    @Test func aShaftOnAPlateStartsAtItsTipAndAShoulderIsNotAnOpenEnd() throws {
        let plate = NewFeatureTests.box("p", "30", "30", "5")
        let shaft = ThreadTests.cylinder("c", d: "10", h: "20", op: .join, on: .face(FaceRef(body: "p", face: "p.top")))
        let body = try #require(NewFeatureTests.regen([plate, shaft]).body("p"))
        let side = try #require(body.faceNames.first { $0.hasPrefix("c.side") })
        let tip = try body.faceCylinder(side)
        #expect(abs(tip.start.z - 25) < 1e-9 && tip.direction.z < -0.999 && !tip.isHole)
        let other = try body.faceCylinder(side, flipped: true)
        #expect(abs(other.start.z - 5) < 1e-9 && other.direction.z > 0.999)
    }
}

// Threads: sizes from the tables, and threads cut into shafts and holes through the regenerator.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct ThreadTests {
    static func cylinder(_ id: FeatureID, d: String, h: String, u: String = "0", op: BodyOperation = .newBody,
                         on plane: PlaneRef = .xy) -> Feature {
        Feature(id: id, name: id, .primitive(PrimitiveFeature(kind: .cylinder, plane: plane, u: u, height: h, diameter: d,
                                                              operation: op)))
    }

    static func thread(_ face: FaceRef, _ size: String, _ standard: ThreadStandard = .metric, length: String? = nil,
                       leftHanded: Bool = false) -> Feature {
        Feature(id: "th", name: "th", .thread(ThreadFeature(face: face, standard: standard, size: size, length: length,
                                                            leftHanded: leftHanded)))
    }

    /// Volume of a basic-profile thread L long: the core, plus the teeth between the minor and major
    /// diameters (external teeth fill 3/4 of the pitch at the minor diameter, 1/8 at the major).
    static func externalVolume(_ s: ThreadSize, _ length: Double) -> Double {
        let r0 = s.minorDiameter / 2, r1 = s.diameter / 2
        let steps = 200
        var v = Double.pi * r0 * r0
        for k in 0..<steps {
            let r = r0 + (r1 - r0) * (Double(k) + 0.5) / Double(steps)
            let fill = 0.75 + (0.125 - 0.75) * (r - r0) / (r1 - r0)
            v += 2 * .pi * r * fill * (r1 - r0) / Double(steps)
        }
        return v * length
    }

    @Test func sizesComeFromTheTables() throws {
        let m8 = try #require(ThreadStandard.metric.size("M8x1.25"))
        #expect(m8.diameter == 8 && m8.pitch == 1.25)
        #expect(abs(m8.minorDiameter - 6.647) < 1e-3)
        let quarter = try #require(ThreadStandard.unc.size("1/4-20"))
        #expect(abs(quarter.diameter - 6.35) < 1e-9 && abs(quarter.pitch - 1.27) < 1e-9)
        #expect(ThreadStandard.unf.size("#10-32") != nil)
        #expect(ThreadStandard.metricFine.size("M10x1.25") != nil)
        #expect(m8.label(.metric) == "M8 × 1.25")
        #expect(quarter.label(.unc) == "1/4-20 UNC")
    }

    @Test func theBestSizeSuitsTheFace() {
        #expect(ThreadSize.best(forDiameter: 8, hole: false)?.1.name == "M8x1.25")
        #expect(ThreadSize.best(forDiameter: 6.35, hole: false)?.1.name == "1/4-20")
        #expect(ThreadSize.best(forDiameter: 6.8, hole: true)?.1.name == "M8x1.25")  // the M8 tap drill
        #expect(ThreadSize.best(forDiameter: 5, hole: true)?.1.name == "M6x1")
        #expect(ThreadSize.best(forDiameter: 6, hole: true)?.1.name == "M6x1")
    }

    @Test func anExternalThreadCutsTheShaft() throws {
        let face = FaceRef(body: "c", face: "c.side")
        var doc = CADDocument()
        doc.features = [Self.cylinder("c", d: "8", h: "20")]
        let cyl = try #require(Regenerator.regenerate(doc).body("c")).faceCylinder("c.side")
        #expect(!cyl.isHole && abs(cyl.radius - 4) < 1e-9 && abs(cyl.length - 20) < 1e-9)
        #expect(abs(cyl.start.z - 20) < 1e-9 && cyl.direction.z < -0.999)  // from the top down

        let start = Date()
        let r = try NewFeatureTests.regen([Self.cylinder("c", d: "8", h: "20"), Self.thread(face, "M8x1.25")])
        let elapsed = Date().timeIntervalSince(start)
        let body = try #require(r.body("c"))
        #expect(body.isValid)
        #expect(body.faceNames.contains { $0.hasPrefix("th.thread") })
        let expected = Self.externalVolume(ThreadStandard.metric.size("M8x1.25")!, 20)
        #expect(abs(body.volume - expected) / expected < 0.02, "volume \(body.volume), expected about \(expected)")
        #expect(elapsed < 10, "took \(elapsed) s")
    }

    @Test func aLeftHandedThreadHasTheSameVolume() throws {
        let face = FaceRef(body: "c", face: "c.side")
        let right = try #require(try NewFeatureTests.regen([Self.cylinder("c", d: "6", h: "10"), Self.thread(face, "M6x1")]).body("c"))
        let left = try #require(try NewFeatureTests.regen([Self.cylinder("c", d: "6", h: "10"),
                                                           Self.thread(face, "M6x1", leftHanded: true)]).body("c"))
        #expect(left.isValid)
        #expect(abs(left.volume - right.volume) / right.volume < 1e-3)
    }

    @Test func aShortThreadStopsPartWayAlongAShaftOnAPlate() throws {
        let plate = NewFeatureTests.box("p", "30", "30", "5")
        let shaft = Self.cylinder("c", d: "10", h: "20", op: .join, on: .face(FaceRef(body: "p", face: "p.top")))
        var doc = CADDocument()
        doc.features = [plate, shaft]
        let before = try #require(Regenerator.regenerate(doc).body("p"))
        let side = try #require(before.faceNames.first { $0.hasPrefix("c.side") })
        let cyl = try before.faceCylinder(side)
        #expect(abs(cyl.start.z - 25) < 1e-9, "the thread starts at the free tip, not at the plate")
        let r = try NewFeatureTests.regen([plate, shaft, Self.thread(FaceRef(body: "p", face: side), "M10x1.5", length: "12 mm")])
        let body = try #require(r.body("p"))
        #expect(body.isValid)
        let removed = before.volume - body.volume
        let full = Double.pi * 25 * 12 - Self.externalVolume(ThreadStandard.metric.size("M10x1.5")!, 12)
        #expect(abs(removed - full) / full < 0.05, "removed \(removed), expected about \(full)")
    }

    /// The groove of an internal thread L long, between the minor and major diameters (it fills
    /// 3/4 of the pitch at the minor diameter, 1/8 at the major).
    static func internalGroove(_ s: ThreadSize, _ length: Double) -> Double {
        let r0 = s.minorDiameter / 2, r1 = s.diameter / 2
        let steps = 200
        var v = 0.0
        for k in 0..<steps {
            let r = r0 + (r1 - r0) * (Double(k) + 0.5) / Double(steps)
            v += 2 * .pi * r * (0.75 + (0.125 - 0.75) * (r - r0) / (r1 - r0)) * (r1 - r0) / Double(steps)
        }
        return v * length
    }

    /// A 30 × 30 × 15 block with a hole down its middle, and the hole's wall.
    static func drilledBlock(_ diameter: String, depth: String? = nil) throws -> (features: [Feature], wall: FaceRef) {
        let block = NewFeatureTests.box("b", "30", "30", "15")
        var doc = CADDocument()
        doc.features = [block]
        let top = try Regenerator.regenerate(doc).body("b")!.faceFrame("b.top")
        let d = SIMD3<Double>(0, 0, 15) - top.origin
        let hole = Feature(id: "h", name: "h", .hole(HoleFeature(face: FaceRef(body: "b", face: "b.top"),
                                                                 u: "\((d * top.xAxis).sum())", v: "\((d * top.yAxis).sum())",
                                                                 diameter: diameter, depth: depth)))
        doc.features = [block, hole]
        let drilled = try #require(Regenerator.regenerate(doc).body("b"))
        let wall = try #require(drilled.faceNames.first { $0.hasPrefix("h.hole.wall") })
        #expect(try drilled.faceCylinder(wall).isHole)
        return ([block, hole], FaceRef(body: "b", face: wall))
    }

    /// Whatever the hole was drilled at (the tap drill, the thread's own size, or smaller than its
    /// minor diameter), an M8 thread leaves the same hole: bored to the minor diameter, with the groove.
    @Test(arguments: ["6.8", "8", "6.4"]) func anInternalThreadIsCutIntoAHole(diameter: String) throws {
        let (features, wall) = try Self.drilledBlock(diameter)
        let r = try NewFeatureTests.regen(features + [Self.thread(wall, "M8x1.25")])
        let body = try #require(r.body("b"))
        #expect(body.isValid)
        #expect(body.faceNames.contains { $0.hasPrefix("th.thread") })
        let m8 = ThreadStandard.metric.size("M8x1.25")!
        let removed = 13500 - body.volume
        let expected = .pi * pow(m8.minorDiameter / 2, 2) * 15 + Self.internalGroove(m8, 15)
        #expect(abs(removed - expected) / expected < 0.02, "removed \(removed), expected about \(expected)")
    }

    /// A small blind hole with a drill point, drilled a little wider than the tap drill (the fill
    /// ring and the groove must both make it into the body).
    @Test func aShortBlindHoleGetsItsThread() throws {
        let (features, wall) = try Self.drilledBlock("3", depth: "3")
        var doc = CADDocument()
        doc.features = features
        let drilled = try #require(Regenerator.regenerate(doc).body("b")).volume
        let r = try NewFeatureTests.regen(features + [Self.thread(wall, "M3.5x0.6")])
        let body = try #require(r.body("b"))
        #expect(body.isValid)
        let m = ThreadStandard.metric.size("M3.5x0.6")!
        // Filled from the 3 mm wall in to the minor diameter, less the groove.
        let change = .pi * (1.5 * 1.5 - pow(m.minorDiameter / 2, 2)) * 3 - Self.internalGroove(m, 3)
        #expect(abs((body.volume - drilled) - change) < 0.15 * abs(change), "changed \(body.volume - drilled), expected about \(change)")
    }

    /// A shaft thinner than the thread is filled out to it, a thicker one turned down: the same thread either way.
    @Test(arguments: ["7.6", "8", "8.6"]) func anExternalThreadSizesTheShaft(diameter: String) throws {
        let r = try NewFeatureTests.regen([Self.cylinder("c", d: diameter, h: "12"), Self.thread(FaceRef(body: "c", face: "c.side"), "M8x1.25")])
        let body = try #require(r.body("c"))
        #expect(body.isValid)
        let expected = Self.externalVolume(ThreadStandard.metric.size("M8x1.25")!, 12)
        #expect(abs(body.volume - expected) / expected < 0.02, "volume \(body.volume), expected about \(expected)")
    }

    @Test func aThreadThatDoesNotFitSaysSo() throws {
        var doc = CADDocument()
        doc.features = [Self.cylinder("c", d: "8", h: "20"), Self.thread(FaceRef(body: "c", face: "c.side"), "M20x2.5")]
        let r = Regenerator.regenerate(doc)
        #expect(r.errors["th"]?.contains("doesn't fit") == true, "\(r.errors)")
        doc.features = [NewFeatureTests.box("b", "10", "10", "10"), Self.thread(FaceRef(body: "b", face: "b.top"), "M8x1.25")]
        #expect(Regenerator.regenerate(doc).errors["th"]?.contains("round face") == true)
    }

    /// A block with two holes of one size side by side, and their walls.
    static func twoHoles() throws -> (features: [Feature], walls: [FaceRef]) {
        let block = NewFeatureTests.box("b", "30", "30", "15")
        var doc = CADDocument()
        doc.features = [block]
        let top = try Regenerator.regenerate(doc).body("b")!.faceFrame("b.top")
        let d = SIMD3<Double>(0, 0, 15) - top.origin
        let u = (d * top.xAxis).sum(), v = (d * top.yAxis).sum()
        let holes = [("h1", -8.0), ("h2", 8.0)].map { id, dx in
            Feature(id: id, name: id, .hole(HoleFeature(face: FaceRef(body: "b", face: "b.top"), u: "\(u + dx)", v: "\(v)",
                                                        diameter: "6.8", depth: nil)))
        }
        doc.features = [block] + holes
        let drilled = try #require(Regenerator.regenerate(doc).body("b"))
        let walls = try ["h1", "h2"].map { id in
            FaceRef(body: "b", face: try #require(drilled.faceNames.first { $0.hasPrefix("\(id).hole.wall") }))
        }
        return ([block] + holes, walls)
    }

    @Test func oneThreadCanCutSeveralHoles() throws {
        let (features, walls) = try Self.twoHoles()
        let single = try NewFeatureTests.regen(features + [Self.thread(walls[0], "M8x1.25")])
        let both = Feature(id: "th", name: "th", .thread(ThreadFeature(face: walls[0], moreFaces: [walls[1]], size: "M8x1.25")))
        let r = try NewFeatureTests.regen(features + [both])
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("b"))
        #expect(body.isValid)
        #expect(body.faceNames.contains { $0.hasPrefix("th.thread") } && body.faceNames.contains { $0.hasPrefix("th.2.thread") })
        // Each hole is bored out and grooved the same way, so the second one removes as much as the first.
        let drilled = try #require(NewFeatureTests.regen(features).body("b")).volume
        let first = drilled - (try #require(single.body("b"))).volume
        let total = drilled - body.volume
        #expect(first > 0 && abs(total - 2 * first) / (2 * first) < 0.02, "one hole \(first), both \(total)")
    }

    @Test func threadsFromBeforeSeveralFacesStillOpen() throws {
        // A file from before the key existed: the same thing without `moreFaces`.
        let face = FaceRef(body: "b", face: "b.side")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ThreadFeature(face: face))) as? [String: Any])
        #expect(json.removeValue(forKey: "moreFaces") != nil)
        let t = try JSONDecoder().decode(ThreadFeature.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(t.faces == [FaceRef(body: "b", face: "b.side")])
        let again = try JSONDecoder().decode(ThreadFeature.self, from: try JSONEncoder().encode(t))
        #expect(again == t)
    }
}

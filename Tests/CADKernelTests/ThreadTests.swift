// Threads: sizes from the tables, and threads cut into shafts and holes through the regenerator.
// Copyright © 2026 Atle Mo. All rights reserved.
@testable import CADCore
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
                       leftHanded: Bool = false, tolerance: String? = nil,
                       unit: ThreadToleranceUnit = .percent) -> Feature {
        Feature(id: "th", name: "th", .thread(ThreadFeature(face: face, standard: standard, size: size, length: length,
                                                            leftHanded: leftHanded, tolerance: tolerance, toleranceUnit: unit)))
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

    /// A blind hole drilled at exactly the thread's major diameter puts the edge where its wall meets the
    /// drill point on the groove's outer edge: the thread used to come out an invalid solid.
    @Test(arguments: [("M18x2.5", ThreadStandard.metric), ("M18x1.5", .metricFine)])
    func aBlindHoleAtTheMajorDiameterGetsItsThread(size: String, standard: ThreadStandard) throws {
        var s = Sketch()
        let c = s.addPoint(0, 0)
        s.constrain(.fix(c, x: 0, y: 0))
        _ = s.addCircle(center: c, radius: 31.6)
        var doc = CADDocument()
        doc.features = [Feature(id: "sk", name: "sk", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let region = try #require(Regenerator.regenerate(doc).sketches["sk"]?.regions.first)
        var extrude = ExtrudeFeature(
            sketch: "sk", profiles: [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)],
            extent: .distance("30 mm"))
        extrude.taper = "-14 deg"
        doc.features.append(Feature(id: "b", name: "b", .extrude(extrude)))
        doc.features.append(Feature(id: "h", name: "h", .hole(HoleFeature(face: FaceRef(body: "b", face: "b.end"), u: "0 mm", v: "0 mm",
                                                                        diameter: "18 mm", depth: "18 mm"))))
        doc.features.append(Self.thread(FaceRef(body: "b", face: "h.hole.wall"), size, standard))
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(try #require(r.body("b")).isValid)
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

    @Test func aThreadThatFailsSuggestsSizesThatWork() throws {
        var doc = CADDocument()
        doc.features = [Self.cylinder("c", d: "8", h: "20"), Self.thread(FaceRef(body: "c", face: "c.side"), "M20x2.5")]
        let message = try #require(Regenerator.regenerate(doc).errors["th"])
        #expect(message.contains("doesn't fit") && message.contains("Sizes that work on this face: M8"), "\(message)")
        // Each one it names does build.
        let listed = try #require(message.components(separatedBy: "work on this face: ").last)
        let first = try #require(listed.split(separator: ",").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " .")) })
        let size = try #require(ThreadStandard.metric.sizes.first { $0.label(.metric) == first })
        doc.features[1] = Self.thread(FaceRef(body: "c", face: "c.side"), size.name)
        #expect(Regenerator.regenerate(doc).errors.isEmpty)
        // A face that isn't round has nothing to suggest.
        doc.features = [NewFeatureTests.box("b", "10", "10", "10"), Self.thread(FaceRef(body: "b", face: "b.top"), "M8x1.25")]
        #expect(Regenerator.regenerate(doc).errors["th"]?.contains("Sizes that work") == false)
    }

    /// The viewport asks for a fillet's drag handle on every frame; on a threaded body each answer is a point-in-solid test
    /// against the helical faces, so a body remembers it.
    @Test func aThreadedBodyAnswersAnEdgeHandleOnceNotEveryFrame() throws {
        let (features, wall) = try Self.drilledBlock("6.8")
        let body = try #require(NewFeatureTests.regen(features + [Self.thread(wall, "M8x1.25")]).body("b"))
        let edge = "b.left|b.top"
        let first = try body.edgeHandle(edge)
        let start = Date()
        for _ in 0..<300 {
            let again = try body.edgeHandle(edge)
            #expect(again.origin == first.origin && again.direction == first.direction)
        }
        #expect(Date().timeIntervalSince(start) < 0.2, "300 lookups took \(Date().timeIntervalSince(start)) s")
    }

    @Test func aDraftLeavesOutTheThreadsAfterTheEditedFeatureAndKeepsItsResultsApart() throws {
        let (features, wall) = try Self.drilledBlock("6.8")
        let all = features + [Self.thread(wall, "M8x1.25")]
        var doc = CADDocument()
        doc.features = all
        let cache = RegenCache()
        func threaded(_ r: RegenResult) -> Bool { r.body("b")?.faceNames.contains { $0.hasPrefix("th.thread") } == true }

        let full = Regenerator.regenerate(doc, cache: cache)
        #expect(threaded(full) && full.errors.isEmpty)
        // Edited feature = the block (first): the thread after it is left out, and nothing breaks.
        let start = Date()
        let draft = Regenerator.regenerate(doc, cache: cache, draftAfter: "b")
        let took = Date().timeIntervalSince(start)
        #expect(!threaded(draft) && draft.errors.isEmpty && draft.body("b")?.isValid == true)
        let plainVolume = try #require(draft.body("b")).volume, threadedVolume = try #require(full.body("b")).volume
        #expect(plainVolume > threadedVolume, "the hole is still the plain drilled one")
        #expect(took < 0.05, "a draft rebuild took \(took) s")
        // The rebuild that follows is the whole thing again, not the draft out of the cache.
        let after = Regenerator.regenerate(doc, cache: cache)
        #expect(threaded(after) && after.errors.isEmpty)
        // A thread at or before the edited feature is built: the thread itself being dragged.
        #expect(threaded(Regenerator.regenerate(doc, cache: cache, draftAfter: "th")))
        // Edited at the hole, which is also before the thread: left out again.
        #expect(!threaded(Regenerator.regenerate(doc, cache: RegenCache(), draftAfter: "h")))
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

    /// The same M8 thread on a shaft, modeled at `grow` mm larger than nominal.
    static func grown(_ grow: Double) -> Double {
        let m8 = ThreadStandard.metric.size("M8x1.25")!
        return externalVolume(ThreadSize(name: m8.name, diameter: m8.diameter + grow, pitch: m8.pitch), 12)
    }

    @Test(arguments: [("2", ThreadToleranceUnit.percent, 0.16), ("0.2", .distance, 0.2), ("-0.1", .distance, -0.1)])
    func aToleranceOffsetResizesTheThread(value: String, unit: ThreadToleranceUnit, grow: Double) throws {
        // The shaft is the thread's own size, so the offset is the only thing that changes it.
        let r = try NewFeatureTests.regen([Self.cylinder("c", d: "8", h: "12"),
                                           Self.thread(FaceRef(body: "c", face: "c.side"), "M8x1.25", tolerance: value, unit: unit)])
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("c"))
        #expect(body.isValid)
        let expected = Self.grown(grow)
        #expect(abs(body.volume - expected) / expected < 0.02, "volume \(body.volume), expected about \(expected)")
    }

    @Test func aHoleThreadWithAnOffsetIsBoredLarger() throws {
        let (features, wall) = try Self.drilledBlock("6.8")
        let plain = try #require(NewFeatureTests.regen(features + [Self.thread(wall, "M8x1.25")]).body("b")).volume
        let loose = try #require(NewFeatureTests.regen(features + [Self.thread(wall, "M8x1.25", tolerance: "0.2", unit: .distance)]).body("b"))
        #expect(loose.isValid)
        #expect(loose.volume < plain - 5, "a larger hole leaves less material: \(loose.volume) against \(plain)")
    }

    @Test func presetsAndOldFilesAndParameters() throws {
        #expect(ThreadMaterial.allCases.map(\.percent) == [1, 2, 1.5, 3])
        // A file from before the offset has neither key.
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ThreadFeature(face: FaceRef(body: "b", face: "b.side"), tolerance: "2"))) as? [String: Any])
        #expect(json.removeValue(forKey: "tolerance") != nil && json.removeValue(forKey: "toleranceUnit") != nil)
        let old = try JSONDecoder().decode(ThreadFeature.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.tolerance == nil && old.toleranceUnit == .percent && old.toleranceMaterial == nil)
        // The chosen material survives a save.
        let petg = ThreadFeature(face: old.face, tolerance: "1", toleranceMaterial: .petg)
        #expect(try JSONDecoder().decode(ThreadFeature.self, from: JSONEncoder().encode(petg)).toleranceMaterial == .petg)
        // The offset is an expression, so it can use a parameter.
        var doc = CADDocument()
        doc.parameters = [Parameter("slop", "0.15 mm")]
        let size = ThreadStandard.metric.size("M5x0.8")!
        let t = ThreadFeature(face: FaceRef(body: "b", face: "b.side"), size: "M5x0.8", tolerance: "slop", toleranceUnit: .distance)
        #expect(abs(try t.modeledDiameter(of: size, ParameterEvaluator.evaluate(doc.parameters)) - 5.15) < 1e-9)
        #expect(abs(try ThreadFeature(face: t.face, tolerance: "2").modeledDiameter(of: size, ParameterValues()) - 5.1) < 1e-9)
    }
}

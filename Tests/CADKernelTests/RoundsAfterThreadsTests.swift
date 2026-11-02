// Rounds and cuts after threads: a body with threads has hundreds of helical faces, and the checks that follow a chamfer
// or a cut must not integrate over every one of them, nor decide anything differently than on a body without threads.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CKernel
@testable import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct RoundsAfterThreadsTests {
    /// The 60 × 30 × 15 block with four holes, as features: drilled only, and drilled and threaded.
    static func features() throws -> (plain: [Feature], threaded: [Feature]) {
        let (drilled, walls) = try ThreadTogetherTests.block(holes: [("6.8", -24), ("5", -8), ("4.2", 8), ("6.8", 24)])
        let thread = Feature(id: "th", name: "th", .thread(ThreadFeature(
            face: walls[0], moreFaces: Array(walls.dropFirst()),
            moreSpecs: [ThreadSpec(standard: .metric, size: "M6x1"), ThreadSpec(standard: .metric, size: "M5x0.8"),
                        ThreadSpec(standard: .metric, size: "M8x1.25")], size: "M8x1.25")))
        return (drilled, drilled + [thread])
    }

    static func body(_ features: [Feature]) throws -> KBody { try #require(NewFeatureTests.regen(features).body("b")) }

    /// The four edges round the top of the block itself (not the holes').
    static func outerTopEdges(_ body: KBody) throws -> [String] {
        let edges = try body.faceEdges("b.top").filter { $0.split(separator: "|").allSatisfy { $0.hasPrefix("b.") } }
        #expect(edges.count == 4, "\(edges)")
        return edges
    }

    @Test func aChamferTakesAsMuchOffAThreadedBodyAsOffAPlainOne() throws {
        let (plain, threaded) = try (Self.body(Self.features().plain), Self.body(Self.features().threaded))
        #expect(threaded.faceNames.count > 200 && plain.faceNames.count < 20, "the threads give the body hundreds of faces: \(threaded.faceNames.count)")
        var removed: [Double] = []
        for body in [plain, threaded] {
            let edges = try Self.outerTopEdges(body)
            let made = try body.chamfer(edges: edges, distance: 1.5, featureID: "c")
            #expect(made.isValid)
            removed.append(body.volume - made.volume)
        }
        #expect(removed[0] > 100 && abs(removed[0] - removed[1]) < 1e-6 * plain.volume, "\(removed)")
    }

    @Test func aFilletTakesAsMuchOffAThreadedBodyAsOffAPlainOne() throws {
        let (plain, threaded) = try (Self.body(Self.features().plain), Self.body(Self.features().threaded))
        var removed: [Double] = []
        for body in [plain, threaded] {
            let made = try body.fillet(edges: try Self.outerTopEdges(body), radius: 2, featureID: "f")
            #expect(made.isValid)
            removed.append(body.volume - made.volume)
        }
        #expect(removed[0] > 10 && abs(removed[0] - removed[1]) < 1e-6 * plain.volume, "\(removed)")
    }

    @Test func aRoundTooBigForTheBodyFailsOnAThreadedBodyAsOnAPlainOne() throws {
        // A chamfer taller than the side it is cut into.
        for features in [try Self.features().plain, try Self.features().threaded] {
            let body = try Self.body(features)
            let edges = try Self.outerTopEdges(body)
            #expect(throws: KernelError.self) { try body.chamfer(edges: edges, distance: 20, featureID: "c") }
        }
    }

    // MARK: nothing left

    private func box(_ id: FeatureID, _ size: String, u: String = "0 mm") -> Feature {
        NewFeatureTests.box(id, u: u, size, size, size)
    }

    @Test func aBodyIsEmptyWhenNothingIsLeftOfIt() throws {
        let plain = try Self.body(Self.features().plain)
        #expect(!plain.isEmpty)
        let cutter = try #require(NewFeatureTests.regen([box("a", "10 mm"), box("k", "50 mm")]).body("a"))
        let big = try #require(NewFeatureTests.regen([box("a", "10 mm"), box("k", "50 mm")]).body("k"))
        #expect(try cutter.boolean(big, SK_CUT).isEmpty)
        #expect(try big.boolean(cutter, SK_CUT).isEmpty == false)
        let far = try #require(NewFeatureTests.regen([box("a", "10 mm"), box("far", "10 mm", u: "100 mm")]).body("far"))
        #expect(try cutter.boolean(far, SK_COMMON).isEmpty)
    }

    @Test(arguments: [false, true])
    func aCutThatRemovesEverythingOrMeetsNothingIsAnErrorWhateverTheBodyHas(threaded: Bool) throws {
        let features = try threaded ? Self.features().threaded : Self.features().plain
        // The block is 60 × 30 × 15 and stands on z = 0, centred on x and y.
        let everything = NewFeatureTests.box("all", "200", "200", "200")
        var doc = CADDocument()
        doc.features = features + [everything, Feature(id: "c", name: "Combine1", .combine(CombineFeature(target: "b", tools: ["all"], operation: .cut)))]
        let gone = Regenerator.regenerate(doc)
        #expect(gone.errors["c"]?.contains("removes the whole body") == true, "\(gone.errors)")

        let away = NewFeatureTests.box("away", u: "500 mm", "10", "10", "10")
        var apart = CADDocument()
        apart.features = features + [away, Feature(id: "c", name: "Combine1", .combine(CombineFeature(target: "b", tools: ["away"], operation: .intersect)))]
        #expect(Regenerator.regenerate(apart).errors["c"]?.contains("don't overlap") == true)

        // Part of it cut away is not nothing.
        let corner = NewFeatureTests.box("corner", u: "-30 mm", "20", "20", "30")
        var partly = CADDocument()
        partly.features = features + [corner, Feature(id: "c", name: "Combine1", .combine(CombineFeature(target: "b", tools: ["corner"], operation: .cut)))]
        let part = Regenerator.regenerate(partly)
        #expect(part.errors.isEmpty, "\(part.errors)")
        #expect(try #require(part.body("b")).volume < (try Self.body(features)).volume)
    }
}

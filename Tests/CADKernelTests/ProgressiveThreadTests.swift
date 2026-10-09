// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// A rebuild that will be followed by a full one can leave out the threads it would have to build.
@Suite struct ProgressiveThreadTests {
    /// A box whose width is a parameter, with a drilled hole and a thread in it.
    static func threadedBox(width: String = "30 mm") throws -> CADDocument {
        let block = Feature(id: "b", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "w", length: "30 mm", height: "15 mm")))
        var doc = CADDocument(parameters: [Parameter("w", width), Parameter("unused", "1 mm")])
        doc.features = [block]
        let top = try #require(Regenerator.regenerate(doc).body("b")).faceFrame("b.top")
        let d = SIMD3<Double>(0, 0, 15) - top.origin
        let hole = Feature(id: "h", name: "Hole", .hole(HoleFeature(face: FaceRef(body: "b", face: "b.top"),
                                                                    u: "\((d * top.xAxis).sum())", v: "\((d * top.yAxis).sum())",
                                                                    diameter: "6.8", depth: nil)))
        doc.features = [block, hole]
        let wall = try #require(Regenerator.regenerate(doc).body("b")?.faceNames.first { $0.hasPrefix("h.hole.wall") })
        doc.features.append(Feature(id: "th", name: "Thread", .thread(ThreadFeature(face: FaceRef(body: "b", face: wall), size: "M8x1.25"))))
        return doc
    }

    private func hasThread(_ r: RegenResult) -> Bool { r.body("b")?.faceNames.contains { $0.hasPrefix("th.thread") } == true }

    @Test func onlyThreadsThatHaveToBeBuiltAreLeftOut() throws {
        let cache = RegenCache()
        var doc = try Self.threadedBox()
        let first = Regenerator.regenerate(doc, cache: cache, progressiveThreads: 0)  // nothing built yet: the thread is left out
        #expect(first.threadsLeftOut == 1 && !hasThread(first) && first.errors.isEmpty)
        let full = Regenerator.regenerate(doc, cache: cache)
        #expect(full.threadsLeftOut == 0 && hasThread(full) && full.errors.isEmpty)

        // Nothing changed, or something the thread doesn't see: it is kept.
        #expect(Regenerator.regenerate(doc, cache: cache, progressiveThreads: 0).threadsLeftOut == 0)
        doc.parameters[1].expression = "2 mm"
        let same = Regenerator.regenerate(doc, cache: cache, progressiveThreads: 0)
        #expect(same.threadsLeftOut == 0 && hasThread(same))

        // The box changes: the thread is built again, so it waits for the full rebuild.
        doc.parameters[0].expression = "34 mm"
        let draft = Regenerator.regenerate(doc, cache: cache, progressiveThreads: 0)
        #expect(draft.threadsLeftOut == 1 && !hasThread(draft) && draft.errors.isEmpty)
        let wider = try #require(draft.body("b")).volume
        let after = Regenerator.regenerate(doc, cache: cache)
        #expect(after.threadsLeftOut == 0 && hasThread(after) && after.errors.isEmpty)
        let fresh = Regenerator.regenerate(doc)
        #expect(abs(try #require(after.body("b")).volume - (try #require(fresh.body("b")).volume)) < 1e-6)
        #expect(wider > (try #require(after.body("b")).volume))  // a plain hole has more material than a threaded one
    }

    @Test func aThreadThatIsQuickToBuildIsNotLeftOut() throws {
        let cache = RegenCache()
        var doc = try Self.threadedBox()
        _ = Regenerator.regenerate(doc, cache: cache)  // the thread's cost is now known: well under a minute
        doc.parameters[0].expression = "34 mm"
        let r = Regenerator.regenerate(doc, cache: cache, progressiveThreads: 60)
        #expect(r.threadsLeftOut == 0 && hasThread(r))
    }
}

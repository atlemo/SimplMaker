// Sketches of hundreds of curves: the cursor-move and per-frame work stays fast, and gives the answers it always did.
// Copyright © 2026 Atle Mo. All rights reserved.
@testable import CADCore
import Foundation
import Testing

@Suite struct SketchScaleTests {
    /// A wall of small squares, circles, an arc and a spline: `n` shapes of each kind.
    static func busy(_ n: Int) -> Sketch {
        var s = Sketch()
        for i in 0..<n { _ = s.addRectangle(Double(i % 25) * 4, Double(i / 25) * 4, Double(i % 25) * 4 + 2.5, Double(i / 25) * 4 + 2.5) }
        for i in 0..<n {
            let c = s.addPoint(200 + Double(i % 20) * 5, Double(i / 20) * 5)
            _ = s.addCircle(center: c, radius: 1.5)
        }
        return s
    }

    @Test func chainsFollowOpenAndClosedRuns() throws {
        var s = Sketch()
        let p = (0..<7).map { s.addPoint(Double($0), 0) }
        // An open run of three lines, drawn out of order and one backwards; a closed triangle; a lone line.
        let l1 = s.addLine(p[0], p[1]), l3 = s.addLine(p[3], p[2]), l2 = s.addLine(p[1], p[2])
        let q = (0..<3).map { s.addPoint(Double($0), 5) }
        let t1 = s.addLine(q[0], q[1]), t2 = s.addLine(q[1], q[2]), t3 = s.addLine(q[2], q[0])
        let lone = s.addLine(p[5], p[6])
        let result = s.chains([l1, l3, l2, t1, t2, t3, lone])
        #expect(result.count == 3)
        let open = try #require(result.first { $0.items.first?.id == l1 })
        #expect(open.items.map(\.id) == [l1, l2, l3] && open.items.map(\.reversed) == [false, false, true] && !open.closed)
        let triangle = try #require(result.first { $0.items.first?.id == t1 })
        #expect(triangle.items.map(\.id) == [t1, t2, t3] && triangle.closed)
        #expect(result.contains { $0.items.map(\.id) == [lone] && !$0.closed })
    }


    /// The first version of `chains`, which looked everything up by scanning: the answers the fast one must keep giving.
    static func referenceChains(_ s: Sketch, _ ids: [EntityID]) -> [(items: [(id: EntityID, reversed: Bool)], closed: Bool)] {
        func ends(_ id: EntityID) -> (EntityID, EntityID)? {
            guard let c = s.curve(id) else { return nil }
            switch c.geometry {
            case .line(let a, let b): return (a, b)
            case .arc(_, let a, let b): return (a, b)
            case .bezier(let a, _, _, let b): return (a, b)
            case .circle: return nil
            }
        }
        var remaining = ids.filter { ends($0) != nil }
        var result: [(items: [(id: EntityID, reversed: Bool)], closed: Bool)] = []
        func degree(_ p: EntityID) -> Int { remaining.filter { let e = ends($0)!; return e.0 == p || e.1 == p }.count }
        while !remaining.isEmpty {
            let startID = remaining.first { let e = ends($0)!; return degree(e.0) == 1 || degree(e.1) == 1 } ?? remaining[0]
            let e0 = ends(startID)!
            var chain: [(id: EntityID, reversed: Bool)] = [(startID, degree(e0.0) != 1 && degree(e0.1) == 1)]
            remaining.removeAll { $0 == startID }
            var tip = chain[0].reversed ? e0.0 : e0.1
            let first = chain[0].reversed ? e0.1 : e0.0
            while let next = remaining.first(where: { let e = ends($0)!; return e.0 == tip || e.1 == tip }) {
                let e = ends(next)!
                let rev = e.1 == tip
                chain.append((next, rev))
                tip = rev ? e.0 : e.1
                remaining.removeAll { $0 == next }
            }
            result.append((chain, tip == first && chain.count > 1))
        }
        return result
    }

    @Test func chainsGiveTheSameAnswersAsTheFirstVersion() {
        var rng = SystemRandomNumberGenerator()
        for round in 0..<300 {
            var s = Sketch()
            let pointCount = Int.random(in: 3...14, using: &rng)
            let pts = (0..<pointCount).map { s.addPoint(Double($0), Double(round)) }
            var ids: [EntityID] = []
            for _ in 0..<Int.random(in: 1...22, using: &rng) {
                let a = pts.randomElement(using: &rng)!, b = pts.randomElement(using: &rng)!
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: ids.append(s.addCircle(center: a, radius: 1))
                case 1: ids.append(s.addArc(center: pts.randomElement(using: &rng)!, start: a, end: b))
                case 2: ids.append(s.addBezier(start: a, control1: pts.randomElement(using: &rng)!, control2: pts.randomElement(using: &rng)!, end: b))
                default: ids.append(s.addLine(a, b))  // loops (a == b) and doubled lines included
                }
            }
            ids.shuffle(using: &rng)
            let a = s.chains(ids), b = Self.referenceChains(s, ids)
            #expect(a.count == b.count && zip(a, b).allSatisfy { $0.closed == $1.closed && $0.items.map(\.id) == $1.items.map(\.id)
                && $0.items.map(\.reversed) == $1.items.map(\.reversed) }, "round \(round)")
        }
    }

    @Test func chainsStartAtAnOpenEndAndSkipCircles() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(1, 0), c = s.addPoint(2, 0)
        let circle = s.addCircle(center: a, radius: 1)
        let l2 = s.addLine(b, c), l1 = s.addLine(a, b)
        // Given l2 first, the run starts there (its end c is open) and walks back to a.
        let result = s.chains([circle, l2, l1])
        #expect(result.count == 1)
        #expect(result[0].items.map(\.id) == [l2, l1] && result[0].items.map(\.reversed) == [true, true] && !result[0].closed)
    }

    @Test func sizeSuggestionsMatchSuggestDimension() throws {
        var s = Self.busy(6)
        // A line with a point constrained onto it (measured corner to corner), an arc, a spline.
        let a = s.addPoint(0, 50), b = s.addPoint(10, 50), mid = s.addPoint(4, 50.0), far = s.addPoint(14, 50)
        let line = s.addLine(a, b)
        s.constrain(.pointOnCurve(point: mid, curve: line))
        s.constrain(.pointOnCurve(point: far, curve: line))
        let c = s.addPoint(0, 70), st = s.addPoint(5, 70), en = s.addPoint(0, 75)
        let arc = s.addArc(center: c, start: st, end: en)
        let c1 = s.addPoint(20, 60), c2 = s.addPoint(25, 65)
        _ = s.addBezier(start: s.addPoint(18, 60), control1: c1, control2: c2, end: s.addPoint(30, 60))
        let all = s.sizeSuggestions()
        for curve in s.curves {
            let one = s.suggestDimension(for: [curve.id])
            let batch = all[curve.id]
            #expect((one == nil) == (batch == nil), "\(curve.id)")
            if let one, let batch { #expect(one.kind == batch.kind && abs(one.value - batch.value) < 1e-12, "\(curve.id)") }
        }
        #expect(all[arc] != nil && all[line] != nil)
    }

    @Test func aBusySketchChainsAndFindsShapeCentresQuickly() throws {
        let s = Self.busy(150)  // 600 lines and 150 circles
        var start = Date()
        let centers = s.shapeCenters()
        let took = Date().timeIntervalSince(start)
        #expect(centers.count == 150)
        #expect(took < 1.0, "shapeCenters took \(took) s")
        start = Date()
        let suggestions = s.sizeSuggestions()
        #expect(suggestions.count == 750)
        #expect(Date().timeIntervalSince(start) < 1.0, "sizeSuggestions took \(Date().timeIntervalSince(start)) s")
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

func approxLine(_ g: CurveGeometry?, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
    guard case .line(let p, let q)? = g else { return false }
    return vlen(p - a) < 1e-9 && vlen(q - b) < 1e-9
}

@Suite struct SketchModifyTests {
    /// A horizontal line crossed by two vertical lines at x = 10 and x = 20.
    func crossed() -> (Sketch, line: EntityID) {
        var s = Sketch()
        let line = s.addLine(s.addPoint(0, 0), s.addPoint(30, 0))
        s.addLine(s.addPoint(10, -5), s.addPoint(10, 5))
        s.addLine(s.addPoint(20, -5), s.addPoint(20, 5))
        return (s, line)
    }

    @Test func intersections() {
        #expect(intersect(.line(SIMD2(0, 0), SIMD2(1, 0)), .line(SIMD2(5, -1), SIMD2(5, 1))).map { vlen($0 - SIMD2(5, 0)) < 1e-12 } == [true])
        #expect(intersect(.line(SIMD2(-10, 0), SIMD2(10, 0)), .circle(center: .zero, radius: 5)).count == 2)
        #expect(intersect(.circle(center: .zero, radius: 5), .circle(center: SIMD2(8, 0), radius: 5)).count == 2)
        #expect(intersect(.circle(center: .zero, radius: 1), .circle(center: SIMD2(8, 0), radius: 1)).isEmpty)
    }

    @Test func trimEndPiece() {
        var (s, line) = crossed()
        let r1 = s.trim(line, at: SIMD2(3, 0))
        #expect(r1)
        let g = s.geometry(of: line)!
        #expect(approxLine(g, SIMD2(10, 0), SIMD2(30, 0)))
        let start = s.pointIDs(of: s.curve(line)!)[0]
        #expect(s.constraints.contains { if case .pointOnCurve(start, _) = $0.kind { return true }; return false })
        #expect(s.points.count == 1 + 6)  // origin, 4 vertical-line ends, new start, old end (old start removed)
    }

    @Test func trimMiddleSplits() {
        var (s, line) = crossed()
        let r2 = s.trim(line, at: SIMD2(15, 0))
        #expect(r2)
        #expect(s.curves.count == 4)
        #expect(approxLine(s.geometry(of: line), SIMD2(0, 0), SIMD2(10, 0)))
        let second = s.curves.last!.id
        #expect(approxLine(s.geometry(of: second), SIMD2(20, 0), SIMD2(30, 0)))
        #expect(s.constraints.contains { $0.kind == .parallel(line, second) })
        var solved = s
        let solveResult1 = SketchSolver.solve(&solved, dimensionValues: [:])
        #expect(solveResult1.status == .solved)
    }

    @Test func trimUncrossedCurveDeletesIt() {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(0, 0), radius: 3)
        let r3 = s.trim(c, at: SIMD2(3, 0))
        #expect(r3)
        #expect(s.curves.isEmpty)
    }

    @Test func trimCircleLeavesArc() {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(0, 0), radius: 5)
        s.addLine(s.addPoint(-10, 0), s.addPoint(10, 0))
        let r4 = s.trim(c, at: SIMD2(0, 5))
        #expect(r4)  // remove the top half
        guard case .arc(_, let r, let a0, let sweep)? = s.geometry(of: c) else { Issue.record("not an arc"); return }
        #expect(abs(r - 5) < 1e-9 && abs(sweep - .pi) < 1e-9)
        #expect(abs(a0 - .pi) < 1e-9)  // from the left crossing, counter-clockwise through the bottom
    }

    @Test func extendLineToCurve() {
        var s = Sketch()
        let line = s.addLine(s.addPoint(0, 0), s.addPoint(5, 0))
        s.addLine(s.addPoint(12, -5), s.addPoint(12, 5))
        let r5 = s.extend(line, near: SIMD2(4.9, 0))
        #expect(r5)
        #expect(approxLine(s.geometry(of: line), SIMD2(0, 0), SIMD2(12, 0)))
        var solved = s
        let solveResult2 = SketchSolver.solve(&solved, dimensionValues: [:])
        #expect(solveResult2.status == .solved)
        let r6 = s.extend(line, near: SIMD2(0, 0))
        #expect(!r6)  // nothing behind the start
    }

    @Test func offsetClosedRectangleOutward() {
        var s = Sketch()
        let rect = s.addRectangle(0, 0, 20, 10)
        let created = s.offset(rect.lines, distance: 2, expression: "2 mm")
        #expect(created.count == 4)
        let xs = created.compactMap { s.geometry(of: $0) }.flatMap { g -> [Double] in
            if case .line(let a, let b) = g { return [a.x, b.x] } else { return [] }
        }
        #expect(abs(xs.min()! + 2) < 1e-9 && abs(xs.max()! - 22) < 1e-9)  // outward on both sides
        #expect(s.dimensions.count == 4)
        let values = Dictionary(uniqueKeysWithValues: s.dimensions.map { ($0.id, 2.0) })
        var solved = s
        let r = SketchSolver.solve(&solved, dimensionValues: values)
        #expect(r.status == .solved)
    }

    @Test func offsetCircleIsConcentric() {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(0, 0), radius: 5)
        let created = s.offset([c], distance: -1, expression: "1 mm")
        #expect(created.count == 1)
        #expect(abs(s.radius(of: s.curve(created[0])!)! - 4) < 1e-12)
        #expect(abs(s.measure(.radialOffset(from: c, to: created[0]))! - 1) < 1e-12)
    }

    @Test func filletCornerMakesTangentArc() throws {
        var s = Sketch()
        let corner = s.addPoint(10, 0)
        let l1 = s.addLine(s.addPoint(0, 0), corner)
        let l2 = s.addLine(corner, s.addPoint(10, 10))
        let r7 = s.filletCorner(corner, radius: 2, expression: "2 mm")
        let dim = try #require(r7)
        let arc = try #require(s.curves.first { if case .arc = $0.geometry { return true }; return false })
        #expect(s.radius(of: arc).map { abs($0 - 2) < 1e-9 } == true)
        #expect(approxLine(s.geometry(of: l1), SIMD2(0, 0), SIMD2(8, 0)))
        #expect(approxLine(s.geometry(of: l2), SIMD2(10, 2), SIMD2(10, 10)))
        guard case .arc(let c, _, _, let sweep)? = s.geometry(of: arc.id) else { Issue.record("no arc"); return }
        #expect(vlen(c - SIMD2(8, 2)) < 1e-9 && abs(sweep - .pi / 2) < 1e-9)
        #expect(s.point(corner) != nil)  // virtual sharp stays
        var solved = s
        let solveResult3 = SketchSolver.solve(&solved, dimensionValues: [dim: 3])
        #expect(solveResult3.status == .solved)
        let r = solved.radius(of: solved.curve(arc.id)!)!
        #expect(abs(r - 3) < 1e-6)
        let r8 = s.filletCorner(corner, radius: 50, expression: "50 mm")
        #expect(r8 == nil)  // corner no longer shared
    }
}

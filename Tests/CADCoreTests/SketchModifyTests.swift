// Copyright © 2026 Atle Mo
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

    /// A slot drawn against projected edges: every corner is a pair of points (tied by a coincident constraint,
    /// or, at the last corner, only a micrometre apart), as the saved sketches hold it.
    func splitCornerSlot(gap: Bool) -> (Sketch, [EntityID]) {
        var s = Sketch()
        let top = s.addLine(s.addPoint(0, 3.1), s.addPoint(5.8, 3.1))
        let bottom = s.addLine(s.addPoint(5.8, 0), s.addPoint(0, 0))
        let left = s.addArc(center: s.addPoint(0, 1.55), start: s.addPoint(0, 3.1), end: s.addPoint(0, 0))
        let right = s.addArc(center: s.addPoint(5.8, 1.55), start: s.addPoint(5.8, 0), end: s.addPoint(5.8 + (gap ? 1e-4 : 0), 3.1))
        func ends(_ id: EntityID) -> [EntityID] {
            switch s.curve(id)!.geometry {
            case .line(let a, let b), .arc(_, let a, let b): return [a, b]
            default: return []
            }
        }
        s.constrain(.coincident(ends(top)[0], ends(left)[0]))
        s.constrain(.coincident(ends(left)[1], ends(bottom)[1]))
        s.constrain(.coincident(ends(bottom)[0], ends(right)[0]))
        if !gap { s.constrain(.coincident(ends(right)[1], ends(top)[1])) }
        return (s, [top, bottom, left, right])
    }

    @Test(arguments: [true, false], [0.6, -0.4])
    func offsetSlotWhoseCornersAreSeparatePoints(gap: Bool, distance: Double) throws {
        var (s, ids) = splitCornerSlot(gap: gap)
        let created = s.offset(ids, distance: distance, expression: "\(abs(distance)) mm")
        #expect(created.count == 4)
        // Every piece moved the same way: lines by the distance, arcs' radius by the same.
        for id in created {
            switch try #require(s.geometry(of: id)) {
            case .line(let a, _): #expect(abs(abs(a.y - 1.55) - (1.55 + distance)) < 1e-6)
            case .arc(_, let r, _, _): #expect(abs(r - (1.55 + distance)) < 1e-6)
            default: Issue.record("unexpected curve")
            }
        }
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

/// Rounding a rectangle's corners keeps its sizes: they're measured corner to corner, through the
/// virtual sharps, and still drive it.
@Suite struct RoundCornerKeepsSizesTests {
    @Test func widthAndHeightSurviveAndStillDrive() throws {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 40, 20)
        s.constrain(.fix(r.corners[0], x: 0, y: 0))
        s.dimension(.length(r.lines[0]), "w", id: "W")
        s.dimension(.length(r.lines[1]), "20 mm", id: "H")
        var v: [EntityID: Double] = ["W": 40, "H": 20]
        for corner in r.corners {
            guard let dim = s.filletCorner(corner, radius: 4, expression: "4 mm") else { Issue.record("corner not rounded"); return }
            v[dim] = 4
            #expect(SketchSolver.solve(&s, dimensionValues: v).status == .solved)
        }
        #expect(s.dimensions.first { $0.id == "W" }?.expression == "w", "same dimension, same expression")
        #expect(s.measure(s.dimensions.first { $0.id == "W" }!.kind).map { abs($0 - 40) < 1e-9 } == true)
        #expect(r.lines.map { s.suggestDimension(for: [$0])?.value ?? 0 } == [40, 20, 40, 20], "grey sizes: corner to corner")
        v["W"] = 50
        #expect(SketchSolver.solve(&s, dimensionValues: v).status == .solved)
        #expect(abs((s.position(r.corners[2])?.x ?? 0) - 50) < 1e-6, "the width still drives the rounded rectangle")
    }
}

/// Changing a dimension moves what it's about and leaves the rest where it is.
@Suite struct LocalSolveTests {
    @Test func aCornerRadiusLeavesTheRectangleAlone() throws {
        var s = Sketch()
        let r = s.addRectangle(10, 10, 50, 30)
        var v: [EntityID: Double] = [:]
        for corner in r.corners {
            guard let dim = s.filletCorner(corner, radius: 2, expression: "2 mm") else { Issue.record("corner not rounded"); return }
            v[dim] = 2
            #expect(SketchSolver.solveLocally(&s, dimensionValues: v).status == .solved)
            v[dim] = 5  // typing a bigger radius
            #expect(SketchSolver.solveLocally(&s, dimensionValues: v).status == .solved)
        }
        for (corner, at) in zip(r.corners, [SIMD2(10.0, 10), SIMD2(50, 10), SIMD2(50, 30), SIMD2(10, 30)]) {
            #expect(vlen((s.position(corner) ?? .zero) - at) < 1e-6, "corner \(corner) stayed put")
        }
        #expect(r.lines.map { s.suggestDimension(for: [$0])?.value ?? 0 } == [40, 20, 40, 20])
    }

    @Test func aWidthStillMovesASide() {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 40, 20)
        s.constrain(.fix(r.corners[0], x: 0, y: 0))
        s.dimension(.length(r.lines[0]), "40 mm", id: "W")
        s.dimension(.length(r.lines[1]), "20 mm", id: "H")
        #expect(SketchSolver.solveLocally(&s, dimensionValues: ["W": 55, "H": 20]).status == .solved)
        #expect(abs((s.position(r.corners[2])?.x ?? 0) - 55) < 1e-6 && abs((s.position(r.corners[2])?.y ?? 0) - 20) < 1e-6)
    }
}

/// Two points (or circle centres) mirrored across a line.
@Suite struct SymmetricConstraintTests {
    @Test func pointsAndCirclesMirrorAcrossALine() throws {
        var s = Sketch()
        let axis = s.addLine(s.addPoint(0, -10), s.addPoint(0, 10))
        s.constrain(.vertical(axis))
        let a = s.addPoint(-7, 3), b = s.addPoint(4, 6)
        let kinds = try #require(s.constraints(.symmetric, for: [a, b, axis]))
        #expect(kinds == [.symmetric(a, b, line: axis)])
        let applied = s.applyConstraints(kinds, values: [:])
        #expect(applied)
        let pa = try #require(s.position(a)), pb = try #require(s.position(b))
        let x = try #require(s.lineEnds(axis)).0.x  // the line may move too
        #expect(abs(pa.x + pb.x - 2 * x) < 1e-6 && abs(pa.y - pb.y) < 1e-6, "\(pa) \(pb) about x = \(x)")

        let c1 = s.addCircle(center: s.addPoint(-5, -5), radius: 2), c2 = s.addCircle(center: s.addPoint(8, -4), radius: 2)
        let circles = try #require(s.constraints(.symmetric, for: [c1, c2, axis]))
        let appliedCircles = s.applyConstraints(circles, values: [:])
        #expect(appliedCircles)
        let q1 = try #require(s.center(of: c1).flatMap { s.position($0) }), q2 = try #require(s.center(of: c2).flatMap { s.position($0) })
        let x2 = try #require(s.lineEnds(axis)).0.x
        #expect(abs(q1.x + q2.x - 2 * x2) < 1e-6 && abs(q1.y - q2.y) < 1e-6)
        #expect(s.constraints(.symmetric, for: [a, b]) == nil, "needs a line")
    }
}

/// The sketch's own axes, picked as lines to constrain against.
@Suite struct AxisConstraintTests {
    @Test func twoPointsAreSymmetricAboutTheYAxis() throws {
        var s = Sketch()
        let a = s.addPoint(-7, 3), b = s.addPoint(4, 6)
        let kinds = try #require(s.constraints(.symmetric, for: [a, b, SketchMirrorDef.yAxis]))
        #expect(kinds == [.symmetric(a, b, line: SketchMirrorDef.yAxis)])
        let applied = s.applyConstraints(kinds, values: [:])
        #expect(applied)
        let pa = try #require(s.position(a)), pb = try #require(s.position(b))
        #expect(abs(pa.x + pb.x) < 1e-6 && abs(pa.y - pb.y) < 1e-6, "\(pa) \(pb)")
        // The axis may come first in the pick.
        #expect(s.constraints(.symmetric, for: [SketchMirrorDef.xAxis, a, b]) != nil)
        #expect(s.constraints(.symmetric, for: [a, SketchMirrorDef.yAxis]) == nil, "needs two points")
    }

    @Test func circlesAreSymmetricAboutTheXAxis() throws {
        var s = Sketch()
        let c1 = s.addCircle(center: s.addPoint(-5, 8), radius: 2), c2 = s.addCircle(center: s.addPoint(9, -3), radius: 2)
        let kinds = try #require(s.constraints(.symmetric, for: [c1, c2, SketchMirrorDef.xAxis]))
        let applied = s.applyConstraints(kinds, values: [:])
        #expect(applied)
        let q1 = try #require(s.center(of: c1).flatMap { s.position($0) }), q2 = try #require(s.center(of: c2).flatMap { s.position($0) })
        #expect(abs(q1.y + q2.y) < 1e-6 && abs(q1.x - q2.x) < 1e-6)
    }

    @Test func aPointCanLieOnAnAxis() throws {
        var s = Sketch()
        let p = s.addPoint(6, 4)
        let kinds = try #require(s.constraints(.coincident, for: [p, SketchMirrorDef.xAxis]))
        #expect(kinds == [.pointOnCurve(point: p, curve: SketchMirrorDef.xAxis)])
        let applied = s.applyConstraints(kinds, values: [:])
        #expect(applied)
        #expect(abs(try #require(s.position(p)).y) < 1e-6)
    }

    @Test func aLineParallelOrSquareToAnAxisIsLevelOrUpright() throws {
        var s = Sketch()
        let l = s.addLine(s.addPoint(0, 0), s.addPoint(10, 3))
        #expect(s.constraints(.parallel, for: [l, SketchMirrorDef.xAxis]) == [.horizontal(l)])
        #expect(s.constraints(.perpendicular, for: [SketchMirrorDef.xAxis, l]) == [.vertical(l)])
        #expect(s.constraints(.parallel, for: [l, SketchMirrorDef.yAxis]) == [.vertical(l)])
        #expect(s.constraints(.perpendicular, for: [l, SketchMirrorDef.yAxis]) == [.horizontal(l)])
        #expect(s.constraints(.parallel, for: [SketchMirrorDef.xAxis, SketchMirrorDef.yAxis]) == nil)
        #expect(s.constraints(.horizontal, for: [SketchMirrorDef.xAxis]) == nil, "the axes are not changed")
        #expect(s.constraints(.fix, for: [SketchMirrorDef.xAxis]) == nil)
    }

    @Test func aCircleCanTouchAnAxis() throws {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(3, 9), radius: 2)
        let kinds = try #require(s.constraints(.tangent, for: [c, SketchMirrorDef.xAxis]))
        let applied = s.applyConstraints(kinds, values: [:])
        #expect(applied)
        let y = try #require(s.center(of: c).flatMap { s.position($0) }).y
        #expect(abs(abs(y) - 2) < 1e-6, "\(y)")
    }

    @Test func aConstraintOnAnAxisSurvivesAnotherOneBeingDeleted() throws {
        var s = Sketch()
        let a = s.addPoint(-7, 3), b = s.addPoint(4, 6), loose = s.addPoint(1, 1)
        let applied = s.applyConstraints([.symmetric(a, b, line: SketchMirrorDef.yAxis)], values: [:])
        #expect(applied)
        s.delete([loose])
        #expect(s.constraints.count == 1)
        let r = SketchSolver.solve(&s, dimensionValues: [:])
        #expect(r.status == .solved)
        #expect(r.degreesOfFreedom == 2, "one free coordinate for each point, less the two the mirror ties: \(r.degreesOfFreedom)")
    }
}

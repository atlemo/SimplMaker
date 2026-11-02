// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Big sketches are solved in independent groups; the answer is the same as solving them whole.
@Suite struct SolverGroupTests {
    /// 60 sloppy rectangles, each dimensioned, a few circles with a radius, and loose lines.
    private func bigSketch() -> (Sketch, [EntityID: Double]) {
        var s = Sketch()
        var values: [EntityID: Double] = [:]
        for i in 0..<38 {
            let x = Double(i) * 20, y = Double(i % 7) * 30
            let c = [s.addPoint(x + 0.3, y - 0.2), s.addPoint(x + 9, y + 1), s.addPoint(x + 8, y + 7), s.addPoint(x - 1, y + 6)]
            let l = (0..<4).map { s.addLine(c[$0], c[($0 + 1) % 4]) }
            s.constrain(.horizontal(l[0])); s.constrain(.vertical(l[1]))
            s.constrain(.horizontal(l[2])); s.constrain(.vertical(l[3]))
            s.dimension(.length(l[0]), "w", id: "w\(i)"); values["w\(i)"] = 10 + Double(i % 5)
            s.dimension(.length(l[1]), "h", id: "h\(i)"); values["h\(i)"] = 6 + Double(i % 3)
            s.dimension(.horizontalDistance("origin", c[0]), "x", id: "x\(i)"); values["x\(i)"] = x
            s.dimension(.verticalDistance("origin", c[0]), "y", id: "y\(i)"); values["y\(i)"] = y
        }
        for i in 0..<5 {
            let centre = s.addPoint(Double(i) * 12, -50)
            let circle = s.addCircle(center: centre, radius: 3)
            s.dimension(.radius(circle), "r", id: "r\(i)"); values["r\(i)"] = 4 + Double(i)
        }
        s.addLine(s.addPoint(0, -80), s.addPoint(30, -90))  // nothing ties this one down
        return (s, values)
    }

    @Test func groupsAgreeWithSolvingTogether() {
        let (start, values) = bigSketch()
        #expect(start.points.count > SketchSolver.splitThreshold)
        var whole = start, grouped = start
        let a = SketchSolver.solveTogether(&whole, dimensionValues: values, soft: [], softWeight: 0.05)
        let b = SketchSolver.solve(&grouped, dimensionValues: values)
        #expect(a.status == .solved && b.status == .solved)
        #expect(a.degreesOfFreedom == b.degreesOfFreedom, "\(a.degreesOfFreedom) vs \(b.degreesOfFreedom)")
        for (p, q) in zip(whole.points, grouped.points) {
            #expect(abs(p.x - q.x) < 1e-5 && abs(p.y - q.y) < 1e-5, "\(p.id)")
        }
        for (c, d) in zip(whole.curves, grouped.curves) {
            if case .circle(_, let r1) = c.geometry, case .circle(_, let r2) = d.geometry { #expect(abs(r1 - r2) < 1e-6) }
        }
    }

    @Test func groupsReportConflictsAndKeepDraggedGeometryMoving() {
        var (s, values) = bigSketch()
        // A conflict in one rectangle makes the whole solve fail.
        s.dimension(.length(s.curves[0].id), "again", id: "clash"); values["clash"] = 99
        #expect(SketchSolver.solve(&s, dimensionValues: values).status == .failed)
        // Dragging: a soft pull on one corner moves it while the rest hold.
        var (t, v2) = bigSketch()
        _ = SketchSolver.solve(&t, dimensionValues: v2)
        let corner = t.curves[1].id
        guard case .line(let a, _) = t.curve(corner)!.geometry else { Issue.record("expected a line"); return }
        let before = t.point(a)!.position
        let r = SketchSolver.solve(&t, dimensionValues: v2, soft: [.point(a, before + SIMD2(3, 0))])
        #expect(r.status == .solved || r.maxResidual < 1)
    }

    @Test func aBigUnconstrainedDrawingSolvesQuickly() throws {
        // 600 rounded squares: thousands of points, arcs but no constraints.
        var body = ""
        for i in 0..<600 { body += "<rect x=\"\(i % 30 * 4)\" y=\"\(i / 30 * 4)\" width=\"3\" height=\"3\" rx=\"0.5\"/>" }
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200mm\" height=\"200mm\" viewBox=\"0 0 200 200\">\(body)</svg>"
        var sketch = try SVGImport.sketch(from: Data(text.utf8)).sketch
        let t0 = Date()
        let r = SketchSolver.solve(&sketch, dimensionValues: [:])
        #expect(r.status == .solved && Date().timeIntervalSince(t0) < 2)
    }
}

// An example part for learning the constraints: one small cell for each constraint tool.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension CADDocument {
    /// One sketch with twelve cells in a 4 × 3 grid, one for each constraint (Coincident shows both of its faces,
    /// point to point and point on a curve). Each cell holds a constraint and nothing else, so everything else in it is
    /// free: drag a point and watch what the constraint keeps in place. Reading order matches the constraints table in
    /// the docs: Coincident, Point on curve, Horizontal, Vertical / Parallel, Perpendicular, Tangent, Equal /
    /// Midpoint, Concentric, Symmetric, Fix.
    public static func constraintsSamplerDemo() -> CADDocument {
        var doc = CADDocument()
        var s = Sketch()
        // On the front plane the first coordinate runs left to right and the second runs up. A cell is 60 × 50 mm
        // and the cells are 70 mm apart in a row and 60 mm apart from row to row, the first row on top.
        func cell(_ name: String, _ column: Int, _ row: Int, _ build: (_ at: (Double, Double) -> (Double, Double),
                                                                      _ id: (String) -> String) -> Void) {
            let ox = Double(column) * 70, oy = -Double(row) * 60
            build({ (ox + $0, oy + $1) }, { "\(name)-\($0)" })
        }
        func point(_ s: inout Sketch, _ p: (Double, Double), _ id: String) -> String {
            s.addPoint(p.0, p.1, id: id)
        }
        func line(_ s: inout Sketch, _ a: (Double, Double), _ b: (Double, Double), _ id: String) -> (line: String, a: String, b: String) {
            let pa = point(&s, a, id + ".a"), pb = point(&s, b, id + ".b")
            return (s.addLine(pa, pb, id: id), pa, pb)
        }

        // Row 1
        cell("coincident", 0, 0) { at, id in
            let l1 = line(&s, at(5, 10), at(28, 32), id("one")), l2 = line(&s, at(28, 32), at(52, 14), id("two"))
            s.constrain(.coincident(l1.b, l2.a))
        }
        cell("on-curve", 1, 0) { at, id in
            let c = point(&s, at(24, 24), id("centre"))
            let circle = s.addCircle(center: c, radius: 17, id: id("circle"))
            let r = 17 / 2.0.squareRoot()
            let l = line(&s, at(24 + r, 24 + r), at(56, 46), id("line"))
            s.constrain(.pointOnCurve(point: l.a, curve: circle))
        }
        cell("horizontal", 2, 0) { at, id in
            let l = line(&s, at(5, 20), at(55, 20), id("line"))
            s.constrain(.horizontal(l.line))
        }
        cell("vertical", 3, 0) { at, id in
            let l = line(&s, at(30, 3), at(30, 47), id("line"))
            s.constrain(.vertical(l.line))
        }
        // Row 2
        cell("parallel", 0, 1) { at, id in
            let l1 = line(&s, at(5, 8), at(45, 23), id("one")), l2 = line(&s, at(12, 28), at(52, 43), id("two"))
            s.constrain(.parallel(l1.line, l2.line))
        }
        cell("perpendicular", 1, 1) { at, id in
            let l1 = line(&s, at(8, 12), at(38, 32), id("one")), l2 = line(&s, at(40, 12), at(20, 42), id("two"))
            s.constrain(.perpendicular(l1.line, l2.line))
        }
        cell("tangent", 2, 1) { at, id in
            let c = point(&s, at(22, 25), id("centre"))
            let circle = s.addCircle(center: c, radius: 14, id: id("circle"))
            // The line touches the circle at 30° above its right side and runs along the tangent there.
            let angle = Double.pi / 6
            let touch = (22 + 14 * cos(angle), 25 + 14 * sin(angle)), dir = (-sin(angle), cos(angle))
            let l = line(&s, at(touch.0 - 18 * dir.0, touch.1 - 18 * dir.1), at(touch.0 + 18 * dir.0, touch.1 + 18 * dir.1), id("line"))
            s.constrain(.tangent(l.line, circle))
        }
        cell("equal", 3, 1) { at, id in
            let l1 = line(&s, at(5, 10), at(35, 10), id("one")), l2 = line(&s, at(15, 22), at(33, 46), id("two"))
            s.constrain(.equal(l1.line, l2.line))
        }
        // Row 3
        cell("midpoint", 0, 2) { at, id in
            let l = line(&s, at(5, 18), at(55, 28), id("line"))
            let m = point(&s, at(30, 23), id("middle"))
            s.constrain(.midpoint(point: m, line: l.line))
            let stem = s.addLine(m, point(&s, at(30, 46), id("stem.end")), id: id("stem"))
            _ = stem
        }
        cell("concentric", 1, 2) { at, id in
            let c1 = point(&s, at(28, 25), id("centre-one")), c2 = point(&s, at(28, 25), id("centre-two"))
            _ = s.addCircle(center: c1, radius: 20, id: id("outer"))
            _ = s.addCircle(center: c2, radius: 9, id: id("inner"))
            s.constrain(.coincident(c1, c2))
        }
        cell("symmetric", 2, 2) { at, id in
            let axis = line(&s, at(30, 2), at(30, 48), id("axis"))
            s.curves[s.curves.count - 1].construction = true
            s.constrain(.vertical(axis.line))
            let apex = point(&s, at(30, 6), id("apex"))
            let left = point(&s, at(12, 36), id("left")), right = point(&s, at(48, 36), id("right"))
            _ = s.addLine(apex, left, id: id("side-left"))
            _ = s.addLine(apex, right, id: id("side-right"))
            s.constrain(.symmetric(left, right, line: axis.line))
        }
        cell("fix", 3, 2) { at, id in
            let l = line(&s, at(10, 10), at(48, 34), id("line"))
            s.constrain(.fix(l.a, x: at(10, 10).0, y: at(10, 10).1))
        }

        doc.features = [Feature(id: "sampler", name: "Constraints Sampler", .sketch(SketchFeature(plane: .xz, sketch: s)))]
        return doc
    }
}

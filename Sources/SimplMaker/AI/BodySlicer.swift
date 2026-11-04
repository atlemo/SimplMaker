// Cuts a body's surface mesh with a plane square to an axis and gives back the outline of the cut: closed loops of points
// in the coordinates a sketch on that plane would use. This is what an AI needs to rebuild an imported mesh (an STL has no
// feature tree to read): slice it at a few stations, read the sizes, and draw the same sections again.
// Pure geometry on the kernel's tessellation; nothing here touches the document.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADKernel
import Foundation
import simd

enum BodySlicer {
    /// One closed outline of a cut, in the sketch coordinates of the cutting plane.
    struct Loop: Equatable {
        /// Corner points in order; counter-clockwise (seen from the plane's positive side) for an outer outline, clockwise for a hole.
        var points: [SIMD2<Double>]
        /// Signed: positive for an outer outline, negative for a hole.
        var signedArea: Double
        var isHole: Bool { signedArea < 0 }
        /// The loop never came back to where it started (a mesh with a gap), so it is an open path.
        var closed: Bool
    }

    /// Where the plane's own coordinates come from in the model's: axis 0 (x) → (y, z), 1 (y) → (x, z), 2 (z) → (x, y).
    /// These are the sketch coordinates of "yz", "xz" and "xy" planes (the plane's offset moves it along the axis).
    static func planeAxes(_ axis: Int) -> (u: Int, v: Int) {
        switch axis {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
    }

    static func planeName(_ axis: Int) -> String { ["yz", "xz", "xy"][min(max(axis, 0), 2)] }

    // MARK: slicing

    /// The outline of the cut of `mesh` by the plane where coordinate `axis` equals `offset`.
    /// `tolerance` simplifies the outlines: corners that lie within it of a straight line are dropped (0 keeps every point).
    static func slice(_ mesh: Mesh, axis: Int, offset: Double, tolerance: Double = 0) -> [Loop] {
        let (ui, vi) = planeAxes(axis)
        let a = SIMD3<Double>(axis == 0 ? 1 : 0, axis == 1 ? 1 : 0, axis == 2 ? 1 : 0)
        // A plane through a vertex would count it twice; nudging it by a hair keeps every vertex strictly on one side.
        let level = offset + 1.234567e-7
        let p = mesh.positions, idx = mesh.indices

        func vertex(_ i: Int) -> SIMD3<Double> { SIMD3(Double(p[3 * i]), Double(p[3 * i + 1]), Double(p[3 * i + 2])) }

        var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
        for t in 0..<(idx.count / 3) {
            let v = [vertex(Int(idx[3 * t])), vertex(Int(idx[3 * t + 1])), vertex(Int(idx[3 * t + 2]))]
            let above = v.map { $0[axis] > level }
            guard above.contains(true), above.contains(false) else { continue }
            // The two edges the plane crosses. Each crossing point is worked out from the edge's endpoints in a fixed order,
            // so that the neighbouring triangle, which shares the edge, gets the very same number.
            var crossings: [SIMD3<Double>] = []
            for (i, j) in [(0, 1), (1, 2), (2, 0)] where above[i] != above[j] {
                var lo = v[i], hi = v[j]
                if lo.x > hi.x || (lo.x == hi.x && (lo.y > hi.y || (lo.y == hi.y && lo.z > hi.z))) { swap(&lo, &hi) }
                let s = (level - lo[axis]) / (hi[axis] - lo[axis])
                crossings.append(lo + s * (hi - lo))
            }
            guard crossings.count == 2 else { continue }
            let normal = simd_cross(v[1] - v[0], v[2] - v[0])
            guard simd_length(normal) > 1e-18 else { continue }
            // Walk with the material on the left (seen from +axis): along axis × outward normal.
            let along = simd_cross(a, normal)
            var from = crossings[0], to = crossings[1]
            if simd_dot(to - from, along) < 0 { swap(&from, &to) }
            let pf = SIMD2(from[ui], from[vi]), pt = SIMD2(to[ui], to[vi])
            if simd_distance(pf, pt) > 1e-12 { segments.append((pf, pt)) }
        }

        var loops = stitch(segments)
        if tolerance > 0 { loops = loops.map { simplified($0, tolerance: tolerance) } }
        return loops.filter { $0.points.count >= 3 }
    }

    /// Joins the segments end to start into loops. Points closer than `epsilon` count as the same (two faces of a body are
    /// tessellated separately and may disagree in the last bits).
    private static func stitch(_ segments: [(SIMD2<Double>, SIMD2<Double>)]) -> [Loop] {
        let cell = 1e-3, epsilon = 5e-4
        struct Cell: Hashable { var x: Int64; var y: Int64 }
        func cellOf(_ q: SIMD2<Double>) -> Cell { Cell(x: Int64((q.x / cell).rounded(.down)), y: Int64((q.y / cell).rounded(.down))) }
        var byStart: [Cell: [Int]] = [:]
        for (i, s) in segments.enumerated() { byStart[cellOf(s.0), default: []].append(i) }
        var used = [Bool](repeating: false, count: segments.count)

        func next(after end: SIMD2<Double>) -> Int? {
            let c = cellOf(end)
            var best: (Int, Double)?
            for dx in -1...1 {
                for dy in -1...1 {
                    for i in byStart[Cell(x: c.x + Int64(dx), y: c.y + Int64(dy))] ?? [] where !used[i] {
                        let d = simd_distance(segments[i].0, end)
                        if d <= epsilon, best == nil || d < best!.1 { best = (i, d) }
                    }
                }
            }
            return best?.0
        }

        var loops: [Loop] = []
        for first in segments.indices where !used[first] {
            used[first] = true
            var points = [segments[first].0]
            var end = segments[first].1
            var closed = false
            while true {
                if simd_distance(end, points[0]) <= epsilon { closed = true; break }
                guard let n = next(after: end) else { break }
                used[n] = true
                points.append(segments[n].0)
                end = segments[n].1
            }
            if !closed { points.append(end) }
            loops.append(Loop(points: points, signedArea: signedArea(points), closed: closed))
        }
        return loops.sorted { abs($0.signedArea) > abs($1.signedArea) }
    }

    static func signedArea(_ points: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    // MARK: simplifying

    /// Douglas–Peucker on a closed loop (or an open path): the corners that matter, within `tolerance` of the original.
    static func simplified(_ loop: Loop, tolerance: Double) -> Loop {
        var pts = loop.points
        guard pts.count > 3 else { return loop }
        if loop.closed {
            // Split the loop at two far-apart points so that each half is an open path.
            var far = 0
            var best = 0.0
            for i in pts.indices {
                let d = simd_distance(pts[i], pts[0])
                if d > best { best = d; far = i }
            }
            let first = Array(pts[0...far]), second = Array(pts[far...] + [pts[0]])
            let a = douglasPeucker(first, tolerance), b = douglasPeucker(second, tolerance)
            pts = Array(a.dropLast()) + Array(b.dropLast())
        } else {
            pts = douglasPeucker(pts, tolerance)
        }
        if loop.closed { pts = withoutStraightCorners(pts, tolerance: tolerance) }
        return Loop(points: pts, signedArea: signedArea(pts), closed: loop.closed)
    }

    /// Takes out the corners of a closed loop that lie within `tolerance` of the line between their neighbours. Douglas–Peucker keeps
    /// the point the loop starts at whatever it is, so a loop that starts in the middle of a straight side keeps a needless corner.
    private static func withoutStraightCorners(_ points: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        var pts = points
        var i = 0
        while i < pts.count, pts.count > 3 {
            let before = pts[(i + pts.count - 1) % pts.count], after = pts[(i + 1) % pts.count]
            if distance(pts[i], from: before, to: after) <= tolerance { pts.remove(at: i) } else { i += 1 }
        }
        return pts
    }

    private static func douglasPeucker(_ pts: [SIMD2<Double>], _ tolerance: Double) -> [SIMD2<Double>] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            var worst = 0.0, at = lo
            for i in (lo + 1)..<hi {
                let d = distance(pts[i], from: pts[lo], to: pts[hi])
                if d > worst { worst = d; at = i }
            }
            if worst > tolerance { keep[at] = true; stack.append((lo, at)); stack.append((at, hi)) }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    private static func distance(_ p: SIMD2<Double>, from a: SIMD2<Double>, to b: SIMD2<Double>) -> Double {
        let d = b - a
        let len2 = simd_dot(d, d)
        guard len2 > 1e-24 else { return simd_distance(p, a) }
        let t = min(max(simd_dot(p - a, d) / len2, 0), 1)
        return simd_distance(p, a + t * d)
    }

    // MARK: measuring a cut

    /// What the outlines of one cut add up to: the centre, the direction the shape is longest in, and how long and wide it is
    /// along and across that direction. For a thin plate cut across, `lengthAcross` is the chord and `thickness` the thickness.
    struct Shape: Equatable {
        var area: Double
        var centroid: SIMD2<Double>
        var boundsMin: SIMD2<Double>
        var boundsMax: SIMD2<Double>
        /// The long direction, in degrees counter-clockwise from the plane's u axis, folded into (-90, 90].
        var majorAxisDegrees: Double
        var length: Double
        var width: Double
    }

    /// Nil when there is nothing to measure (no loops).
    static func shape(of loops: [Loop]) -> Shape? {
        let outlines = loops.filter { $0.closed }
        guard !outlines.isEmpty else { return nil }
        // Area and first moments from the polygons (holes subtract); second moments about the centroid from the same sums.
        var area = 0.0, mx = 0.0, my = 0.0
        for loop in outlines {
            let p = loop.points
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                let cross = a.x * b.y - b.x * a.y
                area += cross / 2
                mx += (a.x + b.x) * cross / 6
                my += (a.y + b.y) * cross / 6
            }
        }
        guard abs(area) > 1e-12 else { return nil }
        let c = SIMD2(mx / area, my / area)
        var ixx = 0.0, iyy = 0.0, ixy = 0.0
        for loop in outlines {
            let p = loop.points.map { $0 - c }
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                let cross = a.x * b.y - b.x * a.y
                ixx += (a.x * a.x + a.x * b.x + b.x * b.x) * cross / 12
                iyy += (a.y * a.y + a.y * b.y + b.y * b.y) * cross / 12
                ixy += (a.x * b.y + 2 * a.x * a.y + 2 * b.x * b.y + b.x * a.y) * cross / 24
            }
        }
        if area < 0 { ixx = -ixx; iyy = -iyy; ixy = -ixy }
        var theta = 0.5 * atan2(2 * ixy, ixx - iyy)  // the direction of the largest spread
        let major = SIMD2(cos(theta), sin(theta)), minor = SIMD2(-sin(theta), cos(theta))
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        var alongMin = Double.infinity, alongMax = -Double.infinity, acrossMin = Double.infinity, acrossMax = -Double.infinity
        for loop in outlines {
            for q in loop.points {
                lo = simd_min(lo, q); hi = simd_max(hi, q)
                let along = simd_dot(q - c, major), across = simd_dot(q - c, minor)
                alongMin = min(alongMin, along); alongMax = max(alongMax, along)
                acrossMin = min(acrossMin, across); acrossMax = max(acrossMax, across)
            }
        }
        theta = theta * 180 / .pi
        if theta <= -90 { theta += 180 }
        if theta > 90 { theta -= 180 }
        return Shape(area: abs(area), centroid: c, boundsMin: lo, boundsMax: hi, majorAxisDegrees: theta,
                     length: alongMax - alongMin, width: acrossMax - acrossMin)
    }
}

// Cubic Bézier math for sketch curves: evaluation, the closest point, splitting and flattening.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum Bezier {
    /// Point at t (0…1) of the cubic with control points p.
    public static func point(_ p: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let u = 1 - t
        // Weights first, as plain numbers: one long mixed expression is too slow to type-check.
        let w0: Double = u * u * u, w1: Double = 3 * u * u * t, w2: Double = 3 * u * t * t, w3: Double = t * t * t
        let a: SIMD2<Double> = w0 * p[0] + w1 * p[1]
        return a + w2 * p[2] + w3 * p[3]
    }

    /// First derivative at t.
    public static func derivative(_ p: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let u = 1 - t
        let w0: Double = 3 * u * u, w1: Double = 6 * u * t, w2: Double = 3 * t * t
        let a: SIMD2<Double> = w0 * (p[1] - p[0]) + w1 * (p[2] - p[1])
        return a + w2 * (p[3] - p[2])
    }

    /// Parameter (0…1) of the curve point closest to q: the best of a coarse sampling, refined by Newton steps.
    public static func closest(_ q: SIMD2<Double>, _ p: [SIMD2<Double>]) -> Double {
        let n = 32
        var best = 0.0, bestD = Double.infinity
        for i in 0...n {
            let t = Double(i) / Double(n), d = vlen(point(p, t) - q)
            if d < bestD { bestD = d; best = t }
        }
        var t = best
        for _ in 0..<8 {
            // Minimise |B(t) − q|²: Newton on f(t) = B′(t)·(B(t) − q).
            let b = point(p, t), d1 = derivative(p, t)
            let u = 1 - t
            let bend0: SIMD2<Double> = p[2] - 2 * p[1] + p[0], bend1: SIMD2<Double> = p[3] - 2 * p[2] + p[1]
            let d2: SIMD2<Double> = (6 * u) * bend0 + (6 * t) * bend1
            let f = vdot(d1, b - q), df = vdot(d2, b - q) + vdot(d1, d1)
            guard abs(df) > 1e-300 else { break }
            let next = min(max(t - f / df, 0), 1)
            if abs(next - t) < 1e-12 { t = next; break }
            t = next
        }
        return t
    }

    /// The control points of the piece of the curve between t0 and t1 (de Casteljau).
    public static func piece(_ p: [SIMD2<Double>], from t0: Double, to t1: Double) -> [SIMD2<Double>] {
        func split(_ p: [SIMD2<Double>], _ t: Double) -> (left: [SIMD2<Double>], right: [SIMD2<Double>]) {
            let a = p[0] + (p[1] - p[0]) * t, b = p[1] + (p[2] - p[1]) * t, c = p[2] + (p[3] - p[2]) * t
            let d = a + (b - a) * t, e = b + (c - b) * t
            let f = d + (e - d) * t
            return ([p[0], a, d, f], [f, e, c, p[3]])
        }
        let tail = split(p, t0).right
        guard t1 < 1 else { return tail }
        return split(tail, t0 < 1 ? (t1 - t0) / (1 - t0) : 0).left
    }

    /// Handles for a run of cubic Béziers that passes smoothly through the points `p`: for each
    /// segment (point i to the next, wrapping round when `closed`), its two middle control points.
    ///
    /// An anchor with a `pulled` vector (the handle the user dragged out) gets that handle going
    /// forward and its mirror going back. Any other anchor turns along the bisector of the way in and
    /// the way out, with handles a third of the neighbouring gap long; the two ends of an open run
    /// leave as the mirror image of the next anchor's direction across the chord, so a few points
    /// give an even, round bend instead of a straight start.
    public static func smoothHandles(through p: [SIMD2<Double>], pulled: [SIMD2<Double>?],
                                     closed: Bool) -> [(SIMD2<Double>, SIMD2<Double>)] {
        let n = p.count
        guard n >= 2, pulled.count == n else { return [] }
        func unit(_ v: SIMD2<Double>) -> SIMD2<Double>? { let l = vlen(v); return l > 1e-12 ? v / l : nil }
        func next(_ i: Int) -> Int { (i + 1) % n }
        func prev(_ i: Int) -> Int { (i + n - 1) % n }
        func pull(_ i: Int) -> SIMD2<Double>? { pulled[i].flatMap { vlen($0) > 1e-9 ? $0 : nil } }

        var dir = [SIMD2<Double>?](repeating: nil, count: n)
        for i in 0..<n {
            if let h = pull(i) { dir[i] = unit(h); continue }
            if !closed, i == 0 || i == n - 1 { continue }
            guard let b = unit(p[next(i)] - p[i]) else { continue }
            let a = unit(p[i] - p[prev(i)]) ?? b
            dir[i] = unit(a + b) ?? b  // a U-turn has no bisector: carry on the way out
        }
        if !closed {
            // The mirror of the neighbour's direction across the chord (just the chord for two points).
            func end(_ i: Int, _ neighbour: Int) {
                guard dir[i] == nil else { return }
                let chord = unit(i == 0 ? p[1] - p[0] : p[n - 1] - p[n - 2]) ?? SIMD2(1, 0)
                guard n > 2, let t = dir[neighbour] else { dir[i] = chord; return }
                dir[i] = unit(2 * vdot(chord, t) * chord - t) ?? chord
            }
            end(0, 1)
            end(n - 1, n - 2)
        }

        return (0..<(closed ? n : n - 1)).map { i in
            let j = next(i), gap = vlen(p[j] - p[i]) / 3
            let out = pull(i) ?? (dir[i] ?? SIMD2(1, 0)) * gap
            let into = pull(j) ?? (dir[j] ?? SIMD2(1, 0)) * gap
            return (p[i] + out, p[j] - into)
        }
    }

    /// The curve as a polyline of `steps` segments.
    public static func flatten(_ p: [SIMD2<Double>], steps: Int = 48) -> [SIMD2<Double>] {
        (0...steps).map { point(p, Double($0) / Double(steps)) }
    }
}

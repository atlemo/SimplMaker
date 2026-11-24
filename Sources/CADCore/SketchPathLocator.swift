// Where a point lies along a path of sketch curves, and which way the path runs there. Used by a construction plane
// that stands square to a path (see `PlanePath`). Works on the solved sketch in its own 2D coordinates; the caller
// turns the answer into world space with the sketch's frame.

import Foundation

public struct SketchPathError: Error, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}

public struct SketchPathLocator: Sendable {
    /// One curve of the chain, walked from its start to its end (or the other way round).
    struct Piece: Sendable {
        var geometry: CurveGeometry
        var reversed: Bool
        var length: Double
        /// Parameter range of the geometry (0…1, or 0…2π for circles and ellipses).
        var lo: Double, hi: Double
        /// For curves whose parameter is not proportional to arc length: parameter at evenly spaced lengths.
        var table: [(length: Double, t: Double)]?
    }

    var pieces: [Piece]
    /// The whole path, in mm.
    public let length: Double

    /// A point on the path and its unit direction of travel.
    public struct Location: Sendable { public var point: SIMD2<Double>; public var tangent: SIMD2<Double> }

    public init(curves ids: [EntityID], in sketch: Sketch) throws {
        guard !ids.isEmpty else { throw SketchPathError("the path has no curves") }
        var geometries: [CurveGeometry] = []
        for id in ids {
            guard let g = sketch.geometry(of: id) else { throw SketchPathError("a path curve was deleted from its sketch") }
            geometries.append(g)
        }
        let order = try Self.chain(geometries)
        pieces = order.map { Self.piece($0.index, geometries, reversed: $0.reversed) }
        length = pieces.reduce(0) { $0 + $1.length }
        guard length > 1e-9 else { throw SketchPathError("the path has no length") }
    }

    /// The place `fraction` of the way along the path (clamped to 0…1; 0 = start, 1 = end).
    public func location(at fraction: Double) -> Location {
        var remaining = min(max(fraction, 0), 1) * length
        for (n, piece) in pieces.enumerated() {
            if remaining <= piece.length || n == pieces.count - 1 {
                let u = piece.length > 0 ? min(max(remaining / piece.length, 0), 1) : 0
                return Self.evaluate(piece, u)
            }
            remaining -= piece.length
        }
        return Location(point: .zero, tangent: SIMD2(1, 0))  // unreachable: pieces is not empty
    }

    // MARK: building the chain

    private static func range(_ g: CurveGeometry) -> (lo: Double, hi: Double) {
        switch g {
        case .circle, .ellipse: return (0, 2 * .pi)
        default: return (0, 1)
        }
    }

    private static func isClosed(_ g: CurveGeometry) -> Bool {
        switch g { case .circle, .ellipse: return true; default: return false }
    }

    private static func ends(_ g: CurveGeometry) -> (SIMD2<Double>, SIMD2<Double>) {
        let r = range(g)
        return (g.point(r.lo), g.point(r.hi))
    }

    private static func chain(_ g: [CurveGeometry]) throws -> [(index: Int, reversed: Bool)] {
        if g.count == 1 { return [(0, false)] }
        if g.contains(where: isClosed) { throw SketchPathError("a closed curve (circle or ellipse) can only be a path on its own") }
        let tol = 1e-4
        func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { vlen(a - b) < tol }
        let e = g.map(ends)
        // The path starts at a loose end: the first one met going through the curves in the order they were picked.
        // With none (a closed loop of curves) it starts at the start of the first curve.
        var startIndex = 0, startReversed = false
        search: for i in g.indices {
            for flip in [false, true] {
                let p = flip ? e[i].1 : e[i].0
                let joined = g.indices.contains { j in j != i && (near(p, e[j].0) || near(p, e[j].1)) }
                if !joined { startIndex = i; startReversed = flip; break search }
            }
        }
        var order: [(index: Int, reversed: Bool)] = [(startIndex, startReversed)]
        var used: Set<Int> = [startIndex]
        var tip = startReversed ? e[startIndex].0 : e[startIndex].1
        while used.count < g.count {
            var found = false
            for j in g.indices where !used.contains(j) {
                if near(tip, e[j].0) { order.append((j, false)); tip = e[j].1 }
                else if near(tip, e[j].1) { order.append((j, true)); tip = e[j].0 }
                else { continue }
                used.insert(j); found = true; break
            }
            if !found { throw SketchPathError("the path's curves do not form one connected chain") }
        }
        return order
    }

    private static func piece(_ index: Int, _ g: [CurveGeometry], reversed: Bool) -> Piece {
        let geometry = g[index], r = range(geometry)
        switch geometry {
        case .line(let a, let b):
            return Piece(geometry: geometry, reversed: reversed, length: vlen(b - a), lo: r.lo, hi: r.hi, table: nil)
        case .arc(_, let radius, _, let sweep):
            return Piece(geometry: geometry, reversed: reversed, length: radius * abs(sweep), lo: r.lo, hi: r.hi, table: nil)
        case .circle(_, let radius):
            return Piece(geometry: geometry, reversed: reversed, length: 2 * .pi * radius, lo: r.lo, hi: r.hi, table: nil)
        case .bezier, .ellipse:
            let n = 512
            var table: [(length: Double, t: Double)] = [(0, r.lo)]
            var previous = geometry.point(r.lo), total = 0.0
            for k in 1...n {
                let t = r.lo + (r.hi - r.lo) * Double(k) / Double(n)
                let p = geometry.point(t)
                total += vlen(p - previous); previous = p
                table.append((total, t))
            }
            return Piece(geometry: geometry, reversed: reversed, length: total, lo: r.lo, hi: r.hi, table: table)
        }
    }

    /// The point `u` (0…1 of the piece's length, in the direction it is walked) and its direction of travel.
    private static func evaluate(_ p: Piece, _ walked: Double) -> Location {
        let u = p.reversed ? 1 - walked : walked
        var t = p.lo + (p.hi - p.lo) * u
        if let table = p.table {
            let target = u * p.length
            var low = 0, high = table.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if table[mid].length < target { low = mid } else { high = mid }
            }
            let span = table[high].length - table[low].length
            let f = span > 0 ? (target - table[low].length) / span : 0
            t = table[low].t + (table[high].t - table[low].t) * f
        }
        let h = (p.hi - p.lo) * 1e-6
        let a = max(p.lo, t - h), b = min(p.hi, t + h)
        var d = p.geometry.point(b) - p.geometry.point(a)
        let n = vlen(d)
        d = n > 1e-15 ? d / n : SIMD2(1, 0)
        return Location(point: p.geometry.point(t), tangent: p.reversed ? -d : d)
    }
}

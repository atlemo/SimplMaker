// The clear space between a circle's (or arc's) rim and another item: what "put the hole 4 mm
// from the edge" measures.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct RimGap {
    enum Other {
        case point(SIMD2<Double>)
        case line(SIMD2<Double>, SIMD2<Double>)
        case circle(SIMD2<Double>, Double)
    }
    var center: SIMD2<Double>
    var radius: Double
    var other: Other

    /// Which way the gap is taken, read once when a dimension is made and kept while solving, so
    /// the circle stays on its side of the line (or outside / inside the other circle).
    struct Side {
        /// For a line: +1 when the circle's center is left of it (a→b), else -1.
        var line: Double = 1
        /// For two circles: 0 apart, 1 this one lies inside the other, -1 the other lies inside this one.
        var nesting = 0
    }

    var side: Side {
        switch other {
        case .point: return Side()
        case .line(let a, let b): return Side(line: vcross(b - a, center - a) >= 0 ? 1 : -1)
        case .circle(let c, let r):
            guard vlen(c - center) < abs(radius - r) else { return Side() }
            return Side(nesting: radius < r ? 1 : -1)
        }
    }

    /// The gap, positive while the rim clears the other item; negative once they overlap.
    func gap(_ side: Side) -> Double {
        switch other {
        case .point(let p): return vlen(p - center) - radius
        case .line(let a, let b):
            return side.line * vcross(b - a, center - a) / max(vlen(b - a), 1e-12) - radius
        case .circle(let c, let r):
            let d = vlen(c - center)
            switch side.nesting {
            case 1: return r - radius - d
            case -1: return radius - r - d
            default: return d - radius - r
            }
        }
    }

    /// The two points the gap is measured between: on the rim, and on the other item facing it.
    var nearest: (SIMD2<Double>, SIMD2<Double>) {
        func unit(_ v: SIMD2<Double>) -> SIMD2<Double> { let n = vlen(v); return n > 1e-12 ? v / n : SIMD2(1, 0) }
        let toward: SIMD2<Double>, target: SIMD2<Double>
        switch other {
        case .point(let p):
            toward = unit(p - center); target = p
        case .line(let a, let b):
            let d = unit(b - a)
            target = a + d * vdot(center - a, d)
            toward = unit(target - center)
        case .circle(let c, let r):
            toward = unit(c - center); target = c - toward * r
        }
        return (center + toward * radius, target)
    }
}

extension Sketch {
    /// Where a gap dimension is measured: the facing points on the rim and on what it is measured to.
    public func gapEnds(_ circle: EntityID, _ other: EntityID) -> (SIMD2<Double>, SIMD2<Double>)? {
        rimGap(circle, other)?.nearest
    }
}

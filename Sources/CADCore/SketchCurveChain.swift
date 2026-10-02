// A run of smooth Bézier curves drawn point by point (the Curve tool): the chain being built and
// the layout of its handles.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The curves drawn so far by one run of the Curve tool, and the points they pass through.
public struct CurveChain: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var curve: EntityID
        public var control1: EntityID
        public var control2: EntityID
        public init(curve: EntityID, control1: EntityID, control2: EntityID) {
            self.curve = curve; self.control1 = control1; self.control2 = control2
        }
    }

    /// The points the curve passes through, in order.
    public var anchors: [EntityID]
    /// `segments[i]` runs from `anchors[i]` to the next anchor (the first one again when closed).
    public var segments: [Segment] = []
    /// A handle the user pulled out at an anchor (forward; the way back mirrors it). Anchors without
    /// one are smoothed automatically.
    public var pulled: [EntityID: SIMD2<Double>] = [:]
    /// The last curve came back to the first point.
    public var closed = false

    public init(anchors: [EntityID]) { self.anchors = anchors }

    /// The handle points and curves: what snapping should leave alone while the chain grows.
    public var owned: Set<EntityID> {
        Set(segments.flatMap { [$0.curve, $0.control1, $0.control2] })
    }
}

extension Sketch {
    /// Whether everything the chain refers to is still in the sketch (it isn't after an undo).
    public func contains(_ chain: CurveChain) -> Bool {
        chain.anchors.allSatisfy { point($0) != nil }
            && chain.segments.allSatisfy { point($0.control1) != nil && point($0.control2) != nil && curve($0.curve) != nil }
    }

    /// Puts every handle of the chain where its smooth shape wants it.
    public mutating func layOutHandles(of chain: CurveChain) {
        let positions = chain.anchors.compactMap { position($0) }
        guard positions.count == chain.anchors.count else { return }
        let handles = Bezier.smoothHandles(through: positions, pulled: chain.anchors.map { chain.pulled[$0] },
                                           closed: chain.closed)
        for (segment, h) in zip(chain.segments, handles) {
            place(segment.control1, h.0)
            place(segment.control2, h.1)
        }
    }

    private mutating func place(_ id: EntityID, _ p: SIMD2<Double>) {
        guard let i = points.firstIndex(where: { $0.id == id }) else { return }
        points[i].x = p.x
        points[i].y = p.y
    }

    /// Adds the next curve of a chain, from its last anchor to `end` (a snap: an existing point, a spot
    /// on a curve, or free), and lays out the handles again. Coming back to the first anchor of a chain
    /// of at least three closes it smoothly. `pulled` is the handle dragged out at `end`. Returns the
    /// chain, and whether it goes on (false once it has met existing geometry or closed).
    public mutating func extendCurve(_ chain: CurveChain, to end: SketchSnap, pulled: SIMD2<Double>?) -> (chain: CurveChain, continues: Bool) {
        var chain = chain
        guard let last = chain.anchors.last else { return (chain, false) }
        let closing = chain.anchors.count >= 3 && end.point == chain.anchors.first
        let b = resolve(end)
        let c1 = addPoint(0, 0), c2 = addPoint(0, 0)
        let curve = addBezier(start: last, control1: c1, control2: c2, end: b)
        chain.segments.append(.init(curve: curve, control1: c1, control2: c2))
        let meets = end.point != nil || end.curve != nil || end.model != nil
        if closing {
            chain.closed = true
        } else {
            chain.anchors.append(b)
            if !meets, let pulled { chain.pulled[b] = pulled }
        }
        layOutHandles(of: chain)
        return (chain, !closing && !meets)
    }
}

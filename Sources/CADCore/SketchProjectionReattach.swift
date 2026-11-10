// Project Again: giving a projection another edge to follow.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import simd

/// Project Again: a projection that lost its edge (or that should follow another one) is given a new edge, and keeps its
/// points, its curves and everything tied to them.

/// What a projection is made of: the kind decides which edges it can follow.
public enum ProjectionKind: Equatable, Sendable {
    case straight
    /// A circular edge: an arc, or a circle that closes on itself.
    case arc, circle
    /// Any other curve, as Bézier pieces.
    case curve

    public var title: String {
        switch self {
        case .straight: return "a straight edge"
        case .arc: return "a round edge (an arc)"
        case .circle: return "a full circle"
        case .curve: return "a curved edge"
        }
    }
}

public struct ProjectionMismatch: Error, Equatable, CustomStringConvertible {
    public var description: String
}

extension SketchProjection {
    public var kind: ProjectionKind {
        if chainPoints != nil { return .curve }
        if center != nil { return start == end ? .circle : .arc }
        return .straight
    }
}

extension ModelSnap {
    public var projectionKind: ProjectionKind {
        if chain != nil { return .curve }
        if center != nil { return isFullCircle ? .circle : .arc }
        return .straight
    }
}

extension Sketch {
    /// The projection one of the sketch's points or curves belongs to.
    public func projection(owning id: EntityID) -> SketchProjection? {
        projections.first { $0.pointIDs.contains(id) || $0.curveIDs.contains(id) }
    }

    /// Makes the projection `id` follow another edge: its points and curves stay (so constraints, dimensions and curves
    /// drawn on them stay), and move to where the new edge is. Throws, leaving the sketch alone, when the new edge isn't
    /// the same kind (straight, round or curved, a circle or an arc), has no length in the sketch, or is projected already.
    @discardableResult
    public mutating func reattachProjection(_ id: EntityID, to m: ModelSnap) throws -> SketchProjection {
        guard let i = projections.firstIndex(where: { $0.id == id }) else {
            throw ProjectionMismatch(description: "That projection is no longer in the sketch")
        }
        let p = projections[i]
        let intact = p.pointIDs.allSatisfy { point($0) != nil } && p.curveIDs.allSatisfy { curve($0) != nil }
        guard intact else { throw ProjectionMismatch(description: "That projection has lost some of its geometry") }
        guard m.projectionKind == p.kind else {
            throw ProjectionMismatch(description: "That is \(m.projectionKind.title), and this projection is \(p.kind.title): pick \(p.kind.title)")
        }
        if projections.contains(where: { $0.edge == m.edge && $0.id != id }) {
            throw ProjectionMismatch(description: "That edge is projected already")
        }
        if p.kind == .straight, simd_distance(m.start, m.end) < 1e-6 {
            throw ProjectionMismatch(description: "That edge points straight at the sketch, so it has no length in it")
        }
        func place(_ pid: EntityID, _ uv: SIMD2<Double>) {
            guard let k = points.firstIndex(where: { $0.id == pid }) else { return }
            points[k].x = uv.x; points[k].y = uv.y; points[k].fixed = true
        }
        projections[i].edge = m.edge
        switch p.kind {
        case .straight:
            place(p.start, m.start); place(p.end, m.end)
        case .arc, .circle:
            guard let c = p.center, let mid = m.center else { break }
            place(c, mid); place(p.start, m.start); place(p.end, m.end)
            if let k = curves.firstIndex(where: { $0.id == p.line }), case .circle(let cc, _) = curves[k].geometry {
                curves[k].geometry = .circle(center: cc, radius: simd_distance(m.start, mid))
            }
        case .curve:
            // The same number of pieces: a different one is put right by the next rebuild, which samples the new edge into
            // as many pieces as the projection has.
            if let ids = p.chainPoints, let chain = m.chain, chain.count == ids.count {
                for (pid, q) in zip(ids, chain) { place(pid, q) }
            }
        }
        return projections[i]
    }
}

import Foundation

/// Tidying the projected model edges (see SketchProjection): the ones nothing uses, and the ones whose edge is gone.
extension Sketch {
    /// The projections that nothing in the sketch rests on: no drawn curve ends on their points, no constraint or
    /// dimension besides their own pins mentions them, and no text, pattern or mirror uses them.
    public func unusedProjections() -> [SketchProjection] {
        projections.filter { !isUsed($0) }
    }

    private func isUsed(_ p: SketchProjection) -> Bool {
        let ownPoints = Set(p.pointIDs), ownCurves = Set(p.curveIDs)
        let own = ownPoints.union(ownCurves)
        // A drawn curve ending on one of its points (a projection's own curves don't count).
        for c in curves where !ownCurves.contains(c.id) && !Sketch.isGenerated(c.id) {
            if pointIDs(of: c).contains(where: ownPoints.contains) { return true }
        }
        if texts.contains(where: { ownPoints.contains($0.position) }) { return true }
        // Constraints and dimensions that reach outside the projection (its own pins stay inside it).
        for k in constraints {
            let refs = Sketch.references(k.kind)
            if refs.contains(where: own.contains), !refs.allSatisfy(own.contains) { return true }
        }
        for d in dimensions where Sketch.references(d.kind).contains(where: own.contains) { return true }
        if patterns.contains(where: { $0.sources.contains(where: own.contains) }) { return true }
        if mirrors.contains(where: { own.contains($0.line) || $0.sources.contains(where: own.contains) }) { return true }
        return false
    }

    /// Removes one projection with the construction geometry it made. Returns whether it was there.
    @discardableResult
    public mutating func removeProjection(_ id: EntityID) -> Bool {
        guard let p = projections.first(where: { $0.id == id }) else { return false }
        delete(Set(p.curveIDs + p.pointIDs))
        projections.removeAll { $0.id == id }  // already gone if the delete dropped it as broken
        return true
    }

    /// Removes the projections nothing uses. Returns how many went.
    @discardableResult
    public mutating func cleanUpProjections() -> Int {
        let ids = unusedProjections().map(\.id)
        for id in ids { removeProjection(id) }
        return ids.count
    }

    /// Removes the given projections (the stale ones, as the regenerator finds them) with what rests on them.
    /// Returns how many went.
    @discardableResult
    public mutating func removeProjections(_ ids: Set<EntityID>) -> Int {
        var n = 0
        for id in ids where removeProjection(id) { n += 1 }
        return n
    }
}

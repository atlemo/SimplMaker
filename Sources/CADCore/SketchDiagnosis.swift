// Which constraints and dimensions of a sketch fight each other, or say what another already says.
//
// A sketch that cannot be solved is least-squares compromised by the solver: every constraint is a little wrong. The ones
// that stay wrong are the ones that conflict. A constraint whose equations follow from the ones before it (its rows of the
// Jacobian are dependent) is redundant: harmless while it agrees, a conflict when it does not.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SketchDiagnosis: Sendable, Equatable {
    /// Constraints and dimensions (their ids) that cannot all hold, in the order they were added.
    public var conflicting: [EntityID] = []
    /// Constraints and dimensions that already follow from the others and agree with them.
    public var redundant: [EntityID] = []

    public init(conflicting: [EntityID] = [], redundant: [EntityID] = []) {
        self.conflicting = conflicting
        self.redundant = redundant
    }

    public var isEmpty: Bool { conflicting.isEmpty && redundant.isEmpty }
}

extension SketchConstraint.Kind {
    /// The constraint's name as the sketch lists it.
    public var title: String {
        switch self {
        case .coincident: return "Coincident"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .parallel: return "Parallel"
        case .perpendicular: return "Perpendicular"
        case .equal: return "Equal"
        case .tangent: return "Tangent"
        case .pointOnCurve: return "Point on curve"
        case .midpoint: return "Midpoint"
        case .fix: return "Fixed"
        case .symmetric: return "Symmetric"
        }
    }
}

extension SketchDimension {
    /// The dimension's name as the sketch lists it, without its value.
    public var title: String {
        switch kind {
        case .distance: return "Distance"
        case .horizontalDistance: return "Horizontal"
        case .verticalDistance: return "Vertical"
        case .pointLineDistance: return "Distance"
        case .length(let l): return "Length \(l)"
        case .radius(let c): return "Radius \(c)"
        case .diameter(let c): return "Ø \(c)"
        case .angle, .supplementAngle, .lineAngle: return "Angle"
        case .arcAngle(let c): return "Sweep \(c)"
        case .radialOffset: return "Offset"
        case .gap: return "Gap"
        }
    }
}

extension SketchDimension {
    /// The dimension's name for a sentence: no entity id, which means nothing to the user.
    public var shortTitle: String {
        switch kind {
        case .length: return "Length"
        case .radius: return "Radius"
        case .diameter: return "Diameter"
        case .arcAngle: return "Sweep"
        default: return title
        }
    }
}

extension Sketch {
    /// "Horizontal", or "Distance = 40 mm": a constraint or dimension in a sentence. Nil for an id that is neither.
    public func describeRule(_ id: EntityID) -> String? {
        if let c = constraints.first(where: { $0.id == id }) { return c.kind.title }
        if let d = dimensions.first(where: { $0.id == id }) { return "\(d.shortTitle) = \(d.expression)" }
        return nil
    }

    /// What would conflict if these constraints were added, for saying why they can't be.
    public func diagnosis(adding kinds: [SketchConstraint.Kind], values: [EntityID: Double]) -> (diagnosis: SketchDiagnosis, added: Set<EntityID>) {
        var trial = self
        for k in kinds { trial.constrain(k) }
        let added = Set(trial.constraints.map(\.id)).subtracting(constraints.map(\.id))
        return (SketchSolver.diagnose(trial, dimensionValues: values), added)
    }

    /// What would conflict if this dimension were added.
    public func diagnosis(addingDimension kind: SketchDimension.Kind, expression: String, value: Double,
                          values: [EntityID: Double], id: EntityID) -> (diagnosis: SketchDiagnosis, added: Set<EntityID>) {
        var trial = self
        trial.dimension(kind, expression, id: id)
        var v = values
        v[id] = value
        return (SketchSolver.diagnose(trial, dimensionValues: v), [id])
    }

    /// "Horizontal and Length l1 = 40 mm fight" style text for the rules in `ids` other than `excluding`, or nil if none.
    public func conflictText(_ ids: [EntityID], excluding: Set<EntityID> = []) -> String? {
        let names = ids.filter { !excluding.contains($0) }.compactMap(describeRule)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(4).joined(separator: ", ")
        return names.count > 4 ? "\(shown) and \(names.count - 4) more" : shown
    }
}

extension SketchSolver {
    /// Sketches with more points than this are not diagnosed: the analysis is dense.
    static let diagnoseLimit = 400
    /// A residual larger than this is a constraint that is not met.
    static let violated = 1e-6

    /// Finds the constraints and dimensions that conflict or are redundant. Solves a copy of the sketch first, so it can be
    /// called with the sketch as the user left it, solved or not. Empty when the sketch is fine, when it is too big to
    /// analyse, or when the solver merely got stuck: a conflict is named only when the equations are really dependent.
    public static func diagnose(_ sketch: Sketch, dimensionValues: [EntityID: Double]) -> SketchDiagnosis {
        guard !sketch.constraints.isEmpty || !sketch.dimensions.isEmpty, sketch.points.count <= diagnoseLimit else { return SketchDiagnosis() }
        var s = sketch
        _ = solve(&s, dimensionValues: dimensionValues)

        var system = System(s)
        system.addConstraints(s, dimensionValues: dimensionValues)
        let x = system.initial
        let m = system.terms.count, n = x.count
        guard m > 1, n > 0, Double(m) * Double(m) * Double(n) < 4e8 else { return SketchDiagnosis() }
        let f = system.residuals(x)
        let J = system.jacobian(x)

        // Rows in the order they were added; a row with nothing new in it depends on the rows before it.
        var basis: [[Double]] = []
        var dependent = [Bool](repeating: false, count: m)
        for r in 0..<m {
            var v = Array(J[(r * n)..<((r + 1) * n)])
            let size = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if size < 1e-9 { dependent[r] = true; continue }
            for _ in 0..<2 {  // twice, for the rounding of the first pass
                for b in basis {
                    var dot = 0.0
                    for i in 0..<n { dot += v[i] * b[i] }
                    if dot != 0 { for i in 0..<n { v[i] -= dot * b[i] } }
                }
            }
            let rest = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if rest <= 1e-6 * size { dependent[r] = true; continue }
            basis.append(v.map { $0 / rest })
        }

        var diagnosis = SketchDiagnosis()
        let conflicted = (0..<m).contains { dependent[$0] && abs(f[$0]) > violated }
        var seenConflict = Set<EntityID>(), seenRedundant = Set<EntityID>()
        for r in 0..<m {
            guard let owner = system.owners[r] else { continue }
            if conflicted, abs(f[r]) > violated, seenConflict.insert(owner).inserted { diagnosis.conflicting.append(owner) }
            if dependent[r], abs(f[r]) <= violated, !seenConflict.contains(owner), seenRedundant.insert(owner).inserted { diagnosis.redundant.append(owner) }
        }
        // A rule can't be both: the one that has a violated equation is the conflict.
        diagnosis.redundant.removeAll { seenConflict.contains($0) }
        return diagnosis
    }
}

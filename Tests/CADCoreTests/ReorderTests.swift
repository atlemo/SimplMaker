// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// Moving features in the timeline: allowed unless it puts something before what it's built from.
@Suite struct ReorderTests {
    private func doc() -> CADDocument {
        let sketch = { Feature.Kind.sketch(SketchFeature(plane: .xy, sketch: Sketch())) }
        var d = CADDocument()
        d.features = [
            Feature(id: "s1", name: "Sketch1", sketch()),
            Feature(id: "e1", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "s1", profiles: [], extent: .distance("5 mm")))),
            Feature(id: "s2", name: "Sketch2", sketch()),
            Feature(id: "j", name: "Extrude2", .extrude(ExtrudeFeature(sketch: "s2", profiles: [], extent: .distance("5 mm"),
                                                                       operation: .join, target: "e1"))),
            Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: "e1", edge: "x")], size: "1 mm"))),
            Feature(id: "p", name: "Plane1", .plane(PlaneFeature(base: .xy))),
            Feature(id: "s3", name: "Sketch3", .sketch(SketchFeature(plane: .plane("p"), sketch: Sketch()))),
        ]
        return d
    }

    /// The first version of `reorderProblem`, kept as the oracle for the faster one.
    private func oldReorderProblem(_ d: CADDocument, _ id: FeatureID, to index: Int) -> String? {
        let features = d.features
        guard let from = d.index(of: id) else { return "That feature is missing" }
        var order = features
        let f = order.remove(at: from)
        let to = Swift.min(Swift.max(index, 0), order.count)
        order.insert(f, at: to)
        func name(_ id: FeatureID) -> String { features.first { $0.id == id }?.name ?? "a missing feature" }
        for (i, g) in order.enumerated() {
            let before = Set(order[..<i].map(\.id))
            if let missing = g.references.first(where: { r in !before.contains(r) && order.contains { $0.id == r } }) {
                return g.id == id ? "\(g.name) is built from \(name(missing)), so it has to come after it"
                                  : "\(g.name) is built from \(f.name), so \(f.name) has to come before it"
            }
            let usesBodies = g.references
            for (j, h) in features.enumerated() where j < features.firstIndex(where: { $0.id == g.id })! {
                guard !h.changedBodies.isDisjoint(with: usesBodies), !before.contains(h.id) else { continue }
                return h.id == id ? "\(g.name) uses the body as \(h.name) leaves it, so \(h.name) has to stay before it"
                                  : "\(g.name) uses the body as \(h.name) leaves it, so it has to stay after \(h.name)"
            }
        }
        return nil
    }

    @Test func theFasterCheckAgreesWithTheFirstVersionEverywhere() {
        for d in [doc(), .manifoldDemo()] {
            for f in d.features {
                for index in -1...(d.features.count + 1) {
                    // Whether it can move (the wording may name another of several culprits: a Set has no order).
                    #expect((d.reorderProblem(f.id, to: index) == nil) == (oldReorderProblem(d, f.id, to: index) == nil), "\(f.name) to \(index)")
                }
            }
        }
    }

    @Test func aLongTimelineIsCheckedQuicklyForEveryMenu() {
        var d = CADDocument()
        d.features = [Feature(id: "base", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "10")))]
        for i in 0..<150 {
            d.features.append(Feature(id: "f\(i)", name: "Fillet\(i)", .fillet(EdgeFeature(edges: [EdgeRef(body: "base", edge: "e\(i)")], size: "1 mm"))))
        }
        let start = Date()
        for f in d.features {  // what the timeline's context menus ask on every redraw
            _ = d.reorderProblem(f.id, to: d.index(of: f.id)! - 1)
            _ = d.reorderProblem(f.id, to: d.index(of: f.id)! + 1)
        }
        #expect(Date().timeIntervalSince(start) < 0.5, "300 checks on 150 features")
    }

    @Test func whatMayMove() {
        let d = doc()
        #expect(d.reorderProblem("s2", to: 0) == nil, "a sketch on an origin plane can go first")
        #expect(d.reorderProblem("e1", to: 0)?.contains("built from Sketch1") == true)
        #expect(d.reorderProblem("s1", to: 3)?.contains("Sketch1 has to come before it") == true)
        #expect(d.reorderProblem("f", to: 3)?.contains("as Extrude2 leaves it") == true, "the fillet's edges are on the joined body")
        #expect(d.reorderProblem("p", to: 0) == nil)
        #expect(d.reorderProblem("s3", to: 5)?.contains("built from Plane1") == true)
        #expect(d.reorderProblem("j", to: 5)?.contains("Fillet1") == true, "the fillet needs the join before it")
    }

    @Test func referencesAndChangedBodies() {
        let d = doc()
        #expect(d.features[3].references == ["s2", "e1"] && d.features[3].changedBodies == ["e1"])
        #expect(d.features[6].references == ["p"] && d.features[6].changedBodies.isEmpty)
    }
}

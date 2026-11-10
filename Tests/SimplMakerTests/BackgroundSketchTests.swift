// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd
import Testing
@testable import SimplMaker

/// While a sketch is edited the other sketches on show are drawn behind it, and their points and lines can be snapped to.
@Suite(.serialized) @MainActor struct BackgroundSketchTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A square on the floor, a circle 40 mm above it, and an empty sketch on the upright XZ plane, which is being edited.
    private func editing() async throws -> (DocumentModel, SketchSession) {
        var square = Sketch()
        let r = square.addRectangle(-10, -10, 10, 10, lineIDs: ["A", "B", "C", "D"])
        square.constrain(.fix(r.corners[0], x: -10, y: -10)); square.constrain(.fix(r.corners[2], x: 10, y: 10))
        var circle = Sketch()
        let c = circle.addPoint(0, 0)
        circle.constrain(.fix(c, x: 0, y: 0))
        circle.addCircle(center: c, radius: 6, id: "K")
        var d = CADDocument()
        d.features = [
            Feature(id: "sq", name: "Square", .sketch(SketchFeature(plane: .xy, sketch: square))),
            Feature(id: "up", name: "Plane1", .plane(PlaneFeature(base: .xy, offset: "40 mm"))),
            Feature(id: "ci", name: "Circle", .sketch(SketchFeature(plane: .plane("up"), sketch: circle))),
            Feature(id: "path", name: "Path", .sketch(SketchFeature(plane: .xz, sketch: Sketch()))),
        ]
        let model = DocumentModel(document: d)
        model.showOtherSketches = true
        try await settle(model)
        model.editSketch("path")
        try await settle(model)
        return (model, try #require(model.sketchSession))
    }

    private func click(_ s: SketchSession, _ p: SIMD2<Double>) {
        for phase in [SketchMouse.Phase.moved, .down, .up] { _ = s.handle(SketchMouse(phase: phase, uv: p, pick: nil, tolerance: 0.5)) }
    }

    @Test func theOtherSketchesAreDrawnAndCanBeSwitchedOff() async throws {
        let (model, _) = try await editing()
        defer { model.showOtherSketches = true }
        let shown = model.sketchOverlay()
        #expect(shown.inactive.count > 4, "the square's four sides and the circle: \(shown.inactive.count)")
        #expect(shown.inactive.allSatisfy { $0.id == 0 }, "they are a backdrop: a click goes through them")
        model.showOtherSketches = false
        #expect(model.sketchOverlay().inactive.isEmpty)
        #expect(model.sketchSession?.references.points.isEmpty == true)
        model.showOtherSketches = true
        model.setHidden(["ci"], true)
        #expect(model.backgroundSketches.count == 1, "a sketch hidden in the browser stays hidden")
    }

    @Test func projectEdgeBringsInACurveOfAnotherSketchAndItFollows() async throws {
        let (model, session) = try await editing()
        session.setTool(.projectEdge)
        #expect(model.sketchOverlay().inactive.contains { $0.id != 0 }, "with Project Edge the other sketches' curves can be clicked")
        // The circle, seen edge-on from this sketch: the stretch it covers, 40 mm up.
        let circle = EdgeRef(body: "ci", edge: "K")
        for phase in [SketchMouse.Phase.moved, .down, .up] {
            if let name = session.handle(SketchMouse(phase: phase, uv: SIMD2(6, 40), pick: nil, tolerance: 0.5, edge: circle)).commit {
                model.commitSketch(name)
            }
        }
        let p = try #require(session.sketch.projections.first)
        #expect(p.edge == circle && p.center == nil && p.chainPoints == nil, "a straight stretch: \(p)")
        let ends = [p.start, p.end].compactMap { session.sketch.position($0) }.sorted { $0.x < $1.x }
        #expect(simd_distance(ends[0], SIMD2(-6, 40)) < 1e-9 && simd_distance(ends[1], SIMD2(6, 40)) < 1e-9, "\(ends)")

        // Raise the plane the circle is on: the projection goes with it.
        model.finishSketch()
        try await settle(model)
        model.updateFeature("up", "Change Plane") { f in
            if case .plane(var plane) = f.kind { plane.offset = "55 mm"; f.kind = .plane(plane) }
        }
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let solved = try #require(model.result?.sketches["path"]?.solved)
        let now = [p.start, p.end].compactMap { solved.position($0) }.sorted { $0.x < $1.x }
        #expect(simd_distance(now[0], SIMD2(-6, 55)) < 1e-9 && simd_distance(now[1], SIMD2(6, 55)) < 1e-9, "\(now)")
    }

    @Test func aLineSnapsToTheMiddleOfTheCircleAboveAndToThePlaneOfTheSquare() async throws {
        let (_, session) = try await editing()
        // On this plane (x across, z up) the circle is seen edge-on, 40 mm up, with its middle at (0, 40); the square is the
        // stretch from (-10, 0) to (10, 0).
        #expect(session.references.points.contains { simd_distance($0, SIMD2(0, 40)) < 1e-6 }, "\(session.references.points)")
        #expect(session.references.points.contains { simd_distance($0, SIMD2(10, 0)) < 1e-6 })
        session.setTool(.line)
        click(session, SIMD2(3.2, 0.3))    // near the square's plane, away from its corners
        click(session, SIMD2(0.3, 39.8))   // near the circle's middle
        let ends = session.sketch.points.map(\.position)
        #expect(ends.contains { simd_distance($0, SIMD2(3.2, 0)) < 1e-6 }, "it starts exactly on the square's plane: \(ends)")
        #expect(ends.contains { simd_distance($0, SIMD2(0, 40)) < 1e-6 }, "it ends exactly at the circle's middle: \(ends)")
    }
}

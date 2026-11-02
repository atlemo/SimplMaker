// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import simd
import Testing
@testable import SimplMaker

/// In Sketch mode, a click or a drop on a straight model edge ties the sketch to it.
@Suite @MainActor struct ProjectedEdgeSketchTests {
    private let topEdge = EdgeRef(body: "box", edge: "box.right|box.top")

    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func document(_ sketch: Sketch) -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "box", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .face(FaceRef(body: "box", face: "box.right")), sketch: sketch))),
        ]
        return d
    }

    private func editing(_ sketch: Sketch) async throws -> (DocumentModel, SketchSession, ModelSnap) {
        let model = DocumentModel(document: document(sketch))
        try await settle(model)
        model.editSketch("sk")
        try await settle(model)
        let session = try #require(model.sketchSession)
        let i = try #require(session.references.segmentModels.firstIndex { $0?.edge == topEdge }, "the top edge is offered to snap to")
        return (model, session, try #require(session.references.segmentModels[i]))
    }

    private func click(_ s: SketchSession, _ p: SIMD2<Double>) {
        for phase in [SketchMouse.Phase.moved, .down, .up] { _ = s.handle(SketchMouse(phase: phase, uv: p, pick: nil, tolerance: 0.5)) }
    }

    @Test func drawingFromAPointOnTheEdgeTiesTheCornerToIt() async throws {
        let (_, session, edge) = try await editing(Sketch())
        let mid = (edge.start + edge.end) / 2
        let along = simd_normalize(edge.end - edge.start)
        var inward = SIMD2(-along.y, along.x)
        if simd_dot(inward, SIMD2(10, 10) - mid) < 0 { inward = -inward }
        session.setTool(.rectangle)
        click(session, mid + 0.1 * inward)  // within a few pixels of the edge
        click(session, mid + 5 * along + 8 * inward)
        let s = session.sketch
        #expect(s.projections.count == 1 && s.projections[0].edge == topEdge)
        #expect(s.constraints.contains { if case .pointOnCurve(_, let c) = $0.kind { return c == s.projections[0].line } else { return false } })
    }

    @Test func aPointDroppedOnTheEdgeIsTiedToIt() async throws {
        // A rectangle 1 mm short of the top edge; its corner is dragged up onto the edge.
        var probe = Sketch()
        let (_, _, edge) = try await editing(probe)
        let along = simd_normalize(edge.end - edge.start)
        var inward = SIMD2(-along.y, along.x)
        let mid = (edge.start + edge.end) / 2
        if simd_dot(inward, SIMD2(10, 10) - mid) < 0 { inward = -inward }
        let corner = mid + 1 * inward
        probe.addRectangle(corner.x, corner.y, (mid + 6 * along + 9 * inward).x, (mid + 6 * along + 9 * inward).y)
        let (_, session, _) = try await editing(probe)
        #expect(session.sketch.projections.isEmpty)
        let id = try #require(session.sketch.points.first { simd_length($0.position - corner) < 1e-6 }?.id)
        _ = session.handle(SketchMouse(phase: .moved, uv: corner, pick: nil, tolerance: 0.5))
        _ = session.handle(SketchMouse(phase: .down, uv: corner, pick: nil, tolerance: 0.5))
        _ = session.handle(SketchMouse(phase: .dragged, uv: mid + 0.05 * inward, pick: nil, tolerance: 0.5))
        _ = session.handle(SketchMouse(phase: .up, uv: mid + 0.05 * inward, pick: nil, tolerance: 0.5))
        #expect(session.sketch.projections.count == 1, "dropped on the edge: \(session.message ?? "no message")")
        let p = try #require(session.sketch.point(id))
        let line = try #require(session.sketch.lineEnds(session.sketch.projections[0].line))
        let d = simd_normalize(line.1 - line.0)
        #expect(abs(d.x * (p.y - line.0.y) - d.y * (p.x - line.0.x)) < 1e-6, "the corner is on the edge")
    }

    /// Project Edge brings in an edge that is off the face being sketched on, and stays on for more edges.
    @Test func projectEdgeBringsInAnEdgeOffTheFace() async throws {
        let (_, session, _) = try await editing(Sketch())
        let far = EdgeRef(body: "box", edge: "box.left|box.top")
        session.setTool(.projectEdge)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: far))
        #expect(session.sketch.projections.map(\.edge) == [far], "\(session.message ?? "no message")")
        // Clicking the same edge again changes nothing; the tool is still on, and Esc ends it.
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: far))
        #expect(session.sketch.projections.count == 1)
        #expect(session.tool == .projectEdge)
        session.escape()
        #expect(session.tool == .select)
    }

    @Test func projectEdgeSaysWhatItCannotProject() async throws {
        let (_, session, _) = try await editing(Sketch())
        session.setTool(.projectEdge)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: nil))
        #expect(session.sketch.projections.isEmpty && session.message != nil)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: EdgeRef(body: "box", edge: "box.nothing")))
        #expect(session.sketch.projections.isEmpty)
        #expect(session.message == "Only straight edges, and circles and arcs facing the sketch, can be projected")
    }

    @Test func anEdgePointingAtTheSketchIsRefused() async throws {
        // The bottom front edge runs along the right face's normal, so it lands as a single point on that face.
        let (_, session, _) = try await editing(Sketch())
        session.setTool(.projectEdge)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: EdgeRef(body: "box", edge: "box.bottom|box.front")))
        #expect(session.sketch.projections.isEmpty)
        #expect(session.message == "That edge points straight at the sketch, so it has no length in it")
    }

    /// The viewport's pick of a body edge reaches the tool as that edge.
    @Test func aPickedBodyEdgeIsProjectedThroughTheDocument() async throws {
        let (model, _, _) = try await editing(Sketch())
        let body = try #require(model.meshes.firstIndex { $0.id == "box" })
        let edge = try #require(model.meshes[body].mesh.edgeNames.firstIndex(of: "box.left|box.top"))
        model.sketchSession?.setTool(.projectEdge)
        _ = model.sketchMouse(SketchMouse(phase: .down, uv: nil, pick: PickID(body: body, edge: edge)))
        #expect(model.sketchSession?.sketch.projections.map(\.edge) == [EdgeRef(body: "box", edge: "box.left|box.top")])
    }

    /// Project Edge also takes a circle of the body that faces the sketch: the circle comes in with a fixed center.
    @Test func projectEdgeBringsInACircularEdge() async throws {
        var d = CADDocument()
        d.features = [
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "10", diameter: "20"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: Sketch()))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        try await settle(model)
        let session = try #require(model.sketchSession)
        #expect(session.references.roundEdges.count == 2, "both circles of the cylinder are offered")
        let edge = try #require(session.references.roundEdges.keys.sorted { $0.edge < $1.edge }.first)
        session.setTool(.projectEdge)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: edge))
        let p = try #require(session.sketch.projections.first, "\(session.message ?? "no message")")
        #expect(p.edge == edge && p.center != nil)
        guard case .circle(_, let radius) = try #require(session.sketch.curve(p.line)).geometry else { Issue.record("expected a circle"); return }
        #expect(abs(radius - 10) < 1e-6)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: edge))
        #expect(session.sketch.projections.count == 1, "a second click on the same circle changes nothing")
    }
}

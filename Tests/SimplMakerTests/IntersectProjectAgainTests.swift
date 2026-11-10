// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import simd
import Testing
@testable import SimplMaker

/// Sketch mode's Intersect (the cut of a body by the sketch plane, brought in) and Project Again (a projection takes a new edge).
@Suite @MainActor struct IntersectProjectAgainTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func editing(_ d: CADDocument) async throws -> (DocumentModel, SketchSession) {
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        try await Task.sleep(for: .milliseconds(100))  // the rebuild the editing starts
        try await settle(model)
        return (model, try #require(model.sketchSession))
    }

    // MARK: Intersect

    /// A cylinder, and a sketch on a plane 5 mm up, through its middle.
    private func cylinder(sketch: Sketch = Sketch()) -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "10", diameter: "20"))),
            Feature(id: "pl", name: "Plane1", .plane(PlaneFeature(base: .xy, offset: "5 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .plane("pl"), sketch: sketch))),
        ]
        return d
    }

    @Test func intersectBringsInTheCutOfABodyAndStaysOn() async throws {
        let (model, session) = try await editing(cylinder())
        defer { withExtendedLifetime(model) {} }  // the session reads the model's bodies
        session.setTool(.intersect)
        let done = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, body: "c"))
        #expect(done.commit == "Intersect", "\(session.message ?? "no message")")
        let p = try #require(session.sketch.projections.first)
        #expect(session.sketch.projections.count == 1 && p.kind == .circle)
        #expect(p.edge.body == "c" && p.edge.edge.hasPrefix("section:"))
        #expect(session.sketch.curve(p.line)?.construction == true)
        #expect(session.message == "Brought in 1 curve")
        // Again: nothing new, and it says so.
        let again = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, body: "c"))
        #expect(again.commit == nil && session.sketch.projections.count == 1)
        #expect(session.message == "Where the plane cuts that body is already in the sketch")
        #expect(session.tool == .intersect)
        session.escape()
        #expect(session.tool == .select)
    }

    @Test func intersectSaysWhatItCannotDo() async throws {
        let (model, session) = try await editing(cylinder())
        defer { withExtendedLifetime(model) {} }
        session.setTool(.intersect)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, body: nil))
        #expect(session.message == "Click a body to cut it with the sketch plane")
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, body: "nothing"))
        #expect(session.message == "The sketch plane doesn't cut that body")
        #expect(session.sketch.projections.isEmpty)
    }

    @Test func aPickedBodyReachesIntersectThroughTheDocument() async throws {
        let (model, session) = try await editing(cylinder())
        let body = try #require(model.meshes.firstIndex { $0.id == "c" })
        session.setTool(.intersect)
        _ = model.sketchMouse(SketchMouse(phase: .down, uv: nil, pick: PickID(body: body, face: 0)))
        #expect(model.sketchSession?.sketch.projections.count == 1, "\(session.message ?? "no message")")
    }

    @Test func theIntersectionFollowsTheBodyWhenTheDocumentChanges() async throws {
        let (model, session) = try await editing(cylinder())
        session.setTool(.intersect)
        _ = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, body: "c"))
        let p = try #require(session.sketch.projections.first)
        model.commitSketch("Intersect")
        try await settle(model)
        #expect(session.staleProjections.isEmpty)
        let solved = try #require(model.result?.sketches["sk"]?.solved)
        guard case .circle(_, let r) = try #require(solved.curve(p.line)).geometry else { Issue.record("expected a circle"); return }
        #expect(abs(r - 10) < 1e-6)
    }

    // MARK: Project Again

    /// A box, and a sketch on its right face that follows an edge the box doesn't have (as after the model changed).
    private func stale(round: Bool = false) -> (CADDocument, EntityID) {
        var s = Sketch()
        let gone = EdgeRef(body: "box", edge: "box.nothing|box.here")
        let p = round
            ? s.project(ModelSnap(edge: gone, start: SIMD2(5, 0), end: SIMD2(5, 0), center: .zero, isFullCircle: true))
            : s.project(ModelSnap(edge: gone, start: SIMD2(0, 0), end: SIMD2(10, 0)))
        // A corner held on the projected line.
        let corner = s.addPoint(4, 0)
        if !round { s.constrain(.pointOnCurve(point: corner, curve: p.line)) }
        var d = CADDocument()
        d.features = [
            Feature(id: "box", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .face(FaceRef(body: "box", face: "box.right")), sketch: s))),
        ]
        return (d, p.id)
    }

    private let newEdge = EdgeRef(body: "box", edge: "box.left|box.top")

    @Test func projectAgainTakesTheOnlyStaleProjectionAndAClickOnTheNewEdge() async throws {
        let (doc, id) = stale()
        let (_, session) = try await editing(doc)
        #expect(session.staleProjections == [id], "the missing edge is found out at the rebuild")
        session.setTool(.projectAgain)
        #expect(session.reattaching == id, "the only stale one is taken, and shown selected")
        #expect(Set(session.selection) == Set(session.sketch.projections[0].curveIDs))
        let done = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: newEdge))
        #expect(done.commit == "Project Again", "\(session.message ?? "no message")")
        #expect(session.sketch.projections.map(\.edge) == [newEdge])
        #expect(session.sketch.projections[0].id == id && session.reattaching == nil)
        #expect(!session.staleProjections.contains(id))
        let p = session.sketch.projections[0]
        #expect(session.sketch.constraints.contains { if case .pointOnCurve(_, let c) = $0.kind { return c == p.line } else { return false } },
                "what was tied to the line stays tied")
    }

    @Test func projectAgainTakesTheSelectedProjectionOrAClickOnItsCurve() async throws {
        let (doc, id) = stale()
        let (_, session) = try await editing(doc)
        let line = session.sketch.projections[0].line
        // Selected first, in Select.
        session.selection = [line]
        session.setTool(.projectAgain)
        #expect(session.reattaching == id)
        // Or: the tool on with nothing chosen, then a click on the curve.
        session.setTool(.select)
        session.selection = []
        session.setTool(.projectAgain)
        session.setTool(.select); session.setTool(.projectAgain)  // (the only stale one is taken again…)
        #expect(session.reattaching == id)
        session.escape()
        #expect(session.reattaching == nil)
    }

    @Test func projectAgainRefusesAnEdgeOfAnotherKindAndSaysSo() async throws {
        let (doc, id) = stale(round: true)
        let (_, session) = try await editing(doc)
        session.setTool(.projectAgain)
        #expect(session.reattaching == id)
        let done = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: newEdge))
        #expect(done.commit == nil)
        #expect(session.message?.contains("a straight edge") == true && session.message?.contains("a full circle") == true, "\(session.message ?? "no message")")
        #expect(session.sketch.projections[0].edge.edge == "box.nothing|box.here", "nothing changed")
        #expect(session.reattaching == id, "still waiting for another edge")
    }

    @Test func projectAgainNeedsAProjection() async throws {
        let (_, session) = try await editing(cylinder())
        #expect(!session.canProjectAgain)
        session.setTool(.projectAgain)
        #expect(session.reattaching == nil)
        let done = session.handle(SketchMouse(phase: .down, uv: nil, pick: nil, edge: nil))
        #expect(done.commit == nil && session.message != nil)
    }

    @Test func theNewToolsAreInTheReferencesMenuAndTheCommandList() {
        #expect(SketchTool.references.contains(.intersect) && SketchTool.references.contains(.projectAgain))
        #expect(SketchTool.draw.contains(.intersect))
        #expect(SketchTool.intersect.key != nil && SketchTool.projectAgain.key != nil)
        #expect(SketchTool.intersect.key != SketchTool.projectAgain.key)
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Sketch snapping (points, curves, model edges and corners, grid) and extrudes that go backwards into bodies.
@Suite @MainActor struct SnapAndCutTests {
    private func session() -> SketchSession {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(20, 0)
        s.addLine(a, b, id: "L")
        return SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: ParameterValues())
    }

    private func move(_ s: SketchSession, _ x: Double, _ y: Double, grid: Double? = 1, snapping: Bool = true) -> SketchSnap {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil, tolerance: 0.5, gridStep: grid, snapping: snapping))
        return s.snap(SIMD2(x, y))
    }

    @Test func snapsToNearbyPointsMidpointsAndCurves() {
        let s = session()
        s.setTool(.line)
        let p = move(s, 20.3, 0.2)
        #expect(p.point != nil && p.position == SIMD2(20, 0) && s.lastSnap?.kind == .point)
        let m = move(s, 10.2, 0.3)
        #expect(m.position == SIMD2(10, 0) && s.lastSnap?.kind == .midpoint)
        let c = move(s, 5.3, 0.4)
        #expect(c.curve == "L" && simdLength(c.position - SIMD2(5.3, 0)) < 1e-9 && s.lastSnap?.kind == .curve)
        let g = move(s, 7.4, 3.6)
        #expect(g.position == SIMD2(7, 4) && s.lastSnap?.kind == .grid)
        let free = move(s, 7.4, 3.6, grid: nil)
        #expect(free.position == SIMD2(7.4, 3.6) && s.lastSnap == nil)
        let off = move(s, 20.3, 0.2, snapping: false)
        #expect(off.point == nil && off.position == SIMD2(20.3, 0.2), "⌥ places exactly at the cursor")
    }

    @Test func snapsToModelEdgesAndCornersInThePlane() {
        let s = session()
        s.setTool(.line)
        s.references = SketchReferences(segments: [(SIMD2(-10, 30), SIMD2(40, 30))], points: [SIMD2(-10, 30), SIMD2(40, 30)])
        #expect(move(s, 39.8, 30.3).position == SIMD2(40, 30) && s.lastSnap?.kind == .vertex)
        let e = move(s, 12.2, 29.7)
        #expect(e.position == SIMD2(12.2, 30) && e.point == nil && e.curve == nil && s.lastSnap?.kind == .edge)
    }

    @Test func sketchOnAFaceSeesTheFaceOutline() async throws {
        var doc = CADDocument()
        doc.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "10", height: "5")))]
        let model = DocumentModel(document: doc)
        for _ in 0..<400 where model.result == nil || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        model.beginSketch(on: .face(FaceRef(body: "b", face: "b.top")))
        let refs = try #require(model.sketchSession?.references)
        #expect(refs.segments.count == 4, "the top face's four edges")
        #expect(refs.points.count >= 4)
        for _ in 0..<400 where model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func niceGridSteps() {
        #expect(ViewportMTKView.niceStep(0.7) == 1)
        #expect(ViewportMTKView.niceStep(1.3) == 2)
        #expect(ViewportMTKView.niceStep(3) == 5)
        #expect(ViewportMTKView.niceStep(0.03) == 0.05)
    }

    /// A box, a circle sketched on its top, extruded (joined) 10 mm up.
    private func bossDoc() -> CADDocument {
        var s = Sketch()
        let c = s.addPoint(0, 0)
        s.constrain(.fix(c, x: 0, y: 0))
        s.addCircle(center: c, radius: 2, id: "C")
        var doc = CADDocument()
        doc.features = [
            Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "40", length: "40", height: "20"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: ["C"])],
                                                                     extent: .distance("10 mm"), operation: .join))),
        ]
        return doc
    }

    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func operation(_ model: DocumentModel) -> BodyOperation? {
        if case .extrude(let e)? = model.document.features.last?.kind { return e.operation }
        return nil
    }

    @Test func typingANegativeDistanceCutsIntoTheBody() async throws {
        var doc = bossDoc()
        doc.features[1] = Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .face(FaceRef(body: "b", face: "b.top")),
                                                                                    sketch: { if case .sketch(let s) = doc.features[1].kind { return s.sketch }; return Sketch() }())))
        let model = DocumentModel(document: doc)
        try await settle(model)
        // The top face's frame starts at the box's corner, so a quarter of the circle overlaps the box.
        #expect(abs(try #require(model.result?.body("b")).volume - (32000 + .pi * 4 * 10)) < 1e-6)
        model.selectedFeature = "e"
        #expect(model.dragHandle?.allowsNegative == true)
        #expect(model.commitHandle("-5"))
        #expect(operation(model) == .cut, "pulled back into the body, the extrude cuts")
        try await settle(model)
        let cut = try #require(model.result?.body("b")).volume
        #expect(abs(cut - (32000 - .pi * 4 * 5 / 4)) < 1e-6, "\(cut)")
        #expect(model.commitHandle("3"))
        #expect(operation(model) == .join, "pushed out again, it joins")
        #expect(!model.commitHandle("0"), "zero is not a distance")
        try await settle(model)
    }

    @Test func draggingThroughTheBaseTurnsTheArrowRound() async throws {
        let model = DocumentModel(document: bossDoc())
        try await settle(model)
        model.selectedFeature = "e"
        let h = try #require(model.dragHandle)
        model.beginHandleDrag()
        // A ray crossing the handle's axis 4 mm below its base.
        let below = h.base - 4 * h.direction
        model.dragHandle(rayOrigin: below + SIMD3(0, -100, 0), direction: SIMD3(0, 1, 0))
        #expect(abs((model.handlePreviewValue ?? 0) + 4) < 1e-6)
        try await settle(model)
        model.endHandleDrag()
        guard case .extrude(let e)? = model.document.features.last?.kind, case .distance(let d) = e.extent else {
            Issue.record("expected a distance extrude"); return
        }
        #expect(d == "-4 mm" && e.operation == .cut)
        try await settle(model)
    }

    @Test func aCutWithNoTargetCutsEveryBodyItCrosses() throws {
        var s = Sketch()
        let r = s.addRectangle(-30, -2, 30, 2, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: -30, y: -2)); s.constrain(.fix(r.corners[2], x: 30, y: 2))
        var doc = CADDocument()
        doc.features = [
            Feature(id: "l", name: "L", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "-15", width: "20", length: "20", height: "10"))),
            Feature(id: "r", name: "R", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "15", width: "20", length: "20", height: "10"))),
            Feature(id: "far", name: "Far", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "200", width: "5", length: "5", height: "5"))),
            Feature(id: "sk", name: "Slot", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "cut", name: "Cut", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: ["A", "B", "C", "D"])],
                                                                  extent: .distance("10 mm"), operation: .cut))),
        ]
        let res = Regenerator.regenerate(doc)
        #expect(res.errors.isEmpty, "\(res.errors)")
        #expect(abs(try #require(res.body("l")).volume - (4000 - 20 * 4 * 10)) < 1e-6)
        #expect(abs(try #require(res.body("r")).volume - (4000 - 20 * 4 * 10)) < 1e-6)
        #expect(abs(try #require(res.body("far")).volume - 125) < 1e-9)
    }

    @Test func extrudingABodyFacePullsItOutAndPushesItIn() async throws {
        var doc = CADDocument()
        doc.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "10", height: "5")))]
        let model = DocumentModel(document: doc)
        try await settle(model)
        let top = try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "b.top"))
        model.run(.extrude)
        #expect(model.pendingTool == .extrude && model.toolPrompt?.contains("flat face") == true)
        model.click(PickID(body: 0, face: top), additive: false)
        #expect(model.pendingTool == nil)
        guard case .extrude(let e)? = model.document.features.last?.kind else { Issue.record("expected an extrude"); return }
        #expect(e.face == FaceRef(body: "b", face: "b.top") && e.operation == .join && e.target == "b")
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let body = try #require(model.result?.body("b"))
        #expect(model.result?.bodies.count == 1)
        #expect(abs(body.volume - 200 * 15) < 1e-6, "pulled 10 mm up")
        #expect(body.isValid)
        let h = try #require(model.dragHandle)
        #expect(h.allowsNegative && abs(h.base.z - 5) < 1e-9 && abs(h.base.x) < 1e-9, "the arrow starts at the original face's centre")
        #expect(model.commitHandle("-2"))
        guard case .extrude(let e2)? = model.document.features.last?.kind else { return }
        #expect(e2.operation == .cut)
        try await settle(model)
        #expect(abs((model.result?.body("b")?.volume ?? 0) - 200 * 3) < 1e-6, "pushed 2 mm in")
    }

    @Test func curvedFacesCannotBeExtruded() async throws {
        var doc = CADDocument()
        doc.features = [Feature(id: "c", name: "Cyl", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "5", diameter: "10")))]
        let model = DocumentModel(document: doc)
        try await settle(model)
        let side = try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "c.side"))
        model.click(PickID(body: 0, face: side), additive: false)
        model.run(.extrude)
        #expect(model.alert?.title == "Only flat faces can be extruded")
        #expect(model.document.features.count == 1)
        model.cancelTool()
        try await settle(model)
    }
}

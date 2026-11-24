// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The Design toolbar's tools, the browser's visibility toggles, and the new drag handles.
@Suite @MainActor struct DesignToolTests {
    private func loaded(_ doc: CADDocument) async throws -> DocumentModel {
        let model = DocumentModel(document: doc)
        try await settle(model)
        return model
    }

    /// Waits for background rebuilds: a kernel call still running when the test process exits crashes it.
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func lastFeature(_ model: DocumentModel) throws -> Feature { try #require(model.document.features.last) }

    private func slot(_ model: DocumentModel, _ sketch: FeatureID) throws -> Int {
        try #require(model.sketchSlots.firstIndex(of: sketch)) + 1
    }

    /// A square on XZ, right of the Z axis, with a construction line along the axis.
    private func revolveDoc() -> CADDocument {
        var s = Sketch()
        let r = s.addRectangle(5, 0, 15, 20, lineIDs: ["A", "B", "C", "D"])
        s.constrain(.fix(r.corners[0], x: 5, y: 0)); s.constrain(.fix(r.corners[2], x: 15, y: 20))
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30)
        s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 0, y: 30))
        s.addLine(a, b, id: "AX", construction: true)
        var doc = CADDocument()
        doc.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: s)))]
        return doc
    }

    @Test func extrudeWaitsForAProfileThenHidesItsSketch() async throws {
        var doc = CADDocument.demo()
        doc.features = Array(doc.features.prefix(1))  // just the base sketch
        let model = try await loaded(doc)
        model.run(.extrude)
        #expect(model.pendingTool == .extrude && model.cursorPrompt == "Select a profile or a flat face to extrude · Shift-click for several faces")
        model.click(PickID(body: 0, face: 0), additive: false)  // not a profile: ignored
        #expect(model.pendingTool == .extrude)

        let region = PickID(region: 0, slot: try slot(model, "base"))
        #expect(model.profile(of: region) != nil)
        model.click(region, additive: false)
        #expect(model.pendingTool == nil)
        let f = try lastFeature(model)
        guard case .extrude(let e) = f.kind else { Issue.record("expected an extrude"); return }
        #expect(e.sketch == "base" && e.operation == .newBody)
        #expect(model.isHidden("base"), "a sketch is hidden once a feature uses it")
        #expect(model.selectedFeature == f.id && model.handleFocusRequest == 1)
        try await settle(model)
        #expect(model.dragHandle?.label == "Distance")
    }

    @Test func revolveAsksForAnAxisAndReturnUsesTheDefault() async throws {
        let model = try await loaded(revolveDoc())
        let s = try slot(model, "sk")
        model.run(.revolve)
        let profile = try #require((0..<10).map { PickID(region: $0, slot: s) }.first { model.profile(of: $0) != nil })
        model.click(profile, additive: false)
        #expect(model.pendingTool == .revolve, "still waiting for the axis")
        #expect(model.toolPrompt?.contains("axis") == true)
        model.confirmTool()
        #expect(model.pendingTool == nil)
        guard case .revolve(let r) = try lastFeature(model).kind else { Issue.record("expected a revolve"); return }
        #expect(r.axis == .line("AX"), "the sketch's construction line is the default axis")
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let h = try #require(model.dragHandle)
        #expect(h.label == "Angle" && h.unit == .angle)
        #expect(!model.commitHandle("400"), "more than a full turn")
        #expect(model.commitHandle("90"))
        guard case .revolve(let r2) = try lastFeature(model).kind else { return }
        #expect(r2.angle == "90 deg")
        try await settle(model)
    }

    @Test func primitivesArePlacedWhereThePlaneIsClicked() async throws {
        let model = try await loaded(CADDocument())
        model.run(.box)
        #expect(model.pendingTool == .box && model.showsOriginPlanes)
        #expect(model.dimensionLabels().count == 3, "the origin planes are labelled")
        model.clickRay = (SIMD3(12, 7, 50), SIMD3(0, 0, -1))
        model.click(OriginPlane.xy.pickID, additive: false)
        #expect(model.pendingTool == nil && !model.showsOriginPlanes)
        guard case .primitive(let p) = try lastFeature(model).kind else { Issue.record("expected a box"); return }
        #expect(p.kind == .box && p.plane == .xy && p.u == "12 mm" && p.v == "7 mm" && p.operation == .newBody)
        try await settle(model)
        let body = try #require(model.result?.bodies.first)
        #expect(abs(body.body.volume - 8000) < 1e-6)
        #expect(model.dragHandle?.label == "Height")
        #expect(model.commitHandle("30"))
        try await settle(model)
        #expect(abs((model.result?.bodies.first?.body.volume ?? 0) - 12000) < 1e-6)
    }

    @Test func holeOnTheSelectedFace() async throws {
        // The front side: the middle of the top face is inside the plate's centre hole.
        let model = try await loaded(.demo())
        let side = try #require(model.meshes.first?.mesh.faceNames.firstIndex(of: "plate.side.L0"))
        model.click(PickID(body: 0, face: side), additive: false)
        let before = try #require(model.result?.body("plate")).volume
        model.run(.hole)
        #expect(model.pendingTool == nil, "a selected flat face is enough")
        guard case .hole(let h) = try lastFeature(model).kind else { Issue.record("expected a hole"); return }
        #expect(h.face == FaceRef(body: "plate", face: "plate.side.L0"))
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(try #require(model.result?.body("plate")).volume < before)
        #expect(model.dragHandle?.label == "Depth")
    }

    @Test func threadWaitsForARoundFaceAndPicksTheSizeThatFits() async throws {
        var doc = CADDocument()
        doc.features = [Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy,
                                                                                         height: "20 mm", diameter: "10 mm"))),
                        Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "40 mm")))]
        let model = try await loaded(doc)
        let names = try #require(model.meshes.first?.mesh.faceNames)
        let box = try #require(model.meshes.firstIndex { $0.id == "b" })
        model.run(.thread)
        #expect(model.pendingTool == .thread)
        let boxTop = try #require(model.meshes[box].mesh.faceNames.firstIndex(of: "b.top"))
        model.click(PickID(body: box, face: boxTop), additive: false)
        #expect(model.pendingTool == .thread && model.alert == nil, "a face with nothing round by it is ignored")
        #expect(model.cursorPrompt?.hasPrefix("That face isn't round") == true)
        #expect(model.threadHighlight.isEmpty)
        // The shaft's flat end borders its round side: that's the face to thread, and it lights up.
        let top = PickID(body: 0, face: try #require(names.firstIndex(of: "c.top")))
        model.hover(top)
        #expect(model.highlighted == [PickID(body: 0, face: try #require(names.firstIndex(of: "c.side"))).raw])
        model.click(top, additive: false)
        #expect(model.pendingTool == nil)
        guard case .thread(let t) = try lastFeature(model).kind else { Issue.record("expected a thread"); return }
        #expect(t.standard == .metric && t.size == "M10x1.5" && t.length == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.dragHandle == nil, "a full-length thread has no length to drag")
        // While it's selected, the threaded section shows.
        let threaded = model.threadHighlight
        #expect(!threaded.isEmpty && threaded.allSatisfy { raw in
            model.meshes[0].mesh.faceNames[PickID(raw: raw).element].contains(".thread")
        })
        model.updateFeature(try lastFeature(model).id, "Length") { f in
            if case .thread(var t) = f.kind { t.length = "8 mm"; f.kind = .thread(t) }
        }
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.dragHandle?.label == "Length")
    }

    /// A 30 × 30 × 15 block with two 6.8 mm holes side by side.
    private func twoHoleBlock() throws -> CADDocument {
        let block = Feature(id: "b", name: "b", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "30", length: "30", height: "15")))
        var doc = CADDocument()
        doc.features = [block]
        let top = try #require(Regenerator.regenerate(doc).body("b")).faceFrame("b.top")
        let d = SIMD3<Double>(0, 0, 15) - top.origin
        let u = (d * top.xAxis).sum(), v = (d * top.yAxis).sum()
        doc.features += [("h1", -8.0), ("h2", 8.0)].map { id, dx in
            Feature(id: id, name: id, .hole(HoleFeature(face: FaceRef(body: "b", face: "b.top"), u: "\(u + dx)", v: "\(v)",
                                                        diameter: "6.8", depth: nil)))
        }
        return doc
    }

    @Test func shiftClickPicksSeveralHolesToThreadTogether() async throws {
        let doc = try twoHoleBlock()
        let model = try await loaded(doc)
        let names = try #require(model.meshes.first?.mesh.faceNames)
        let walls = names.indices.filter { names[$0].contains(".hole.wall") }.map { PickID(body: 0, face: $0) }
        #expect(walls.count == 2)
        model.run(.thread)
        model.click(walls[0], additive: true)
        #expect(model.pendingTool == .thread && model.selection == [walls[0]] && model.document.features.count == 3)
        #expect(model.cursorPrompt?.contains("Return") == true)
        model.click(walls[1], additive: true)
        model.click(walls[0], additive: true)  // ⇧-click again takes it back out
        model.click(walls[0], additive: true)
        #expect(model.selection.count == 2)
        model.confirmTool()
        #expect(model.pendingTool == nil && model.document.features.count == 4, "one feature for both holes")
        guard case .thread(let t) = try lastFeature(model).kind else { Issue.record("expected a thread"); return }
        #expect(t.faces.count == 2 && t.size == "M8x1.25")
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }

    @Test func holesOfDifferentSizesPickedTogetherAreOneThreadWithOneTolerance() async throws {
        var doc = try twoHoleBlock()
        // The second hole takes an M10: another size than the first.
        if case .hole(var h) = doc.features[2].kind { h.diameter = "8.5"; doc.features[2].kind = .hole(h) }
        let model = try await loaded(doc)
        let names = try #require(model.meshes.first?.mesh.faceNames)
        let walls = names.indices.filter { names[$0].contains(".hole.wall") }.map { PickID(body: 0, face: $0) }
        #expect(walls.count == 2)
        #expect(model.addThreads(on: walls))
        let threads = model.document.features.compactMap { f -> ThreadFeature? in if case .thread(let t) = f.kind { t } else { nil } }
        #expect(threads.count == 1, "one timeline step for all the holes")
        let t = try #require(threads.first)
        #expect(t.faces.count == 2 && t.isMixed && Set((0..<2).map { t.spec(at: $0).size }) == ["M8x1.25", "M10x1.5"], "\(t)")
        // One tolerance offset for all of them.
        let id = try lastFeature(model).id
        model.updateFeature(id, "Change Thread Tolerance") { f in
            if case .thread(var t) = f.kind { t.tolerance = "4"; t.toleranceMaterial = .abs; f.kind = .thread(t) }
        }
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        // Both holes show blue while it is selected.
        let lit = Set(model.threadHighlight.map { raw in model.meshes[PickID(raw: raw).body].mesh.faceNames[PickID(raw: raw).element] })
        #expect(lit.contains { $0.hasPrefix("\(id).") } && lit.contains { $0.hasPrefix("\(id).2.") }, "\(lit)")
        // Giving both the same size makes them alike again.
        var same = t
        same.setSpec(t.spec(at: 0), at: 1)
        #expect(!same.isMixed && same.moreSpecs.isEmpty)
    }

    @Test func clickingAHoleThreadsItAndTheOnesAlreadyPicked() async throws {
        let doc = try twoHoleBlock()
        let model = try await loaded(doc)
        let names = try #require(model.meshes.first?.mesh.faceNames)
        let walls = names.indices.filter { names[$0].contains(".hole.wall") }.map { PickID(body: 0, face: $0) }
        model.run(.thread)
        model.click(walls[0], additive: true)
        model.click(walls[1], additive: false)
        #expect(model.pendingTool == nil)
        guard case .thread(let t) = try lastFeature(model).kind else { Issue.record("expected a thread"); return }
        #expect(t.faces.count == 2)
    }

    @Test func editingAFeatureLightsUpTheFacesItMade() async throws {
        let model = try await loaded(.demo())
        var lit = 0
        for f in model.document.features {
            model.selectedFeature = f.id
            let names = model.meshes.flatMap(\.mesh.faceNames)
            let shown = model.highlighted.map { raw in model.meshes[PickID(raw: raw).body].mesh.faceNames[PickID(raw: raw).element] }
            if case .sketch = f.kind {
                #expect(shown.isEmpty, "a sketch shows itself, not faces")
                continue
            }
            #expect(shown.allSatisfy { $0.hasPrefix("\(f.id).") }, "\(f.name): \(shown)")
            #expect(Set(shown) == Set(names.filter { $0.hasPrefix("\(f.id).") }), "\(f.name) lights every face it made")
            if !shown.isEmpty { lit += 1 }
        }
        #expect(lit >= 3, "the demo's extrude, hole and fillets each leave faces on the body")
        model.selectedFeature = nil
        #expect(model.highlighted.isEmpty)
    }

    @Test func pipeFollowsAChainOfCurves() async throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30), c = s.addPoint(20, 30), d = s.addPoint(50, 50)
        for (p, x, y) in [(a, 0.0, 0.0), (b, 0, 30), (c, 20, 30), (d, 50, 50)] { s.constrain(.fix(p, x: x, y: y)) }
        s.addLine(a, b, id: "P1")
        s.addLine(b, c, id: "P2")
        s.addLine(d, s.addPoint(60, 50), id: "Other")
        #expect(Set(DocumentModel.chain(from: "P2", in: s)) == ["P1", "P2"])

        var doc = CADDocument()
        doc.features = [Feature(id: "path", name: "Path", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = try await loaded(doc)
        let p2 = try #require(model.result?.sketches["path"]?.solved.curves.firstIndex { $0.id == "P2" })
        model.run(.pipe)
        model.click(PickID(sketchCurve: p2, slot: try slot(model, "path")), additive: false)
        guard case .pipe(let pipe) = try lastFeature(model).kind else { Issue.record("expected a pipe"); return }
        #expect(Set(pipe.path.curves) == ["P1", "P2"])
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(model.dragHandle?.label == "Diameter")
    }

    private func pathModel() async throws -> DocumentModel {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(0, 30), c = s.addPoint(20, 30)
        for (p, x, y) in [(a, 0.0, 0.0), (b, 0, 30), (c, 20, 30)] { s.constrain(.fix(p, x: x, y: y)) }
        s.addLine(a, b, id: "P1")
        s.addLine(b, c, id: "P2")
        var doc = CADDocument()
        doc.features = [Feature(id: "path", name: "Path", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        return try await loaded(doc)
    }

    @Test func planeAlongPathWaitsForACurveThenPreviewsAndMakesThePlane() async throws {
        let model = try await pathModel()
        let p1 = try #require(model.result?.sketches["path"]?.solved.curves.firstIndex { $0.id == "P1" })
        model.run(.planeAlongPath)
        #expect(model.pendingTool == .planeAlongPath && model.pathPlane?.path == nil)
        #expect(model.pathPlaneFrame == nil, "nothing to show before a path is picked")
        model.click(PickID(sketchCurve: p1, slot: try slot(model, "path")), additive: false)
        let draft = try #require(model.pathPlane)
        #expect(Set(try #require(draft.path).curves) == ["P1", "P2"], "the whole chain joined to the curve is the path")
        #expect(draft.position == "0.5" && model.pendingTool == .planeAlongPath)
        // Nothing is in the timeline yet, but the plane is on show: 25 mm of the 50 along (the corner is at 30).
        #expect(model.document.features.count == 1)
        let preview = try #require(model.pathPlaneFrame)
        #expect(abs(preview.origin.x - 0) < 1e-6 && abs(preview.origin.y - 25) < 1e-6, "\(preview.origin)")
        #expect(model.sketchOverlay().moveHandle.first?.id == PickID.pathHandle.raw, "the dot sits on the path")
        #expect(model.dimensionLabels().first?.text == "0.5")

        // Dragging the dot: a ray straight down at y = 15 is 15 of the 50 mm.
        model.beginPathPlaneDrag()
        model.dragPathPlane(rayOrigin: SIMD3(0, 15, 100), direction: SIMD3(0, 0, -1))
        model.endPathPlaneDrag()
        #expect(model.pathPlane?.position == "0.3", "\(model.pathPlane?.position ?? "")")
        #expect(abs((try #require(model.pathPlaneFrame)).origin.y - 15) < 1e-6)
        // ... and typing a position or an offset works the same way.
        model.setPathPlane(position: "1", offset: "2 mm")
        let end = try #require(model.pathPlaneFrame)
        #expect(abs(end.origin.x - 22) < 1e-6 && abs(end.origin.y - 30) < 1e-6, "\(end.origin)")

        model.setPathPlane(position: "0.3", offset: "0 mm")
        #expect(model.commitPathPlane())
        guard case .plane(let plane) = try lastFeature(model).kind else { Issue.record("expected a plane"); return }
        #expect(plane.along?.position == "0.3" && plane.offset == "0 mm")
        #expect(model.pendingTool == nil && model.pathPlane == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let frame = try #require(model.result?.planes[try lastFeature(model).id])
        #expect(abs(frame.origin.y - 15) < 1e-9 && abs(abs(frame.normal.y) - 1) < 1e-9, "\(frame)")
    }

    @Test func planeAlongPathCancelsLeavingNothingBehind() async throws {
        let model = try await pathModel()
        let p2 = try #require(model.result?.sketches["path"]?.solved.curves.firstIndex { $0.id == "P2" })
        model.run(.planeAlongPath)
        #expect(!model.commitPathPlane(), "no path yet: OK does nothing")
        model.click(PickID(sketchCurve: p2, slot: try slot(model, "path")), additive: false)
        #expect(model.pathPlane?.path != nil)
        model.clearPlanePath()
        #expect(model.pathPlane?.path == nil && model.pendingTool == .planeAlongPath, "the cross in the panel goes back to picking")
        model.click(PickID(sketchCurve: p2, slot: try slot(model, "path")), additive: false)
        model.cancelTool()
        #expect(model.pathPlane == nil && model.pathPlaneFrame == nil)
        #expect(model.document.features.count == 1)
        #expect(model.sketchOverlay().moveHandle.isEmpty)
    }

    @Test func planeAlongPathStartsFromACurveThatIsAlreadySelected() async throws {
        let model = try await pathModel()
        let p1 = try #require(model.result?.sketches["path"]?.solved.curves.firstIndex { $0.id == "P1" })
        model.selection = [PickID(sketchCurve: p1, slot: try slot(model, "path"))]
        model.run(.planeAlongPath)
        #expect(model.pathPlane?.path != nil && model.pathPlaneFrame != nil)
    }

    /// A 40 x 20 x 10 box "b" on the floor.
    private func boxModel() async throws -> DocumentModel {
        var doc = CADDocument()
        doc.features = [Feature(id: "b", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "0 mm", v: "0 mm", width: "40 mm", length: "20 mm", height: "10 mm")))]
        let model = try await loaded(doc)
        try await settle(model)
        return model
    }

    /// The pick of the box's straight edge along X at the top front (y = -10, z = 10).
    private func topFrontEdge(_ model: DocumentModel) throws -> PickID {
        let box = try #require(model.meshes.firstIndex { $0.id == "b" })
        let body = try #require(model.result?.body("b"))
        let names = model.meshes[box].mesh.edgeNames
        let index = try #require(names.indices.first { i in
            guard let l = try? body.edgeLine(names[i]) else { return false }
            return abs(abs(l.direction.x) - 1) < 1e-9 && abs(l.origin.z - 10) < 1e-6 && abs(l.origin.y + 10) < 1e-6
        })
        return PickID(body: box, edge: index)
    }

    @Test func planeAtAngleTakesABaseAndAnAxisAndPreviewsTheTurnedPlane() async throws {
        let model = try await boxModel()
        let box = try #require(model.meshes.firstIndex { $0.id == "b" })
        let top = try #require(model.meshes[box].mesh.faceNames.firstIndex(of: "b.top"))
        model.run(.planeAtAngle)
        #expect(model.pendingTool == .planeAtAngle && model.anglePlane?.base == nil)
        #expect(model.anglePlaneOutcome.frame == nil, "nothing to show yet")
        model.click(PickID(body: box, face: top), additive: false)
        guard case .face(let face)? = model.anglePlane?.base else { Issue.record("expected the top face as the base"); return }
        #expect(face.face == "b.top" && model.anglePlane?.axis == nil)
        model.click(try topFrontEdge(model), additive: false)
        guard case .edge(let edge)? = model.anglePlane?.axis else { Issue.record("expected the edge as the axis"); return }
        #expect(edge.body == "b")
        #expect(model.highlighted.count == 2, "the base and the axis stay lit")
        model.setAnglePlane { $0.angle = "30 deg" }
        let frame = try #require(model.anglePlaneOutcome.frame)
        // The top face (z = 10, normal up) leans 30° about its front edge: the normal tips by 30° off vertical.
        #expect(abs(abs(frame.normal.z) - (3.0.squareRoot() / 2)) < 1e-6, "\(frame.normal)")
        #expect(model.document.features.count == 1, "nothing is in the timeline until OK")
        #expect(model.commitAnglePlane())
        guard case .plane(let plane) = try lastFeature(model).kind else { Issue.record("expected a plane"); return }
        #expect(plane.turn != nil && plane.angle == "30 deg" && plane.turn?.directionOnly == false)
        #expect(model.pendingTool == nil && model.anglePlane == nil)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }

    @Test func planeAtAngleAxisFromTheMenuDirectionOnlyAndPivotPick() async throws {
        let model = try await pathModel()
        model.run(.planeAtAngle)
        model.setAnglePlane { $0.base = .xy }
        #expect(model.anglePlaneOutcome.frame == nil, "no axis yet")
        model.chooseAngleAxis(.x)
        model.setAnglePlane { $0.angle = "90 deg" }
        #expect(model.anglePlaneOutcome.frame != nil)
        // Only the direction counts: the Z axis is square to the floor, so there is nothing to turn about, and the panel says why.
        model.chooseAngleAxis(.z)
        model.setAnglePlane { $0.directionOnly = true }
        #expect(model.anglePlaneOutcome.frame == nil && model.anglePlaneOutcome.problem?.contains("square to the base") == true)
        #expect(!model.commitAnglePlane(), "OK does nothing while the plane can't be made")
        model.chooseAngleAxis(.x)
        // The pivot is taken where the next click on the base lands.
        model.setAnglePlane { $0.choosingPivot = true }
        model.clickRay = (SIMD3(0, 12.345, 50), SIMD3(0, 0, -1))
        model.click(PickID(plane: 0), additive: false)
        #expect(model.anglePlane?.pivotU == "0 mm" && model.anglePlane?.pivotV == "12.35 mm" && model.anglePlane?.choosingPivot == false,
                "\(model.anglePlane?.pivotU ?? "") \(model.anglePlane?.pivotV ?? "")")
        let frame = try #require(model.anglePlaneOutcome.frame)
        #expect(abs(frame.origin.y - 12.35) < 1e-9 && abs(abs(frame.origin.z) - 12.35) < 1e-9, "turned 90° about the point: \(frame.origin)")
        model.cancelTool()
        #expect(model.anglePlane == nil && model.document.features.count == 1)
    }

    @Test func aConstructionPlaneHidesOnceASketchDrawnOnItIsLeft() async throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 10, y: 0))
        s.addLine(a, b, id: "L")
        var doc = CADDocument()
        doc.features = [Feature(id: "up", name: "Up", .plane(PlaneFeature(base: .xy, offset: "20 mm"))),
                        Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .plane("up"), sketch: s))),
                        Feature(id: "fl", name: "Floor sketch", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = try await loaded(doc)
        // Entering the sketch leaves the plane showing; leaving it, with a line drawn, hides it.
        model.editSketch("sk")
        #expect(model.sketchSession != nil && !model.isHidden("up"))
        model.finishSketch()
        #expect(model.isHidden("up"), "the plane has done its job")
        // Bring it back by hand; a sketch on an origin plane touches no plane, and an empty sketch on the plane leaves it be.
        model.setHidden(["up"], false)
        model.editSketch("fl")
        model.finishSketch()
        #expect(!model.isHidden("up"))
        model.beginSketch(on: .plane("up"))
        model.finishSketch()
        #expect(!model.isHidden("up"), "nothing was drawn")
    }

    @Test func nearestPointOnAPathAndFractionText() {
        let hit = DocumentModel.nearest(ray: (SIMD3(5, 2, 10), SIMD3(0, 0, -1)), segment: (SIMD3(0, 0, 0), SIMD3(10, 0, 0)))
        #expect(abs(hit.t - 0.5) < 1e-9 && abs(hit.distance - 2) < 1e-9)
        let past = DocumentModel.nearest(ray: (SIMD3(50, 0, 10), SIMD3(0, 0, -1)), segment: (SIMD3(0, 0, 0), SIMD3(10, 0, 0)))
        #expect(past.t == 1, "held at the end of the segment")
        #expect(DocumentModel.fractionText(0.30000000001) == "0.3" && DocumentModel.fractionText(1.2) == "1" && DocumentModel.fractionText(-1) == "0")
        #expect(DocumentModel.fractionText(0.12345) == "0.123")
    }

    @Test func hidingChangesTheViewNotTheModel() async throws {
        let model = try await loaded(.demo())
        let revision = model.sceneRevision
        model.setHidden(["plate"], true)
        #expect(model.isHidden("plate") && model.visibleMeshes.isEmpty && model.meshes.count == 1)
        #expect(!model.isRegenerating && model.sceneRevision == revision + 1, "no rebuild for a visibility change")
        model.setHidden(["plate"], false)
        #expect(model.visibleMeshes.count == 1)

        #expect(model.sketchOverlay().regionIndices.isEmpty == false, "unhidden sketches show their profiles")
        model.setHidden(model.sketches.map(\.id), true)
        #expect(model.sketchOverlay().regionIndices.isEmpty && model.sketchOverlay().inactive.isEmpty)
        model.selectedFeature = "base"
        #expect(model.sketchOverlay().regionIndices.isEmpty && model.sketchOverlay().inactive.isEmpty,
                "a hidden sketch stays hidden when selected")
        try await settle(model)
    }

    @Test func escapeCancelsAWaitingTool() async throws {
        let model = try await loaded(.demo())
        model.run(.fillet)
        #expect(model.pendingTool == .fillet && model.dragHandle == nil)
        model.cancelTool()
        #expect(model.pendingTool == nil)
        model.run(.loft)
        model.run(.loft)  // pressing it again with nothing picked cancels it
        #expect(model.pendingTool == nil)
        try await settle(model)
    }
}

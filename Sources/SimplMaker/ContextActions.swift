// What the viewport offers for the thing under the cursor: the right-click menu, double-click to
// edit, and the small options panel shown next to a feature's drag handle.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// One entry of the viewport's right-click menu.
enum ContextItem {
    case action(String, symbol: String? = nil, enabled: Bool = true, @MainActor () -> Void)
    case submenu(String, [ContextItem])
    case separator

    var title: String? {
        switch self {
        case .action(let t, _, _, _), .submenu(let t, _): return t
        case .separator: return nil
        }
    }
}

extension DocumentModel {
    // MARK: right-click menu

    /// The right-click menu for what's under the cursor. `ray` is the click's pointer ray, for
    /// placing things where the user clicked.
    func contextItems(for pick: PickID?, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)? = nil) -> [ContextItem] {
        if let tool = pendingTool {
            return [.action("Cancel \(tool.rawValue)", symbol: "xmark.circle") { self.cancelTool() }]
        }
        if let session = sketchSession { return sketchItems(session) }
        guard let pick else { return backgroundItems() }
        switch pick.kind {
        case .face: return faceItems(pick, ray: ray)
        case .edge: return edgeItems(pick)
        case .region: return profileItems(pick)
        case .sketchCurve: return curveItems(pick)
        case .plane: return planeItems(pick)
        default: return backgroundItems()
        }
    }

    private func faceItems(_ pick: PickID, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)?) -> [ContextItem] {
        guard let ref = faceRef(pick) else { return backgroundItems() }
        let flat = (try? result?.body(ref.body)?.faceFrame(ref.face)) != nil
        clickRay = ray
        let round = roundFace(pick) != nil
        clickRay = nil
        var items: [ContextItem] = [
            .action("Sketch on Face", symbol: "pencil.and.outline", enabled: flat) { self.beginSketch(on: .face(ref)) },
            .action("Extrude Face", symbol: DesignTool.extrude.symbol, enabled: flat) {
                self.selection = [pick]
                self.run(.extrude)
            },
            .action("Insert Image…", symbol: "photo", enabled: flat) {
                self.selection = [pick]
                self.run(.canvas)
            },
            .action("Hole Here", symbol: DesignTool.hole.symbol, enabled: flat) {
                self.clickRay = ray
                self.place(.hole, on: pick)
            },
            .action("Thread…", symbol: DesignTool.thread.symbol, enabled: round) {
                self.clickRay = ray
                self.addThread(on: pick)
            },
            .separator,
            .action("Fillet Face Edges", symbol: DesignTool.fillet.symbol) { self.selection = [pick]; self.run(.fillet) },
            .action("Chamfer Face Edges", symbol: DesignTool.chamfer.symbol) { self.selection = [pick]; self.run(.chamfer) },
            .action("Draft Face", symbol: DesignTool.draft.symbol) { self.selection = [pick]; self.run(.draft) },
            .action("Measure", symbol: DesignTool.measure.symbol) { self.selection = [pick]; self.run(.measure) },
            .action("Section Analysis at Face", symbol: DesignTool.sectionAnalysis.symbol, enabled: flat) {
                self.selection = [pick]
                self.run(.sectionAnalysis)
            },
            .separator,
            .action("Move or Rotate Body", symbol: "arrow.up.and.down.and.arrow.left.and.right") { self.selection = [pick]; self.run(.move) },
            .action("Scale Body", symbol: DesignTool.scale.symbol) { self.selection = [pick]; self.run(.scale) },
            .action("Lay Face on Floor", symbol: DesignTool.layOnFloor.symbol, enabled: flat) { self.selection = [pick]; self.run(.layOnFloor) },
            .action("Split Body…", symbol: DesignTool.split.symbol) { self.selection = [pick]; self.run(.split) },
            .action("Split into Parts", symbol: DesignTool.split.symbol) { self.splitIntoParts(bodies: [ref.body]) },
            .action("Combine with Other Bodies…", symbol: "square.on.square.intersection.dashed") {
                self.selection = [pick]
                self.run(.combine)
            },
        ]
        items += ownerItems(featureMaking(face: ref.face), body: ref.body)
        return items
    }

    private func edgeItems(_ pick: PickID) -> [ContextItem] {
        // Keep a multi-edge selection that includes this edge; otherwise act on this edge alone.
        let pickEdge = { if !self.selection.contains(pick) { self.selection = [pick] } }
        var items: [ContextItem] = [
            .action("Fillet", symbol: DesignTool.fillet.symbol) { pickEdge(); self.run(.fillet) },
            .action("Chamfer", symbol: DesignTool.chamfer.symbol) { pickEdge(); self.run(.chamfer) },
            .action("Measure", symbol: DesignTool.measure.symbol) { self.selection = [pick]; self.run(.measure) },
        ]
        if let body = meshes[safe: pick.body]?.id { items += ownerItems(nil, body: body) }
        return items
    }

    private func profileItems(_ pick: PickID) -> [ContextItem] {
        guard let p = profile(of: pick) else { return backgroundItems() }
        let pickProfile = { if !self.selection.contains(pick) { self.selection = self.profileGroup(of: pick) } }
        var items: [ContextItem] = ([.extrude, .revolve, .sweep, .loft] as [DesignTool]).map { tool in
            .action(tool.rawValue, symbol: tool.symbol) { pickProfile(); self.run(tool) }
        }
        items += sketchOwnerItems(p.sketch)
        return items
    }

    private func curveItems(_ pick: PickID) -> [ContextItem] {
        guard let c = curve(of: pick) else { return backgroundItems() }
        let pickCurve = { if !self.selection.contains(pick) { self.selection = [pick] } }
        var items: [ContextItem] = ([.pipe, .rib] as [DesignTool]).map { tool in
            .action(tool == .pipe ? "Pipe Along" : "Rib", symbol: tool.symbol) { pickCurve(); self.run(tool) }
        }
        items += sketchOwnerItems(c.sketch)
        return items
    }

    private func sketchOwnerItems(_ sketch: FeatureID) -> [ContextItem] {
        [.separator,
         .action("Edit \(featureName(sketch))", symbol: "pencil") { self.editSketch(sketch) },
         .action("Move or Rotate \(featureName(sketch))", symbol: "arrow.up.and.down.and.arrow.left.and.right") { self.move(sketches: [sketch]) },
         .action("Scale \(featureName(sketch))", symbol: "arrow.up.left.and.arrow.down.right") { self.scale(sketches: [sketch]) },
         .action("Hide \(featureName(sketch))", symbol: "eye.slash") { self.setHidden([sketch], true) },
         .action("Export \(featureName(sketch)) as DXF…", symbol: "square.and.arrow.up") { self.exportDXF(sketch: sketch) }]
    }

    /// "Edit Extrude1" for the feature that made a face, and "Hide Body1".
    private func ownerItems(_ feature: FeatureID?, body: FeatureID) -> [ContextItem] {
        var items: [ContextItem] = [.separator]
        if let feature { items.append(.action("Edit \(featureName(feature))", symbol: "pencil") { self.editFeature(feature) }) }
        let bodyName = bodies.first { $0.id == body }?.name ?? "Body"
        items.append(.action("Appearance…", symbol: "paintpalette") { self.openAppearance(for: body) })
        items.append(.action("Hide \(bodyName)", symbol: "eye.slash") { self.setHidden([body], true) })
        items.append(.submenu("Export \(bodyName)", [
            .action("STL…") { self.export(bodies: [body], format: .stl) },
            .action("3MF…") { self.export(bodies: [body], format: .threeMF) },
            .action("STEP…") { self.export(bodies: [body], format: .step) },
        ]))
        return items
    }

    private func planeItems(_ pick: PickID) -> [ContextItem] {
        guard let id = constructionPlane(of: pick) else { return backgroundItems() }
        let name = featureName(id)
        return [
            .action("Sketch on \(name)", symbol: "pencil.and.outline") { self.beginSketch(on: .plane(id)) },
            .action("New Plane from \(name)", symbol: DesignTool.plane.symbol) {
                self.add(Feature(name: self.document.nextName("Plane"), .plane(PlaneFeature(base: .plane(id)))))
            },
            .action("Insert Image…", symbol: "photo") { self.selection = [pick]; self.run(.canvas) },
            .separator,
            .action("Edit \(name)", symbol: "pencil") { self.editFeature(id) },
            .action("Hide \(name)", symbol: "eye.slash") { self.setHidden([id], true) },
        ]
    }

    private func backgroundItems() -> [ContextItem] {
        var items: [ContextItem] = [
            .action("New Sketch…", symbol: "pencil.and.outline") { self.startSketch() },
            .submenu("Add Shape", DesignTool.primitives.map { tool in .action(tool.rawValue, symbol: tool.symbol) { self.run(tool) } }),
            .separator,
            .action("Fit All", symbol: "arrow.up.left.and.arrow.down.right") { self.fitView() },
            .submenu("Standard Views", StandardView.allCases.map { v in .action(v.title) { self.show(v) } }),
        ]
        if !document.hidden.isEmpty {
            items.append(.action("Show All", symbol: "eye") { self.setHidden(Array(self.document.hidden), false) })
        }
        return items
    }

    private func sketchItems(_ session: SketchSession) -> [ContextItem] {
        var items: [ContextItem] = [.action("Finish Sketch", symbol: "checkmark.circle") { self.finishSketch() }, .separator]
        if !session.selection.isEmpty {
            let constraints = ConstraintTool.allCases.filter { session.canApply($0) }
            if !constraints.isEmpty {
                items.append(.submenu("Constrain", constraints.map { c in .action(c.rawValue) { self.sketchCommand { $0.apply(c) } } }))
            }
            if session.canToggleConstruction {
                items.append(.action("Construction", symbol: "pencil.slash") { self.sketchCommand { $0.toggleConstruction() } })
            }
            items.append(.action("Delete", symbol: "trash") { self.sketchCommand { $0.deleteSelection() } })
            items.append(.separator)
        }
        items += ([.select] + SketchTool.draw + [.dimension, .distance]).map { tool in
            .action(tool.rawValue, symbol: tool.symbol, enabled: session.tool != tool) { self.setSketchTool(tool) }
        }
        return items
    }

    // MARK: editing a feature from the viewport

    /// The feature a face's persistent name says made it ("plate.end" → "plate", "h.hole.wall" → "h").
    func featureMaking(face name: String) -> FeatureID? {
        guard let prefix = name.split(separator: ".").first.map(String.init),
              document.features.contains(where: { $0.id == prefix }) else { return nil }
        return prefix
    }

    /// Opens a feature for editing: a sketch goes into sketch mode; anything else is selected with
    /// its drag handle and size field ready for typing.
    func editFeature(_ id: FeatureID) {
        guard !isLocked(id), let f = document.features.first(where: { $0.id == id }) else { return }
        if case .sketch = f.kind { editSketch(id); return }
        // A failed extrude, revolve or sweep usually lost a profile: pick its profiles again.
        if result?.errors[id] != nil, profileSource(id) != nil { reselectProfiles(id); return }
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        bringIntoModel(id)
        selection = []
        selectedFeature = id
        showInspector = true
        handleFocusRequest += 1
    }

    /// Double-click in the viewport: edit the feature that made the face, or the sketch of a curve
    /// or profile; on an edge, select the loop of edges it's part of. `viewDirection` (where the
    /// camera looks) decides which of an edge's two faces' loops: the face turned toward you.
    func doubleClick(_ pick: PickID?, viewDirection: SIMD3<Double> = SIMD3(0, 0, -1), additive: Bool = false) {
        guard sketchSession == nil, let pick, !isLockedPick(pick) else { return }
        if pick.kind == .edge {
            selectEdgeLoop(pick, viewDirection: viewDirection, additive: additive)
            return
        }
        guard pendingTool == nil else { return }
        switch pick.kind {
        case .face:
            if let ref = faceRef(pick), let owner = featureMaking(face: ref.face) { editFeature(owner) }
        case .region:
            if let p = profile(of: pick) { editSketch(p.sketch) }
        case .sketchCurve:
            if let c = curve(of: pick) { editSketch(c.sketch) }
        default:
            break
        }
    }

    /// Selects every edge in the loop through a picked edge, around the face that faces the viewer most.
    func selectEdgeLoop(_ pick: PickID, viewDirection: SIMD3<Double>, additive: Bool) {
        guard pick.isEdge, let m = meshes[safe: pick.body], pick.element < m.mesh.edgeNames.count,
              let body = result?.body(m.id) else { return }
        let edge = m.mesh.edgeNames[pick.element]
        let faces = (try? body.edgeFaces(edge)) ?? []
        // How much a face turns toward the camera: its triangles' normals against the view.
        func facing(_ name: String) -> Double {
            guard let f = m.mesh.faceNames.firstIndex(of: name) else { return -.infinity }
            var sum = SIMD3<Double>.zero
            for (t, face) in m.mesh.triangleFace.enumerated() where Int(face) == f {
                for k in 0..<3 {
                    let v = Int(m.mesh.indices[t * 3 + k]) * 3
                    sum += SIMD3(Double(m.mesh.normals[v]), Double(m.mesh.normals[v + 1]), Double(m.mesh.normals[v + 2]))
                }
            }
            let len = simd_length(sum)
            return len > 0 ? -simd_dot(sum / len, viewDirection) : -.infinity
        }
        guard let face = faces.max(by: { facing($0) < facing($1) }),
              let loop = try? body.loopEdges(face: face, edge: edge) else { return }
        let picks = loop.compactMap { name in m.mesh.edgeNames.firstIndex(of: name).map { PickID(body: pick.body, edge: $0) } }
        guard !picks.isEmpty, pendingTool?.accepts(.edge) ?? true else { return }
        // A waiting tool (Fillet, Chamfer) collects edges, so the loop adds to what it has.
        let add = additive || pendingTool != nil
        selection = add ? selection + picks.filter { !selection.contains($0) } : picks
        overlayRevision += 1
    }

    // MARK: the options panel next to the handle

    /// Join / Cut / New Body / Intersect of a feature, if it has one.
    func operation(of id: FeatureID) -> BodyOperation? {
        switch document.features.first(where: { $0.id == id })?.kind {
        case .extrude(let e)?: return e.operation
        case .revolve(let r)?: return r.operation
        case .sweep(let s)?: return s.operation
        case .loft(let l)?: return l.operation
        case .twistSweep(let t)?: return t.operation
        case .primitive(let p)?: return p.operation
        case .pipe(let p)?: return p.operation
        default: return nil
        }
    }

    func setOperation(_ op: BodyOperation, of id: FeatureID) {
        guard operation(of: id) != op else { return }
        storeTypedSize()
        updateFeature(id, "Change Operation") { f in
            switch f.kind {
            case .extrude(var e): e.operation = op; f.kind = .extrude(e)
            case .revolve(var r): r.operation = op; f.kind = .revolve(r)
            case .sweep(var s): s.operation = op; f.kind = .sweep(s)
            case .loft(var l): l.operation = op; f.kind = .loft(l)
            case .twistSweep(var t): t.operation = op; f.kind = .twistSweep(t)
            case .primitive(var p): p.operation = op; f.kind = .primitive(p)
            case .pipe(var p): p.operation = op; f.kind = .pipe(p)
            default: break
            }
        }
    }

    /// The axis of a move's arrow or a rotation; nil for other features.
    func transformAxis(_ id: FeatureID) -> Axis3? {
        switch document.features.first(where: { $0.id == id })?.kind {
        case .move(let m)?: return m.arrow
        case .rotate(let r)?: return r.axis
        default: return nil
        }
    }

    func setTransformAxis(_ a: Axis3, of id: FeatureID) {
        guard transformAxis(id) != a else { return }
        storeTypedSize()  // what was typed for X stays with X
        if isMoveFeature(id) {
            setPresentation(id) { f in if case .move(var m) = f.kind { m.arrow = a; f.kind = .move(m) } }  // no undo step: nothing changes
            return
        }
        updateFeature(id, "Change Axis") { f in
            switch f.kind {
            case .rotate(var r): r.axis = a; f.kind = .rotate(r)
            default: break
            }
        }
    }

    func isMoveFeature(_ id: FeatureID) -> Bool {
        if case .move? = document.features.first(where: { $0.id == id })?.kind { return true }
        return false
    }

    /// Makes the typed field of a Move feature set a turn (or a distance).
    func setRotating(_ rotating: Bool, of id: FeatureID) {
        guard isRotating(id) != rotating else { return }
        storeTypedSize()
        setPresentation(id) { f in if case .move(var m) = f.kind { m.rotating = rotating; f.kind = .move(m) } }
    }

    /// Whether an extrude goes against its sketch's (or face's) normal; nil for other features.
    func isFlipped(_ id: FeatureID) -> Bool? {
        switch document.features.first(where: { $0.id == id })?.kind {
        case .extrude(let e)?: return e.flipped
        case .chamfer(let e)? where e.mode != .equalDistance: return e.flipped  // which face the first distance is on
        default: return nil
        }
    }

    func toggleFlip(_ id: FeatureID) {
        storeTypedSize()
        updateFeature(id, "Flip") { f in
            if case .extrude(var e) = f.kind { e.flipped.toggle(); f.kind = .extrude(e) }
            if case .chamfer(var e) = f.kind { e.flipped.toggle(); f.kind = .chamfer(e) }
        }
    }

    /// Whether the feature is an extrude of sketch profiles, which can start on another face than the sketch's plane.
    func canStartOnFace(_ id: FeatureID) -> Bool {
        if case .extrude(let e)? = document.features.first(where: { $0.id == id })?.kind { return e.face == nil }
        return false
    }

    /// The face an extrude has been told to start from, if any.
    func startFace(of id: FeatureID) -> FaceRef? {
        if case .extrude(let e)? = document.features.first(where: { $0.id == id })?.kind { return e.start }
        return nil
    }

    /// The one flat face picked in the viewport, which an extrude could start from.
    var selectedFlatFace: FaceRef? {
        guard selection.count == 1, let pick = selection.first, let ref = faceRef(pick),
              let body = result?.body(ref.body), (try? body.faceFrame(ref.face)) != nil else { return nil }
        return ref
    }

    /// Makes an extrude start on `face` (carrying its profile there), or back on the sketch plane when nil.
    func setStartFace(_ face: FaceRef?, of id: FeatureID) {
        guard startFace(of: id) != face else { return }
        storeTypedSize()
        updateFeature(id, face == nil ? "Start on the Profile Plane" : "Start from Face") { f in
            if case .extrude(var e) = f.kind { e.start = face; f.kind = .extrude(e) }
        }
        selection = []
    }

    /// Why a feature failed to build, without the repeated "name:" the kernel puts in front.
    func errorText(of id: FeatureID) -> String? {
        guard let error = result?.errors[id] else { return nil }
        let parts = error.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 && parts[0].lowercased() == featureKindWord(id) ? parts[1] : error
    }

    private func featureKindWord(_ id: FeatureID) -> String {
        document.features.first { $0.id == id }?.typeName.lowercased() ?? ""
    }

    /// Cancel on a feature that was just created: take it out again (and show its sketches again).
    func cancelNewFeature() {
        guard let id = newFeature, let before = documentBeforeNewFeature else { return finishFeatureEdit() }
        let name = featureName(id)
        mutate("Cancel \(name)") { doc in
            doc.features.removeAll { $0.id == id }
            doc.hidden = before.hidden
            doc.rollback = before.rollback
        }
        newFeature = nil
        selectedFeature = nil
        selection = []
    }
}

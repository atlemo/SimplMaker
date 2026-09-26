// App state: the document, undo, background regeneration, selection, files.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import Observation
import simd
import UniformTypeIdentifiers

/// A problem to report in an alert: the title states what went wrong, the message what to do.
struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// A tessellated body for the viewport.
struct BodyMesh: Sendable {
    var index: Int
    var id: FeatureID
    var name: String
    var mesh: Mesh
}

@MainActor
@Observable
final class DocumentModel {
    private(set) var document: CADDocument
    private(set) var result: RegenResult?
    private(set) var meshes: [BodyMesh] = []
    private(set) var sceneRevision = 0
    private(set) var fitRevision = 0
    private(set) var isRegenerating = false

    var selection: [PickID] = []
    private(set) var hovered: PickID?
    private var selectedFeatureStorage: FeatureID?
    var selectedFeature: FeatureID? {
        get { selectedFeatureStorage }
        set {
            guard newValue != selectedFeatureStorage else { return }
            selectedFeatureStorage = newValue
            overlayRevision += 1
        }
    }
    /// The sketch being edited, if any.
    private(set) var sketchSession: SketchSession?
    /// A new sketch is waiting for the user to click an origin plane or a flat face.
    private(set) var isPickingSketchPlane = false
    /// A tool waiting for the user to pick what it needs (a profile, a path, a face...). See DesignTools.swift.
    var pendingTool: DesignTool?
    /// The pointer ray of the latest click in the viewport, for placing things where the user clicked.
    @ObservationIgnored var clickRay: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// Side length of the origin plane squares shown while picking, in mm.
    var sketchPlaneSize: Double = 25
    /// Bumped whenever the sketch overlay needs rebuilding.
    var overlayRevision = 0
    /// Camera request for the viewport (look at a sketch plane, standard views), with a revision counter.
    private(set) var cameraCommand: (command: CameraCommand, revision: Int)?
    var showInspector = true
    var orthographic = false
    var fileURL: URL?
    var alert: AlertInfo?

    @ObservationIgnored var undoManager: UndoManager?
    /// Called with every new document, so the file can snapshot it off the main thread.
    @ObservationIgnored var onDocumentChange: (@Sendable (CADDocument) -> Void)?
    @ObservationIgnored private var generation = 0

    init(document: CADDocument = CADDocument()) {
        self.document = document
        regenerate(fit: true)
    }

    // MARK: editing (every change goes through here: undo + regenerate)

    func mutate(_ actionName: String, _ change: (inout CADDocument) -> Void) {
        var doc = document
        change(&doc)
        guard doc != document else { return }
        replace(with: doc, actionName: actionName)
    }

    private func replace(with doc: CADDocument, actionName: String) {
        let old = document
        document = doc
        onDocumentChange?(doc)
        syncSession()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replace(with: old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        if doc.ignoringVisibility == old.ignoringVisibility {  // only shown/hidden changed: nothing to rebuild
            sceneRevision += 1
            overlayRevision += 1
        } else {
            regenerate()
        }
    }

    // MARK: visibility

    func isHidden(_ id: FeatureID) -> Bool { document.hidden.contains(id) }

    /// Shows or hides bodies and sketches (by the id of the feature that made them), as one undo step.
    func setHidden(_ ids: [FeatureID], _ hidden: Bool) {
        let noun = ids.count == 1 ? (document.features.first { $0.id == ids[0] }.map { if case .sketch = $0.kind { "Sketch" } else { "Body" } } ?? "") : "Items"
        mutate(hidden ? "Hide \(noun)" : "Show \(noun)") { doc in
            if hidden { doc.hidden.formUnion(ids) } else { doc.hidden.subtract(ids) }
        }
        if hidden { selection.removeAll { $0.isFace || $0.isEdge ? ids.contains(meshes[safe: $0.body]?.id ?? "") : false } }
    }

    /// Bodies the viewport draws.
    var visibleMeshes: [BodyMesh] { meshes.filter { !document.hidden.contains($0.id) } }

    /// Bodies for the browser, in creation order.
    var bodies: [BodyResult] { result?.bodies ?? [] }

    /// Sketch features for the browser.
    var sketches: [Feature] { document.features.filter { if case .sketch = $0.kind { true } else { false } } }

    func setParameter(_ name: String, expression: String) {
        mutate("Change \(name)") { doc in
            if let i = doc.parameters.firstIndex(where: { $0.name == name }) { doc.parameters[i].expression = expression }
        }
    }

    func addParameter() {
        mutate("Add Parameter") { doc in
            var n = 1
            while doc.parameters.contains(where: { $0.name == "p\(n)" }) { n += 1 }
            doc.parameters.append(Parameter("p\(n)", "10 mm"))
        }
    }

    func removeParameter(_ name: String) {
        mutate("Delete \(name)") { $0.parameters.removeAll { $0.name == name } }
    }

    func updateFeature(_ id: FeatureID, _ actionName: String, _ change: (inout Feature) -> Void) {
        mutate(actionName) { doc in
            if let i = doc.index(of: id) { change(&doc.features[i]) }
        }
    }

    func deleteFeature(_ id: FeatureID) {
        if sketchSession?.featureID == id { sketchSession = nil }
        mutate("Delete Feature") { $0.features.removeAll { $0.id == id } }
        if selectedFeature == id { selectedFeature = nil }
    }

    /// Creates a fillet or chamfer on the selected edges.
    func addEdgeFeature(fillet: Bool) {
        let edges: [EdgeRef] = selection.compactMap { pick in
            guard pick.isEdge, pick.body < meshes.count else { return nil }
            let m = meshes[pick.body]
            guard pick.element < m.mesh.edgeNames.count else { return nil }
            return EdgeRef(body: m.id, edge: m.mesh.edgeNames[pick.element])
        }
        guard !edges.isEmpty else { return }
        let base = fillet ? "Fillet" : "Chamfer"
        let edgeFeature = EdgeFeature(edges: edges, size: fillet ? "2 mm" : "1 mm")
        add(Feature(name: document.nextName(base), fillet ? .fillet(edgeFeature) : .chamfer(edgeFeature)))
    }

    /// Adds a new feature as one undo step, hides the sketches it uses, and selects it so its
    /// drag handle and size field appear.
    func add(_ feature: Feature) {
        mutate("Add \(feature.typeName)") { doc in
            doc.features.append(feature)
            doc.hidden.formUnion(feature.sketchesUsed)
        }
        selection = []
        pendingTool = nil
        selectedFeature = feature.id
        handleFocusRequest += 1
    }

    var selectedEdgeCount: Int { selection.filter(\.isEdge).count }

    // MARK: regeneration

    func regenerate(fit: Bool = false, preview: CADDocument? = nil, previewFeature: FeatureID? = nil) {
        generation += 1
        let gen = generation
        var doc = preview ?? document
        if let session = sketchSession, let i = doc.index(of: session.featureID) {
            doc.rollback = min(doc.rollback ?? Int.max, i + 1)  // show the model as it was at this sketch
        }
        isRegenerating = true
        Task.detached(priority: .userInitiated) {
            let r = Regenerator.regenerate(doc)
            var meshes: [BodyMesh] = []
            for (i, b) in r.bodies.enumerated() {
                if let mesh = try? b.body.tessellate() { meshes.append(BodyMesh(index: i, id: b.id, name: b.name, mesh: mesh)) }
            }
            await self.apply(r, meshes, generation: gen, fit: fit, previewFeature: previewFeature)
        }
    }

    private func apply(_ r: RegenResult, _ meshes: [BodyMesh], generation gen: Int, fit: Bool, previewFeature: FeatureID?) {
        guard gen == generation else { return }  // a newer edit is already regenerating
        if let previewFeature, r.errors[previewFeature] != nil {
            // Keep showing the last good model; the handle turns red instead.
            previewInvalid = true
            isRegenerating = false
            overlayRevision += 1
            return
        }
        previewInvalid = false
        result = r
        self.meshes = meshes
        selection = selection.filter { pick in
            switch pick.kind {
            case .face, .edge: return pick.body < meshes.count
            case .region: return profile(of: pick) != nil
            case .sketchCurve: return curve(of: pick) != nil
            default: return true
            }
        }
        sceneRevision += 1
        overlayRevision += 1
        if fit { fitRevision += 1 }
        isRegenerating = false
        if let session = sketchSession, let frame = r.sketches[session.featureID]?.frame { session.frame = frame }
        updateSketchReferences()
    }

    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        for m in visibleMeshes {
            let p = m.mesh.positions
            for i in stride(from: 0, to: p.count, by: 3) {
                let v = SIMD3(p[i], p[i + 1], p[i + 2])
                lo = simd_min(lo, v); hi = simd_max(hi, v); any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    func fitView() { fitRevision += 1 }

    // MARK: selection

    func name(of pick: PickID) -> String? {
        guard pick.isFace || pick.isEdge, pick.body >= 0, pick.body < meshes.count else { return nil }
        let m = meshes[pick.body].mesh
        let names = pick.isEdge ? m.edgeNames : m.faceNames
        return pick.element < names.count ? names[pick.element] : nil
    }

    func hover(_ pick: PickID?) { hovered = pick }

    func click(_ pick: PickID?, additive: Bool) {
        if isPickingSketchPlane {
            // Only a plane or a face answers the question; anything else keeps asking.
            guard let pick else { return }
            if let plane = OriginPlane(pick: pick) {
                beginSketch(on: plane.planeRef)
            } else if let ref = faceRef(pick) {
                beginSketch(on: .face(ref))
            }
            return
        }
        if let tool = pendingTool {
            toolClick(tool, pick)
            return
        }
        guard let pick, accepts(pick) else {
            if !additive { selection = [] }
            return
        }
        if additive {
            if let i = selection.firstIndex(of: pick) { selection.remove(at: i) } else { selection.append(pick) }
        } else {
            selection = selection == [pick] ? [] : [pick]
        }
    }

    func clearSelection() { selection = [] }

    /// What a plain click can select: faces, edges, and the profiles and curves of visible sketches.
    func accepts(_ pick: PickID) -> Bool {
        switch pick.kind {
        case .face, .edge: return true
        case .region: return profile(of: pick) != nil
        case .sketchCurve: return curve(of: pick) != nil
        default: return false
        }
    }

    // MARK: sketching

    var parameterValues: ParameterValues { result?.parameters ?? ParameterEvaluator.evaluate(document.parameters) }

    /// The picked face by persistent name, planar or not.
    func faceRef(_ pick: PickID) -> FaceRef? {
        guard pick.isFace, pick.body >= 0, pick.body < meshes.count, let name = name(of: pick) else { return nil }
        return FaceRef(body: meshes[pick.body].id, face: name)
    }

    /// The single selected planar face, as a sketch plane.
    var selectedFacePlane: PlaneRef? {
        guard selection.count == 1, let pick = selection.first, let ref = faceRef(pick),
              let body = result?.body(ref.body), (try? body.faceFrame(ref.face)) != nil else { return nil }
        return .face(ref)
    }

    /// The Sketch button: sketches on the selected flat face right away, otherwise asks for a plane
    /// by showing the origin planes in the viewport (see `click`).
    func startSketch() {
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        if let plane = selectedFacePlane {
            beginSketch(on: plane)
            return
        }
        sketchPlaneSize = OriginPlane.displaySize(for: sceneBounds)
        isPickingSketchPlane = true
        selection = []
        selectedFeature = nil
        overlayRevision += 1
    }

    func cancelSketchPlanePick() {
        guard isPickingSketchPlane else { return }
        isPickingSketchPlane = false
        overlayRevision += 1
    }

    /// Instruction shown next to the cursor while the app waits for a pick.
    var cursorPrompt: String? { isPickingSketchPlane ? "Select a plane or planar face" : toolPrompt }

    /// The origin planes are offered while choosing where to sketch or where to put a primitive.
    var showsOriginPlanes: Bool { isPickingSketchPlane || pendingTool?.needsPlane == true }

    func beginSketch(on plane: PlaneRef) {
        let frame: Frame
        do {
            switch plane {
            case .xy: frame = .xy
            case .xz: frame = .xz
            case .yz: frame = .yz
            case .face(let ref):
                guard let body = result?.body(ref.body) else { return }
                frame = try body.faceFrame(ref.face)
            }
        } catch {
            alert = AlertInfo(title: "You can't sketch on that face",
                              message: "Choose a flat face or one of the origin planes. (\(error))")
            return
        }
        isPickingSketchPlane = false
        let feature = Feature(name: document.nextName("Sketch"), .sketch(SketchFeature(plane: plane, sketch: Sketch())))
        sketchSession = SketchSession(featureID: feature.id, frame: frame, sketch: Sketch(), parameters: parameterValues)
        updateSketchReferences()
        selection = []
        selectedFeature = feature.id
        mutate("New Sketch") { doc in
            doc.features.append(feature)
            doc.hidden.remove(feature.id)
        }
        lookAt(frame)
    }

    func editSketch(_ id: FeatureID) {
        guard let f = document.features.first(where: { $0.id == id }), case .sketch(let sf) = f.kind else { return }
        let frame: Frame
        if let r = result?.sketches[id] { frame = r.frame } else {
            switch sf.plane {
            case .xy: frame = .xy
            case .xz: frame = .xz
            case .yz: frame = .yz
            case .face:
                alert = AlertInfo(title: "This sketch's face is missing",
                                  message: "Fix the features before this sketch first, then edit it again.")
                return
            }
        }
        isPickingSketchPlane = false
        pendingTool = nil
        sketchSession = SketchSession(featureID: id, frame: frame, sketch: sf.sketch, parameters: parameterValues)
        selection = []
        selectedFeature = id
        regenerate()
        lookAt(frame)
    }

    /// Body edges and corners that lie in the sketch plane, for the sketch to snap to.
    func updateSketchReferences() {
        guard let session = sketchSession else { return }
        let f = session.frame
        var refs = SketchReferences()
        func local(_ s: [Float], _ i: Int) -> (uv: SIMD2<Double>, w: Double) {
            let p = SIMD3(Double(s[i]), Double(s[i + 1]), Double(s[i + 2])) - f.origin
            return (SIMD2(simd_dot(p, f.xAxis), simd_dot(p, f.yAxis)), simd_dot(p, f.normal))
        }
        for m in visibleMeshes {
            let s = m.mesh.segments, edge = m.mesh.segmentEdge
            for i in edge.indices {
                let a = local(s, i * 6), b = local(s, i * 6 + 3)
                guard abs(a.w) < 1e-3, abs(b.w) < 1e-3 else { continue }
                refs.segments.append((a.uv, b.uv))
                // An edge's ends: where its run of segments starts and stops.
                if i == 0 || edge[i - 1] != edge[i] { refs.points.append(a.uv) }
                if i == edge.count - 1 || edge[i + 1] != edge[i] { refs.points.append(b.uv) }
            }
        }
        session.references = refs
    }

    func finishSketch() {
        sketchSession = nil
        overlayRevision += 1
        regenerate()
    }

    private func lookAt(_ frame: Frame) {
        let o = frame.origin, n = frame.normal
        send(.look(target: SIMD3(Float(o.x), Float(o.y), Float(o.z)), normal: SIMD3(Float(n.x), Float(n.y), Float(n.z))))
    }

    func show(_ view: StandardView) { send(.standard(view)) }

    private func send(_ command: CameraCommand) {
        cameraCommand = (command, (cameraCommand?.revision ?? 0) + 1)
    }

    /// Writes the session's sketch into the document (one undo step) and regenerates.
    func commitSketch(_ action: String?) {
        overlayRevision += 1
        guard let action, let session = sketchSession else { return }
        let sketch = session.sketch
        mutate(action) { doc in
            guard let i = doc.index(of: session.featureID), case .sketch(var sf) = doc.features[i].kind else { return }
            sf.sketch = sketch
            doc.features[i].kind = .sketch(sf)
        }
    }

    /// After undo/redo or edits, make the session match the document.
    private func syncSession() {
        guard let session = sketchSession else { return }
        guard let f = document.features.first(where: { $0.id == session.featureID }), case .sketch(let sf) = f.kind else {
            sketchSession = nil  // the sketch itself was undone
            return
        }
        let params = ParameterEvaluator.evaluate(document.parameters)
        if sf.sketch != session.sketch || params.values != session.parameters.values {
            session.reload(sf.sketch, parameters: params)
        }
        overlayRevision += 1
    }

    func sketchMouse(_ m: SketchMouse) -> Bool {
        guard let session = sketchSession else { return false }
        let r = session.handle(m)
        if m.phase != .moved || !session.clicks.isEmpty { overlayRevision += 1 }
        commitSketch(r.commit)
        return r.handled
    }

    func sketchCommand(_ command: (SketchSession) -> String?) {
        guard let session = sketchSession else { return }
        commitSketch(command(session))
    }

    /// Selects a sketch entity or constraint (e.g. from a constraint glyph).
    func selectSketchItem(_ id: EntityID, additive: Bool) {
        guard let session = sketchSession else { return }
        session.select(id, additive: additive)
        overlayRevision += 1
    }

    func setSketchTool(_ tool: SketchTool) {
        sketchSession?.setTool(tool)
        overlayRevision += 1
    }

    // MARK: sketches in the viewport

    /// Every sketch in document order. A sketch's position here, plus one, is the slot its curves and
    /// profiles carry in pick IDs, so picks stay valid when sketches are shown or hidden.
    var sketchSlots: [FeatureID] { sketches.map(\.id) }

    /// A sketch is drawn unless hidden, suppressed or rolled back; the selected sketch always shows.
    func isSketchShown(_ id: FeatureID) -> Bool {
        guard document.activeFeatures.contains(where: { $0.id == id && !$0.suppressed }) else { return false }
        return !document.hidden.contains(id) || selectedFeature == id
    }

    /// The sketch, region and profile reference a profile pick points at.
    func profile(of pick: PickID) -> (sketch: FeatureID, region: KSketch.Region, ref: ProfileRef)? {
        guard pick.kind == .region, pick.sketchSlot > 0, pick.sketchSlot <= sketchSlots.count else { return nil }
        let id = sketchSlots[pick.sketchSlot - 1]
        guard let r = result?.sketches[id], pick.element < r.regions.count else { return nil }
        let region = r.regions[pick.element]
        return (id, region, ProfileRef(curves: region.tags.split(separator: ",").map(String.init),
                                       hintU: region.sample.x, hintV: region.sample.y))
    }

    /// The sketch and curve a curve pick points at (finished sketches only).
    func curve(of pick: PickID) -> (sketch: FeatureID, curve: EntityID)? {
        guard pick.kind == .sketchCurve, pick.sketchSlot > 0, pick.sketchSlot <= sketchSlots.count else { return nil }
        let id = sketchSlots[pick.sketchSlot - 1]
        guard let r = result?.sketches[id], pick.element < r.solved.curves.count else { return nil }
        return (id, r.solved.curves[pick.element].id)
    }

    /// Selected profiles, in the order they were picked.
    var selectedProfiles: [(sketch: FeatureID, region: KSketch.Region, ref: ProfileRef)] { selection.compactMap { profile(of: $0) } }
    /// Selected sketch curves, in the order they were picked.
    var selectedCurves: [(sketch: FeatureID, curve: EntityID)] { selection.compactMap { curve(of: $0) } }

    /// Everything the viewport draws for sketches: the one being edited, or the visible finished
    /// sketches with pickable profiles and curves, plus the origin planes and the drag handle.
    func sketchOverlay() -> SketchOverlay {
        var o = SketchOverlay()
        if let session = sketchSession {
            SketchOverlayBuilder.editing(session, into: &o)
            if let r = result?.sketches[session.featureID] { SketchOverlayBuilder.regions(r, slot: 0, into: &o) }
            return o
        }
        if showsOriginPlanes { SketchOverlayBuilder.originPlanes(size: sketchPlaneSize, into: &o) }
        if let h = dragHandle {
            let a = h.base, b = h.base + h.direction * h.value
            let fa = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), fb = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
            let id = PickID.handle.raw
            o.handle = [SegmentInstance(ax: fa.x, ay: fa.y, az: fa.z, bx: fb.x, by: fb.y, bz: fb.z, id: id),
                        SegmentInstance(ax: fb.x, ay: fb.y, az: fb.z, bx: fb.x, by: fb.y, bz: fb.z, id: id)]
            o.handleInvalid = previewInvalid
        }
        for (i, id) in sketchSlots.enumerated() where isSketchShown(id) {
            guard let r = result?.sketches[id] else { continue }
            SketchOverlayBuilder.finished(r, slot: i + 1, into: &o)
            SketchOverlayBuilder.regions(r, slot: i + 1, into: &o)
        }
        return o
    }

    func dimensionLabels() -> [DimensionLabel] {
        if let session = sketchSession { return SketchOverlayBuilder.labels(session) }
        if showsOriginPlanes { return SketchOverlayBuilder.originPlaneLabels(size: sketchPlaneSize) }
        return []  // the drag handle's size is an editable field; see the viewport
    }

    /// Pick IDs to highlight as selected.
    var highlighted: [UInt32] {
        if let session = sketchSession {
            return (session.selection + session.dimensionPicks).compactMap { session.pickID(for: $0)?.raw }
        }
        return selection.map(\.raw)
    }

    // MARK: drag handles

    /// An orange arrow on the selected feature; dragging it sets one of the feature's sizes with a
    /// live preview, and the field beside it takes a typed value.
    struct DragHandle {
        var featureID: FeatureID
        /// What the arrow sets, e.g. "Distance" or "Angle".
        var label: String
        var base: SIMD3<Double>
        var direction: SIMD3<Double>
        /// Arrow length, in mm.
        var value: Double
        /// The expression currently stored in the feature.
        var expression: String
        var unit: UnitKind = .length
        /// Arrow millimetres per unit of the value (per mm, or per radian for angles).
        var lengthPerUnit: Double = 1
        /// Largest value allowed (a full turn, for angles).
        var maxValue: Double?
        /// The arrow can be dragged back through its base (an extrude going the other way).
        var allowsNegative = false

        /// The value written to the feature for an arrow length.
        func featureValue(_ length: Double) -> Double {
            let v = length / lengthPerUnit
            return maxValue.map { min(v, $0) } ?? v
        }
    }

    /// A parameter-driven value was dragged: ask before replacing the expression with a number.
    struct UnlinkPrompt: Identifiable {
        let id = UUID()
        var featureID: FeatureID
        var label: String
        var unit: UnitKind
        var expression: String
        var value: Double
        var startValue: Double?
    }

    @ObservationIgnored private var handleDragStart: CADDocument?
    private(set) var handlePreviewValue: Double?
    /// The latest preview failed (e.g. a fillet too big for its faces); the last good model stays visible.
    private(set) var previewInvalid = false
    var unlinkPrompt: UnlinkPrompt?
    /// Bumped when a new feature wants its size typed right away: the viewport focuses the handle's field.
    var handleFocusRequest = 0

    /// What the handle's field shows: the stored expression, or the size being dragged.
    var handleFieldText: String? {
        guard let h = dragHandle else { return nil }
        if handleDragStart != nil { return formatDimension(h.featureValue(h.value), kind: h.unit) }
        return h.expression
    }

    var dragHandle: DragHandle? {
        guard sketchSession == nil, pendingTool == nil, let id = selectedFeature,
              let f = document.features.first(where: { $0.id == id }), !f.suppressed, let result else { return nil }
        let params = parameterValues
        func handle(_ label: String, _ base: SIMD3<Double>, _ direction: SIMD3<Double>, _ expression: String,
                    unit: UnitKind = .length, per: Double = 1, max: Double? = nil, negative: Bool = false) -> DragHandle {
            let v = (try? params.value(of: expression, kind: unit)) ?? 0
            return DragHandle(featureID: id, label: label, base: base, direction: direction,
                              value: handlePreviewValue ?? v * per, expression: expression, unit: unit,
                              lengthPerUnit: per, maxValue: max, allowsNegative: negative)
        }
        switch f.kind {
        case .extrude(let e):
            guard let sr = result.sketches[e.sketch], let ref = e.profiles.first,
                  let region = Regenerator.region(ref, in: sr) else { return nil }
            let n = sr.frame.normal * (e.flipped ? -1 : 1)
            let base = sr.frame.point(region.sample.x, region.sample.y)
            switch e.extent {
            case .distance(let d): return handle("Distance", base, n, d, negative: true)
            case .symmetric(let d): return handle("Distance", base, n, d, per: 0.5)
            case .twoSides(let d, _): return handle("Distance", base, n, d, negative: true)
            }
        case .fillet(let ef), .chamfer(let ef):
            guard let ref = ef.edges.first, let body = result.edgeFeatureInputs[id]?[ref.body],
                  let h = try? body.edgeHandle(ref.edge) else { return nil }
            if case .fillet = f.kind { return handle("Radius", h.origin, h.direction, ef.size) }
            return handle("Distance", h.origin, h.direction, ef.size)
        case .revolve(let rv):
            guard let sr = result.sketches[rv.sketch], let ref = rv.profiles.first,
                  let region = Regenerator.region(ref, in: sr),
                  let axis = try? Regenerator.axis(rv.axis, sketch: sr) else { return nil }
            // A tangent arrow at the profile: its length is the arc the profile's sample point travels.
            let p = sr.frame.point(region.sample.x, region.sample.y)
            let radial = (p - axis.origin) - simd_dot(p - axis.origin, axis.direction) * axis.direction
            let r = simd_length(radial)
            guard r > 1e-6 else { return nil }
            return handle("Angle", p, simd_normalize(simd_cross(axis.direction, radial)), rv.angle, unit: .angle,
                          per: r, max: 2 * .pi)
        case .primitive(let pf):
            guard let frame = try? Regenerator.primitiveFrame(pf, result) else { return nil }
            switch pf.kind {
            case .box, .cylinder: return handle("Height", frame.origin, frame.normal, pf.height)
            case .sphere: return handle("Diameter", frame.origin, frame.normal, pf.diameter, per: 0.5)
            case .torus: return handle("Diameter", frame.origin, frame.xAxis, pf.diameter, per: 0.5)
            case .coil:
                guard let turns = try? params.value(of: pf.turns, kind: .none), turns > 0 else { return nil }
                return handle("Pitch", frame.origin, frame.normal, pf.pitch, per: turns)  // the arrow spans the coil
            }
        case .hole(let hf):
            guard let depth = hf.depth, let frame = try? Regenerator.holeFrame(hf, result) else { return nil }
            return handle("Depth", frame.origin, -frame.normal, depth)
        case .pipe(let pf):
            guard let at = pathPoint(pf.path, result) else { return nil }
            return handle("Diameter", at.point, at.side, pf.diameter, per: 0.5)
        case .rib(let rf):
            guard let at = pathPoint(rf.path, result, middle: true) else { return nil }
            return handle("Thickness", at.point, at.normal, rf.thickness, per: 0.5)
        case .sketch, .sweep, .loft:
            return nil
        }
    }

    /// A point on a path's first curve (its start, or its middle) with the in-plane direction
    /// square to the curve there and the sketch normal.
    private func pathPoint(_ ref: CurveRef, _ r: RegenResult, middle: Bool = false)
        -> (point: SIMD3<Double>, side: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard let sk = r.sketches[ref.sketch], let first = ref.curves.first, let g = sk.solved.geometry(of: first) else { return nil }
        let t = middle ? 0.5 : 0.0
        let p = g.point(t), q = g.point(t + 1e-3)
        let d = q - p, len = (d.x * d.x + d.y * d.y).squareRoot()
        guard len > 1e-12 else { return nil }
        let side = SIMD2(-d.y, d.x) / len
        return (sk.frame.point(p.x, p.y), side.x * sk.frame.xAxis + side.y * sk.frame.yAxis, sk.frame.normal)
    }

    func beginHandleDrag() {
        guard let h = dragHandle else { return }
        handleDragStart = document
        handleStartValue = h.featureValue(h.value)
    }

    /// The size when the drag or typing began, to notice an extrude turning round (Join ⇄ Cut).
    @ObservationIgnored private var handleStartValue: Double?

    /// Moves the handle to the point on its axis closest to the mouse ray, and previews the result.
    func dragHandle(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>) {
        guard let start = handleDragStart, let h = dragHandle else { return }
        let a = h.direction, w = h.base - o
        let b = simd_dot(a, d)
        guard 1 - b * b > 1e-6 else { return }  // looking straight down the handle
        let s = (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
        var length = h.allowsNegative ? (abs(s) < 0.01 ? (s < 0 ? -0.01 : 0.01) : s) : max(s, 0.01)
        if let m = h.maxValue { length = min(length, m * h.lengthPerUnit) }
        handlePreviewValue = length
        var preview = start
        Self.set(expression: formatDimension(h.featureValue(length), kind: h.unit), of: h.featureID, in: &preview)
        Self.turnRound(h.featureID, from: handleStartValue, to: h.featureValue(length), in: &preview)
        regenerate(preview: preview, previewFeature: h.featureID)
        overlayRevision += 1
    }

    func endHandleDrag() {
        guard handleDragStart != nil else { return }
        defer { handleDragStart = nil; handlePreviewValue = nil }
        guard let h = dragHandle, let length = handlePreviewValue else { return }
        if previewInvalid {
            // Dropped where the feature can't be built: go back to what was there.
            previewInvalid = false
            regenerate()
            return
        }
        let value = h.featureValue(length)
        if Self.isParametric(h.expression) {
            unlinkPrompt = UnlinkPrompt(featureID: h.featureID, label: h.label, unit: h.unit, expression: h.expression,
                                        value: value, startValue: handleStartValue)
            return  // the preview stays on screen until the user answers
        }
        commitHandle(h.featureID, h.label, formatDimension(value, kind: h.unit), from: handleStartValue, to: value)
    }

    /// Answer to the unlink prompt: use the dragged number, or keep the expression.
    func resolveUnlink(useValue: Bool) {
        guard let p = unlinkPrompt else { return }
        unlinkPrompt = nil
        if useValue {
            commitHandle(p.featureID, p.label, formatDimension(p.value, kind: p.unit), from: p.startValue, to: p.value)
        } else {
            regenerate()
        }
    }

    private func commitHandle(_ id: FeatureID, _ label: String, _ expression: String, from old: Double? = nil, to new: Double? = nil) {
        mutate("Change \(label)") { doc in
            Self.set(expression: expression, of: id, in: &doc)
            if let new { Self.turnRound(id, from: old, to: new, in: &doc) }
        }
    }

    /// An extrude dragged or typed through zero turns round: pulled back into the body it cuts,
    /// pushed out again it joins. Other operations are left as the user chose them.
    static func turnRound(_ id: FeatureID, from old: Double?, to new: Double, in doc: inout CADDocument) {
        guard let old, let i = doc.index(of: id), case .extrude(var e) = doc.features[i].kind else { return }
        if old >= 0, new < 0, e.operation == .join { e.operation = .cut }
        else if old < 0, new >= 0, e.operation == .cut { e.operation = .join }
        else { return }
        doc.features[i].kind = .extrude(e)
    }

    // MARK: typing the handle's size

    /// Evaluates a typed size: positive, and a bare number read as millimetres (or degrees).
    private func handleSize(_ text: String, _ h: DragHandle) -> (expression: String, value: Double)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let v = try? parameterValues.value(of: t, kind: h.unit), h.allowsNegative ? abs(v) > 1e-9 : v > 1e-9 else { return nil }
        if let m = h.maxValue, v > m + 1e-9 { return nil }
        let bare = Double(t).map { h.unit == .angle ? $0 * .pi / 180 : $0 }
        return (bare.map { formatDimension($0, kind: h.unit) } ?? t, v)
    }

    /// Previews a size typed in the handle's field. Returns false if the text isn't a usable size.
    @discardableResult
    func previewHandle(_ text: String) -> Bool {
        guard let h = dragHandle, handleDragStart == nil, let size = handleSize(text, h) else { return false }
        handlePreviewValue = size.value * h.lengthPerUnit
        var preview = document
        Self.set(expression: size.expression, of: h.featureID, in: &preview)
        Self.turnRound(h.featureID, from: h.featureValue((try? parameterValues.value(of: h.expression, kind: h.unit)) ?? 0), to: size.value, in: &preview)
        regenerate(preview: preview, previewFeature: h.featureID)
        overlayRevision += 1
        return true
    }

    /// Return in the handle's field: stores the typed size (an expression may use parameters).
    @discardableResult
    func commitHandle(_ text: String) -> Bool {
        guard let h = dragHandle, let size = handleSize(text, h) else { return false }
        handlePreviewValue = nil
        let old = (try? parameterValues.value(of: h.expression, kind: h.unit)) ?? 0
        if size.expression == h.expression { regenerate() } else { commitHandle(h.featureID, h.label, size.expression, from: old, to: size.value) }
        overlayRevision += 1
        return true
    }

    /// Esc in the handle's field: drop the preview and show the stored size again.
    func cancelHandleEdit() {
        guard handleDragStart == nil, handlePreviewValue != nil || previewInvalid else { return }
        handlePreviewValue = nil
        previewInvalid = false
        regenerate()
        overlayRevision += 1
    }

    static func isParametric(_ expression: String) -> Bool {
        ((try? Expressions.parse(expression))?.references.isEmpty == false)
    }

    /// Writes the size a feature's drag handle controls.
    static func set(expression text: String, of id: FeatureID, in doc: inout CADDocument) {
        guard let i = doc.index(of: id) else { return }
        switch doc.features[i].kind {
        case .extrude(var e):
            switch e.extent {
            case .distance: e.extent = .distance(text)
            case .symmetric: e.extent = .symmetric(text)
            case .twoSides(_, let back): e.extent = .twoSides(text, back: back)
            }
            doc.features[i].kind = .extrude(e)
        case .fillet(var ef):
            ef.size = text
            doc.features[i].kind = .fillet(ef)
        case .chamfer(var ef):
            ef.size = text
            doc.features[i].kind = .chamfer(ef)
        case .revolve(var r):
            r.angle = text
            doc.features[i].kind = .revolve(r)
        case .primitive(var p):
            switch p.kind {
            case .box, .cylinder: p.height = text
            case .sphere, .torus: p.diameter = text
            case .coil: p.pitch = text
            }
            doc.features[i].kind = .primitive(p)
        case .hole(var h):
            if h.depth != nil { h.depth = text }
            doc.features[i].kind = .hole(h)
        case .pipe(var p):
            p.diameter = text
            doc.features[i].kind = .pipe(p)
        case .rib(var r):
            r.thickness = text
            doc.features[i].kind = .rib(r)
        case .sketch, .sweep, .loft:
            break
        }
    }

    /// Previews an uncommitted edit (e.g. while typing in the inspector) without an undo step.
    func preview(_ id: FeatureID, _ change: (inout Feature) -> Void) {
        var doc = document
        guard let i = doc.index(of: id) else { return }
        change(&doc.features[i])
        regenerate(preview: doc, previewFeature: id)
    }

    // MARK: files

    func export(stl: Bool) {
        guard let bodies = result?.bodies.map(\.body), !bodies.isEmpty else {
            alert = AlertInfo(title: "There's nothing to export", message: "Create a body first, for example by extruding a sketch.")
            return
        }
        let panel = NSSavePanel()
        let ext = stl ? "stl" : "step"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if stl { try KBody.exportSTL(bodies, to: url) } else { try KBody.exportSTEP(bodies, to: url) }
        } catch {
            alert = AlertInfo(title: "The export failed", message: "\(error)")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

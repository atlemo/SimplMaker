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
            selection.removeAll { $0.kind == .region }  // regions belong to the previously selected sketch
            overlayRevision += 1
        }
    }
    /// The sketch being edited, if any.
    private(set) var sketchSession: SketchSession?
    /// A new sketch is waiting for the user to click an origin plane or a flat face.
    private(set) var isPickingSketchPlane = false
    /// Side length of the origin plane squares shown while picking, in mm.
    private(set) var sketchPlaneSize: Double = 25
    /// Bumped whenever the sketch overlay needs rebuilding.
    private(set) var overlayRevision = 0
    /// Camera request for the viewport (look at a sketch plane, standard views), with a revision counter.
    private(set) var cameraCommand: (command: CameraCommand, revision: Int)?
    var showInspector = true
    var orthographic = false
    var fileURL: URL?
    var alert: AlertInfo?

    @ObservationIgnored var undoManager: UndoManager?
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
        syncSession()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replace(with: old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        regenerate()
    }

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
        let feature = Feature(name: document.nextName(base), fillet ? .fillet(edgeFeature) : .chamfer(edgeFeature))
        mutate("Add \(base)") { $0.features.append(feature) }
        selection = []
        selectedFeature = feature.id
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
        selection = selection.filter { $0.body < meshes.count }
        sceneRevision += 1
        overlayRevision += 1
        if fit { fitRevision += 1 }
        isRegenerating = false
        if let session = sketchSession, let frame = r.sketches[session.featureID]?.frame { session.frame = frame }
    }

    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        for m in meshes {
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
        guard let pick, pick.kind != .sketchPoint, pick.kind != .sketchCurve, pick.kind != .handle, pick.kind != .plane else {
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

    // MARK: sketching

    var parameterValues: ParameterValues { result?.parameters ?? ParameterEvaluator.evaluate(document.parameters) }

    /// The picked face by persistent name, planar or not.
    private func faceRef(_ pick: PickID) -> FaceRef? {
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
    var cursorPrompt: String? { isPickingSketchPlane ? "Select a plane or planar face" : nil }

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
        selection = []
        selectedFeature = feature.id
        mutate("New Sketch") { $0.features.append(feature) }
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
        sketchSession = SketchSession(featureID: id, frame: frame, sketch: sf.sketch, parameters: parameterValues)
        selection = []
        selectedFeature = id
        regenerate()
        lookAt(frame)
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

    /// Everything the viewport draws for sketches: the one being edited, the selected sketch's
    /// profiles, and finished sketches that no feature consumes yet.
    func sketchOverlay() -> SketchOverlay {
        var o = SketchOverlay()
        if let session = sketchSession {
            SketchOverlayBuilder.editing(session, into: &o)
            if let r = result?.sketches[session.featureID] { SketchOverlayBuilder.regions(r, into: &o) }
            return o
        }
        if isPickingSketchPlane { SketchOverlayBuilder.originPlanes(size: sketchPlaneSize, into: &o) }
        let consumed = Set(document.features.compactMap { f -> FeatureID? in
            if case .extrude(let e) = f.kind { return e.sketch }
            return nil
        })
        if let h = dragHandle {
            let a = h.base, b = h.base + h.direction * h.value
            let fa = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), fb = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
            let id = PickID.handle.raw
            o.handle = [SegmentInstance(ax: fa.x, ay: fa.y, az: fa.z, bx: fb.x, by: fb.y, bz: fb.z, id: id),
                        SegmentInstance(ax: fb.x, ay: fb.y, az: fb.z, bx: fb.x, by: fb.y, bz: fb.z, id: id)]
            o.handleInvalid = previewInvalid
        }
        for f in document.activeFeatures where !f.suppressed {
            guard case .sketch = f.kind, let r = result?.sketches[f.id] else { continue }
            if f.id == selectedFeature {
                SketchOverlayBuilder.inactive(r.solved, frame: r.frame, into: &o)
                SketchOverlayBuilder.regions(r, into: &o)
            } else if !consumed.contains(f.id) {
                SketchOverlayBuilder.inactive(r.solved, frame: r.frame, into: &o)
            }
        }
        return o
    }

    func dimensionLabels() -> [DimensionLabel] {
        if let session = sketchSession { return SketchOverlayBuilder.labels(session) }
        if isPickingSketchPlane { return SketchOverlayBuilder.originPlaneLabels(size: sketchPlaneSize) }
        if let h = dragHandle {
            let tip = h.base + h.direction * h.value
            return [DimensionLabel(id: "drag-handle", world: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                                   text: previewInvalid ? "\(h.label) — too large" : h.label,
                                   editing: handlePreviewValue != nil)]
        }
        return []
    }

    /// Pick IDs to highlight as selected.
    var highlighted: [UInt32] {
        if let session = sketchSession {
            return (session.selection + session.dimensionPicks).compactMap { session.pickID(for: $0)?.raw }
        }
        return selection.map(\.raw)
    }

    var selectedRegions: [Int] { selection.filter { $0.kind == .region }.map(\.element) }

    /// Extrudes the selected profiles of the selected sketch.
    func extrudeSelectedProfiles() {
        guard let sid = selectedFeature, let r = result?.sketches[sid] else { return }
        let profiles = selectedRegions.compactMap { i -> ProfileRef? in
            guard i < r.regions.count else { return nil }
            let region = r.regions[i]
            return ProfileRef(curves: region.tags.split(separator: ",").map(String.init),
                              hintU: region.sample.x, hintV: region.sample.y)
        }
        guard !profiles.isEmpty else { return }
        let op: BodyOperation = (result?.bodies.isEmpty ?? true) ? .newBody : .join
        let feature = Feature(name: document.nextName("Extrude"),
                              .extrude(ExtrudeFeature(sketch: sid, profiles: profiles, extent: .distance("10 mm"), operation: op)))
        mutate("Extrude") { $0.features.append(feature) }
        selection = []
        selectedFeature = feature.id
    }

    // MARK: drag handles (extrude distance, fillet radius, chamfer distance)

    /// An orange arrow on the selected feature; dragging it sets the feature's size with a live preview.
    struct DragHandle {
        enum Kind: Equatable { case extrude(symmetric: Bool), fillet, chamfer }
        var featureID: FeatureID
        var kind: Kind
        var base: SIMD3<Double>
        var direction: SIMD3<Double>
        /// Handle length, in mm (half the total for symmetric extrudes).
        var value: Double
        /// The expression currently stored in the feature.
        var expression: String

        /// The value written to the feature for a handle length.
        func featureValue(_ length: Double) -> Double {
            if case .extrude(true) = kind { return length * 2 }
            return length
        }
        var label: String {
            let v = formatDimension(featureValue(value), kind: .length)
            return kind == .fillet ? "R \(v)" : v
        }
    }

    /// A parameter-driven value was dragged: ask before replacing the expression with a number.
    struct UnlinkPrompt: Identifiable {
        let id = UUID()
        var featureID: FeatureID
        var kind: DragHandle.Kind
        var expression: String
        var value: Double
    }

    @ObservationIgnored private var handleDragStart: CADDocument?
    private(set) var handlePreviewValue: Double?
    /// The latest preview failed (e.g. a fillet too big for its faces); the last good model stays visible.
    private(set) var previewInvalid = false
    var unlinkPrompt: UnlinkPrompt?

    var dragHandle: DragHandle? {
        guard sketchSession == nil, let id = selectedFeature, let f = document.features.first(where: { $0.id == id }),
              !f.suppressed, let result else { return nil }
        let params = parameterValues
        func length(_ text: String) -> Double { (try? params.value(of: text, kind: .length)) ?? 0 }
        switch f.kind {
        case .extrude(let e):
            guard let sr = result.sketches[e.sketch], let ref = e.profiles.first else { return nil }
            let hint = SIMD2(ref.hintU, ref.hintV)
            guard let region = sr.regions.filter({ $0.tags == ref.tagString })
                .min(by: { simd_length($0.sample - hint) < simd_length($1.sample - hint) }) else { return nil }
            let value: Double, symmetric: Bool, expression: String
            switch e.extent {
            case .distance(let d): value = length(d); symmetric = false; expression = d
            case .symmetric(let d): value = length(d) / 2; symmetric = true; expression = d
            case .twoSides(let d, _): value = length(d); symmetric = false; expression = d
            }
            let n = sr.frame.normal * (e.flipped ? -1 : 1)
            return DragHandle(featureID: id, kind: .extrude(symmetric: symmetric),
                              base: sr.frame.point(region.sample.x, region.sample.y), direction: n,
                              value: handlePreviewValue ?? value, expression: expression)
        case .fillet(let ef), .chamfer(let ef):
            guard let ref = ef.edges.first, let body = result.edgeFeatureInputs[id]?[ref.body],
                  let h = try? body.edgeHandle(ref.edge) else { return nil }
            let isFillet: Bool
            if case .fillet = f.kind { isFillet = true } else { isFillet = false }
            return DragHandle(featureID: id, kind: isFillet ? .fillet : .chamfer, base: h.origin, direction: h.direction,
                              value: handlePreviewValue ?? length(ef.size), expression: ef.size)
        case .sketch:
            return nil
        }
    }

    func beginHandleDrag() {
        guard dragHandle != nil else { return }
        handleDragStart = document
    }

    /// Moves the handle to the point on its axis closest to the mouse ray, and previews the result.
    func dragHandle(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>) {
        guard let start = handleDragStart, let h = dragHandle else { return }
        let a = h.direction, w = h.base - o
        let b = simd_dot(a, d)
        guard 1 - b * b > 1e-6 else { return }  // looking straight down the handle
        let s = (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
        let length = max(s, 0.01)
        handlePreviewValue = length
        var preview = start
        Self.set(h.featureValue(length), of: h.featureID, in: &preview)
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
            unlinkPrompt = UnlinkPrompt(featureID: h.featureID, kind: h.kind, expression: h.expression, value: value)
            return  // the preview stays on screen until the user answers
        }
        commitHandle(h.featureID, h.kind, value)
    }

    /// Answer to the unlink prompt: use the dragged number, or keep the expression.
    func resolveUnlink(useValue: Bool) {
        guard let p = unlinkPrompt else { return }
        unlinkPrompt = nil
        if useValue { commitHandle(p.featureID, p.kind, p.value) } else { regenerate() }
    }

    private func commitHandle(_ id: FeatureID, _ kind: DragHandle.Kind, _ value: Double) {
        let action: String
        switch kind {
        case .extrude: action = "Change Distance"
        case .fillet: action = "Change Radius"
        case .chamfer: action = "Change Chamfer"
        }
        mutate(action) { Self.set(value, of: id, in: &$0) }
    }

    static func isParametric(_ expression: String) -> Bool {
        ((try? Expressions.parse(expression))?.references.isEmpty == false)
    }

    /// Writes a size (mm) into an extrude's first distance or a fillet/chamfer's size.
    private static func set(_ value: Double, of id: FeatureID, in doc: inout CADDocument) {
        guard let i = doc.index(of: id) else { return }
        let text = formatDimension(value, kind: .length)
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
        case .sketch:
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

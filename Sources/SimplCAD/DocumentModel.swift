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

    func regenerate(fit: Bool = false, preview: CADDocument? = nil) {
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
            await self.apply(r, meshes, generation: gen, fit: fit)
        }
    }

    private func apply(_ r: RegenResult, _ meshes: [BodyMesh], generation gen: Int, fit: Bool) {
        guard gen == generation else { return }  // a newer edit is already regenerating
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
        guard let pick, pick.kind != .sketchPoint, pick.kind != .sketchCurve, pick.kind != .handle else {
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

    /// The single selected planar face, as a sketch plane.
    var selectedFacePlane: PlaneRef? {
        guard selection.count == 1, let pick = selection.first, pick.isFace, pick.body < meshes.count,
              let name = name(of: pick), let body = result?.body(meshes[pick.body].id),
              (try? body.faceFrame(name)) != nil else { return nil }
        return .face(FaceRef(body: meshes[pick.body].id, face: name))
    }

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
            alert = AlertInfo(title: "You can't sketch on that face", message: "\(error)")
            return
        }
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
        let consumed = Set(document.features.compactMap { f -> FeatureID? in
            if case .extrude(let e) = f.kind { return e.sketch }
            return nil
        })
        if let h = extrudeHandle {
            let a = h.base, b = h.base + h.direction * h.distance
            let fa = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), fb = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
            let id = PickID.handle.raw
            o.handle = [SegmentInstance(ax: fa.x, ay: fa.y, az: fa.z, bx: fb.x, by: fb.y, bz: fb.z, id: id),
                        SegmentInstance(ax: fb.x, ay: fb.y, az: fb.z, bx: fb.x, by: fb.y, bz: fb.z, id: id)]
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
        if let h = extrudeHandle {
            let tip = h.base + h.direction * h.distance
            let text = formatDimension(h.symmetric ? h.distance * 2 : h.distance, kind: .length)
            return [DimensionLabel(id: "extrude-handle", world: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                                   text: text, editing: handlePreviewDistance != nil)]
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

    // MARK: extrude handle

    /// Drag handle for the selected extrude: from a point inside its first profile, along its direction.
    struct ExtrudeHandle {
        var featureID: FeatureID
        var base: SIMD3<Double>
        var direction: SIMD3<Double>
        var distance: Double
        var symmetric: Bool
    }

    @ObservationIgnored private var handleDragStart: (document: CADDocument, distance: Double)?
    private(set) var handlePreviewDistance: Double?

    var extrudeHandle: ExtrudeHandle? {
        guard sketchSession == nil, let id = selectedFeature, let f = document.features.first(where: { $0.id == id }),
              case .extrude(let e) = f.kind, !f.suppressed, let sr = result?.sketches[e.sketch],
              let ref = e.profiles.first else { return nil }
        let hint = SIMD2(ref.hintU, ref.hintV)
        guard let region = sr.regions.filter({ $0.tags == ref.tagString })
            .min(by: { simd_length($0.sample - hint) < simd_length($1.sample - hint) }) else { return nil }
        let params = parameterValues
        let distance: Double, symmetric: Bool
        switch e.extent {
        case .distance(let d): distance = (try? params.value(of: d, kind: .length)) ?? 0; symmetric = false
        case .symmetric(let d): distance = ((try? params.value(of: d, kind: .length)) ?? 0) / 2; symmetric = true
        case .twoSides(let d, _): distance = (try? params.value(of: d, kind: .length)) ?? 0; symmetric = false
        }
        let n = sr.frame.normal * (e.flipped ? -1 : 1)
        return ExtrudeHandle(featureID: id, base: sr.frame.point(region.sample.x, region.sample.y), direction: n,
                             distance: handlePreviewDistance ?? distance, symmetric: symmetric)
    }

    func beginHandleDrag() {
        guard let h = extrudeHandle else { return }
        handleDragStart = (document, h.distance)
    }

    /// Moves the handle to the point on its axis closest to the mouse ray, and previews the result.
    func dragHandle(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>) {
        guard let start = handleDragStart, let h = extrudeHandle else { return }
        let a = h.direction, w = h.base - o
        let b = simd_dot(a, d)
        guard 1 - b * b > 1e-6 else { return }  // looking straight down the handle
        let s = (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
        let distance = max(s, 0.01)
        handlePreviewDistance = distance
        var preview = start.document
        Self.setDistance(distance, of: h.featureID, symmetric: h.symmetric, in: &preview)
        regenerate(preview: preview)
        overlayRevision += 1
    }

    func endHandleDrag() {
        defer { handleDragStart = nil; handlePreviewDistance = nil }
        guard let h = extrudeHandle, let distance = handlePreviewDistance, handleDragStart != nil else { return }
        mutate("Change Distance") { Self.setDistance(distance, of: h.featureID, symmetric: h.symmetric, in: &$0) }
    }

    private static func setDistance(_ d: Double, of id: FeatureID, symmetric: Bool, in doc: inout CADDocument) {
        guard let i = doc.index(of: id), case .extrude(var e) = doc.features[i].kind else { return }
        let text = formatDimension(symmetric ? d * 2 : d, kind: .length)
        switch e.extent {
        case .distance: e.extent = .distance(text)
        case .symmetric: e.extent = .symmetric(text)
        case .twoSides(_, let back): e.extent = .twoSides(text, back: back)
        }
        doc.features[i].kind = .extrude(e)
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

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

/// Display meshes of the last rebuild's bodies: a body a rebuild didn't touch (the same kernel
/// body) keeps its mesh instead of being tessellated again.
final class MeshCache: @unchecked Sendable {
    private let lock = NSLock()
    private var meshes: [ObjectIdentifier: (body: KBody, mesh: Mesh)] = [:]  // holds the body, so its id isn't reused

    func meshes(for bodies: [BodyResult]) -> [BodyMesh] {
        lock.lock(); defer { lock.unlock() }
        var kept: [ObjectIdentifier: (body: KBody, mesh: Mesh)] = [:]
        var out: [BodyMesh] = []
        for (i, b) in bodies.enumerated() {
            let key = ObjectIdentifier(b.body)
            guard let mesh = meshes[key]?.mesh ?? (try? b.body.tessellate()) else { continue }
            kept[key] = (b.body, mesh)
            out.append(BodyMesh(index: i, id: b.id, name: b.name, mesh: mesh))
        }
        meshes = kept
        return out
    }
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
    /// A STEP file is being read (see importSTEP).
    private(set) var isImporting = false

    var selection: [PickID] = []
    private(set) var hovered: PickID?
    private var selectedFeatureStorage: FeatureID?
    var selectedFeature: FeatureID? {
        get { selectedFeatureStorage }
        set {
            guard newValue != selectedFeatureStorage else { return }
            selectedFeatureStorage = newValue
            if newValue != newFeature { newFeature = nil }  // moved on: Cancel no longer removes it
            overlayRevision += 1
        }
    }
    /// The sketch being edited, if any.
    private(set) var sketchSession: SketchSession?
    /// A new sketch is waiting for the user to click an origin plane or a flat face.
    private(set) var isPickingSketchPlane = false
    /// The feature just created by a tool, while it is still being sized: Cancel takes it out again.
    var newFeature: FeatureID?
    @ObservationIgnored var documentBeforeNewFeature: CADDocument?
    /// A tool waiting for the user to pick what it needs (a profile, a path, a face...). See DesignTools.swift.
    var pendingTool: DesignTool? {
        didSet { if pendingTool == nil { reselecting = nil } }  // cancelling the tool ends a re-pick too
    }
    /// An extrude, revolve or sweep whose profiles are being picked again (its tool waits for picks).
    var reselecting: FeatureID?
    /// The pointer ray of the latest click in the viewport, for placing things where the user clicked.
    @ObservationIgnored var clickRay: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// The ray one point to the right of the click: how big a point is where the click lands.
    @ObservationIgnored var clickRayNext: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// Side length of the origin plane squares shown while picking, in mm.
    var sketchPlaneSize: Double = 25
    /// Bumped whenever the sketch overlay needs rebuilding.
    var overlayRevision = 0
    /// Camera request for the viewport (look at a sketch plane, standard views), with a revision counter.
    private(set) var cameraCommand: (command: CameraCommand, revision: Int)?
    var showInspector = true
    /// The timeline bar along the bottom.
    var showTimeline = true
    /// The browser (bodies, sketches, timeline, parameters) on the left.
    var showSidebar = true
    /// The Appearance panel, for giving bodies colours (A, or View ▸ Show Appearance).
    var showAppearance = false
    /// A colour shown on bodies while it is being picked, before it is kept (see previewBodyColor).
    private(set) var colorPreview: (bodies: [FeatureID], color: BodyColor)?
    /// Orthographic projection (View menu), on by default: sizes and alignments read truer than in perspective.
    var orthographic = true
    var fileURL: URL?
    var alert: AlertInfo?

    @ObservationIgnored var undoManager: UndoManager?
    /// Called with every new document, so the file can snapshot it off the main thread.
    @ObservationIgnored var onDocumentChange: (@Sendable (CADDocument) -> Void)?
    @ObservationIgnored private var generation = 0
    /// Rebuilds run one at a time: while one runs, only the newest request waits (a drag asks
    /// many times a second, and piling those up made every one of them slower).
    @ObservationIgnored private var regenRunning = false
    @ObservationIgnored private var queuedRegen: (@MainActor () -> Void)?
    /// The newest rebuild whose result is on screen: older results arriving later are dropped.
    @ObservationIgnored private var appliedGeneration = 0
    /// What earlier rebuilds left after each feature, so the next one starts at the first change.
    @ObservationIgnored private let regenCache = RegenCache()
    @ObservationIgnored private let meshCache = MeshCache()

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
        if doc.ignoringPresentation == old.ignoringPresentation {  // only visibility or names changed: nothing to rebuild
            sceneRevision += 1
            overlayRevision += 1
        } else {
            regenerate()
        }
    }

    // MARK: timeline marker

    /// How many features the model is built from: the marker's position in the timeline.
    var markerPosition: Int { document.rollback.map { min($0, document.features.count) } ?? document.features.count }

    /// Moves the timeline marker: the model is rebuilt from the features before it only.
    func setMarker(_ position: Int) {
        let p = min(max(position, 0), document.features.count)
        guard p != markerPosition else { return regenerate() }  // drop a drag preview
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        mutate("Move Timeline Marker") { $0.rollback = p == $0.features.count ? nil : p }
        if let id = selectedFeature, let i = document.index(of: id), i >= p { selectedFeature = nil }
    }

    /// Shows the model as it would be with the marker at `position`, while the marker is dragged.
    func previewMarker(_ position: Int) {
        var doc = document
        let p = min(max(position, 0), doc.features.count)
        doc.rollback = p == doc.features.count ? nil : p
        regenerate(preview: doc)
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

    /// Bodies and sketches that own what's selected in the viewport: highlighted in the browser.
    /// The body selected as a whole (from the browser), if that's what's selected.
    var selectedBody: FeatureID? {
        guard selection.count == 1, let pick = selection.first, pick.isWholeBody else { return nil }
        return meshes[safe: pick.body]?.id
    }

    /// A body clicked in the browser: selected whole, with no tool or handle, the way a click on it
    /// in the viewport would. While a tool waits for bodies, it picks the body for the tool instead.
    /// `additive` (⇧-click) adds the body to the selection, or takes it out again.
    func selectBody(_ id: FeatureID, additive: Bool = false) {
        guard let index = meshes.firstIndex(where: { $0.id == id }) else { return }
        let pick = PickID(wholeBody: index)
        if let tool = pendingTool {
            if tool.accepts(.face) { toolClick(tool, pick) }
            return
        }
        if sketchSession != nil { finishSketch() }
        selectedFeature = nil
        if additive {
            if let i = selection.firstIndex(of: pick) { selection.remove(at: i) } else { selection.append(pick) }
        } else {
            selection = [pick]
        }
    }

    var browserHighlights: Set<FeatureID> {
        var ids = Set<FeatureID>()
        for pick in selection {
            switch pick.kind {
            case .face, .edge: if let id = meshes[safe: pick.body]?.id { ids.insert(id) }
            case .region: if let p = profile(of: pick) { ids.insert(p.sketch) }
            case .sketchCurve: if let c = curve(of: pick) { ids.insert(c.sketch) }
            default: break
            }
        }
        return ids
    }

    /// Bodies the viewport draws.
    var visibleMeshes: [BodyMesh] { meshes.filter { !document.hidden.contains($0.id) } }

    /// Bodies for the browser, in creation order.
    /// The bodies, with the names given to them (renaming a body needs no rebuild).
    var bodies: [BodyResult] {
        (result?.bodies ?? []).map { b in
            var b = b
            if let name = document.bodyNames[b.id] { b.name = name }
            return b
        }
    }

    /// Sketch features for the browser.
    var sketches: [Feature] { document.features.filter { if case .sketch = $0.kind { true } else { false } } }
    /// Construction planes in document order. A plane's position here, plus 3 (after the origin
    /// planes), is its index in plane pick IDs.
    var planeFeatures: [Feature] { document.features.filter { if case .plane = $0.kind { true } else { false } } }

    /// The construction plane a plane pick points at (nil for the origin planes).
    func constructionPlane(of pick: PickID) -> FeatureID? {
        guard pick.kind == .plane, pick.element >= OriginPlane.allCases.count else { return nil }
        return planeFeatures[safe: pick.element - OriginPlane.allCases.count]?.id
    }

    /// The plane a pick means: an origin plane, a construction plane, or a flat face.
    func planeRef(of pick: PickID) -> PlaneRef? {
        if let origin = OriginPlane(pick: pick) { return origin.planeRef }
        if let id = constructionPlane(of: pick) { return .plane(id) }
        return faceRef(pick).map { .face($0) }
    }

    func setParameter(_ name: String, expression: String) {
        mutate("Change \(name)") { doc in
            if let i = doc.parameters.firstIndex(where: { $0.name == name }) { doc.parameters[i].expression = expression }
        }
    }

    /// Makes a parameter a length, an angle or a plain number. A plain value ("10 mm") moves to
    /// the new unit ("10 deg", "10"); an expression stays as it is.
    func setParameterUnit(_ name: String, _ unit: UnitKind) {
        mutate("Change \(name)") { doc in
            guard let i = doc.parameters.firstIndex(where: { $0.name == name }), doc.parameters[i].unit != unit else { return }
            doc.parameters[i].unit = unit
            let text = doc.parameters[i].expression.trimmingCharacters(in: .whitespaces)
            if let match = text.wholeMatch(of: /(-?[0-9]+(?:[.,][0-9]+)?)\s*(mm|cm|m|in|deg|rad|°)?/) {
                let suffix = unit == .length ? " mm" : unit == .angle ? " deg" : ""
                doc.parameters[i].expression = String(match.1) + suffix
            }
        }
    }

    func addParameter() {
        mutate("Add Parameter") { doc in
            var n = 1
            while doc.parameters.contains(where: { $0.name == "p\(n)" }) { n += 1 }
            doc.parameters.append(Parameter("p\(n)", "10 mm"))
        }
    }

    /// Renames a parameter and every expression that uses it. Returns why not, if it can't.
    @discardableResult
    func renameParameter(_ old: String, to new: String) -> String? {
        var doc = document
        do { try doc.renameParameter(old, to: new) } catch { return "\(error)" }
        mutate("Rename \(old)") { $0 = doc }
        return nil
    }

    /// Renames a sketch or other feature (an empty name keeps the old one).
    func renameFeature(_ id: FeatureID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        updateFeature(id, "Rename") { $0.name = n }
    }

    /// Renames a body (an empty name goes back to its "BodyN" name).
    func renameBody(_ id: FeatureID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        mutate("Rename Body") { doc in doc.bodyNames[id] = n.isEmpty ? nil : n }
    }

    // MARK: appearance

    /// Bodies the Appearance panel colours: those selected whole, or owning a selected face or edge.
    var appearanceTargets: [FeatureID] {
        let ids = Set(selection.compactMap { $0.isFace || $0.isEdge ? meshes[safe: $0.body]?.id : nil })
        return bodies.map(\.id).filter(ids.contains)
    }

    /// The colour a body is drawn in: the one being picked for it, else its own; nil = the default.
    func displayColor(of id: FeatureID) -> BodyColor? {
        if let p = colorPreview, p.bodies.contains(id) { return p.color }
        return document.bodyColors[id]
    }

    /// Gives bodies a colour (nil goes back to the default), as one undo step. Needs no rebuild.
    func setBodyColor(_ color: BodyColor?, of ids: [FeatureID]) {
        colorPreview = nil
        overlayRevision += 1  // redraw, in case the preview was all that changed
        guard !ids.isEmpty else { return }
        let noun = ids.count == 1 ? "Colour" : "Colours"
        mutate(color == nil ? "Reset \(noun)" : "Change \(noun)") { doc in
            for id in ids { doc.bodyColors[id] = color }
        }
    }

    /// Shows a colour on bodies while it's being picked, without changing the document.
    func previewBodyColor(_ color: BodyColor, of ids: [FeatureID]) {
        colorPreview = ids.isEmpty ? nil : (ids, color)
        overlayRevision += 1
    }

    /// The A key: shows or hides the Appearance panel (outside sketch mode, where A draws an arc).
    func toggleAppearance() {
        guard sketchSession == nil else { return }
        if !showAppearance, pendingTool != nil { cancelTool() }  // clicks now pick bodies to colour
        showAppearance.toggle()
    }

    /// "Appearance…" on a body: selects it whole and opens the panel for it.
    func openAppearance(for body: FeatureID) {
        if pendingTool != nil { cancelTool() }
        if !appearanceTargets.contains(body) { selectBody(body) }
        showAppearance = true
    }

    func removeParameter(_ name: String) {
        mutate("Delete \(name)") { $0.parameters.removeAll { $0.name == name } }
    }

    func updateFeature(_ id: FeatureID, _ actionName: String, _ change: (inout Feature) -> Void) {
        mutate(actionName) { doc in
            if let i = doc.index(of: id) { change(&doc.features[i]) }
        }
    }

    /// Moves a feature to another place in the timeline (`index` is its new position), unless it
    /// would then come before what it's built from; the reason shows in an alert.
    func moveFeature(_ id: FeatureID, to index: Int) {
        guard let from = document.index(of: id) else { return }
        let to = min(max(index, 0), document.features.count - 1)
        guard to != from else { return }
        if let problem = document.reorderProblem(id, to: to) {
            alert = AlertInfo(title: "\(featureName(id)) can't go there", message: problem)
            return
        }
        mutate("Move \(featureName(id))") { doc in
            let f = doc.features.remove(at: from)
            doc.features.insert(f, at: to)
        }
    }

    func deleteFeature(_ id: FeatureID) {
        if sketchSession?.featureID == id { sketchSession = nil }
        mutate("Delete Feature") { doc in
            guard let i = doc.index(of: id) else { return }
            doc.features.remove(at: i)
            if let r = doc.rollback, i < r { doc.rollback = r - 1 }  // the marker stays after the same features
        }
        if selectedFeature == id { selectedFeature = nil }
    }

    /// Creates a fillet or chamfer on the selected edges, and all round the selected faces.
    func addEdgeFeature(fillet: Bool) {
        let edges: [EdgeRef] = selection.compactMap { pick in
            guard pick.isEdge, pick.body < meshes.count else { return nil }
            let m = meshes[pick.body]
            guard pick.element < m.mesh.edgeNames.count else { return nil }
            return EdgeRef(body: m.id, edge: m.mesh.edgeNames[pick.element])
        }
        let faces = selection.compactMap { faceRef($0) }
        guard !edges.isEmpty || !faces.isEmpty else { return }
        let base = fillet ? "Fillet" : "Chamfer"
        let edgeFeature = EdgeFeature(edges: edges, faces: faces, size: fillet ? "2 mm" : "1 mm")
        add(Feature(name: document.nextName(base), fillet ? .fillet(edgeFeature) : .chamfer(edgeFeature)))
    }

    /// Adds a new feature as one undo step, hides the sketches it uses, and selects it so its
    /// drag handle and size field appear.
    func add(_ feature: Feature) {
        documentBeforeNewFeature = document
        mutate("Add \(feature.typeName)") { doc in
            // At the timeline marker: rolled back, a new feature goes where the marker is.
            if let r = doc.rollback, r < doc.features.count {
                doc.features.insert(feature, at: r)
                doc.rollback = r + 1
            } else {
                doc.features.append(feature)
            }
            doc.hidden.formUnion(feature.sketchesUsed)
        }
        selection = []
        pendingTool = nil
        selectedFeature = feature.id
        newFeature = feature.id
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
        let cache = regenCache, meshCache = self.meshCache, snapshot = doc
        let job: @MainActor () -> Void = {
            self.regenRunning = true
            Task.detached(priority: .userInitiated) {
                let r = Regenerator.regenerate(snapshot, cache: cache)
                let meshes = meshCache.meshes(for: r.bodies)
                await self.finishRegen(r, meshes, generation: gen, fit: fit, previewFeature: previewFeature)
            }
        }
        if regenRunning { queuedRegen = job } else { job() }
    }

    private func finishRegen(_ r: RegenResult, _ meshes: [BodyMesh], generation gen: Int, fit: Bool, previewFeature: FeatureID?) {
        regenRunning = false
        let next = queuedRegen
        queuedRegen = nil
        apply(r, meshes, generation: gen, fit: fit, previewFeature: previewFeature, final: next == nil)
        next?()
    }

    /// Shows a rebuild's result. Intermediate ones (a newer rebuild is queued) are shown too, so a
    /// drag keeps moving; `final` is the last of them.
    private func apply(_ r: RegenResult, _ meshes: [BodyMesh], generation gen: Int, fit: Bool, previewFeature: FeatureID?,
                       final: Bool) {
        if final { isRegenerating = false }
        guard gen > appliedGeneration else { return }  // something newer is already on screen
        appliedGeneration = gen
        if let previewFeature, let error = r.errors[previewFeature] {
            // Keep showing the last good model; the handle turns red instead, and says why.
            previewInvalid = true
            // Kernel errors read "fillet: fillet failed (…)"; drop the repeated context.
            let parts = error.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let reason = parts.count == 2 && parts[1].hasPrefix(parts[0]) ? parts[1] : error
            handleProblem = "Can't build it at that size: \(reason)"
            overlayRevision += 1
            return
        }
        previewInvalid = false
        handleProblem = nil
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
        if let id = constructionPlane(of: pick) { return featureName(id) }
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
            } else if let id = constructionPlane(of: pick) {
                beginSketch(on: .plane(id))
            } else if let ref = faceRef(pick) {
                beginSketch(on: .face(ref))
            }
            return
        }
        if let tool = pendingTool {
            toolClick(tool, pick)
            return
        }
        if let pick, let id = constructionPlane(of: pick) {  // a construction plane: select it, with its offset handle
            selection = []
            selectedFeature = id
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

    /// Return (or Esc) after sizing a feature: done with it, so its handle and size field go away.
    func finishFeatureEdit() {
        newFeature = nil
        guard dragHandle != nil else { return }
        selectedFeature = nil
        selection = []
    }

    /// What a plain click can select: faces, edges, and the profiles and curves of visible sketches.
    func accepts(_ pick: PickID) -> Bool {
        switch pick.kind {
        case .face, .edge: return true
        case .plane: return OriginPlane(pick: pick) != nil || constructionPlane(of: pick) != nil
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
        // A selected construction plane counts too.
        if selection.isEmpty, let id = selectedFeature, case .plane? = document.features.first(where: { $0.id == id })?.kind,
           result?.planes[id] != nil {
            return .plane(id)
        }
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
    var showsOriginPlanes: Bool { isPickingSketchPlane || pendingTool?.showsPlanes == true }

    func beginSketch(on plane: PlaneRef) {
        let frame: Frame
        do {
            frame = try Regenerator.resolvePlane(plane, result ?? RegenResult())
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
            case .face, .plane:
                alert = AlertInfo(title: "This sketch's face or plane is missing",
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
        return !document.hidden.contains(id) || selectedFeature == id || reselecting.flatMap { profileSource($0)?.sketch } == id
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
        if showsOriginPlanes {
            SketchOverlayBuilder.originPlanes(size: sketchPlaneSize, into: &o)
            o.planesSeeThrough = true
        }
        // Construction planes, always (unless hidden), pickable to sketch on or to select.
        let planeSize = OriginPlane.displaySize(for: sceneBounds)
        for (slot, f) in planeFeatures.enumerated() where !document.hidden.contains(f.id) {
            guard let frame = result?.planes[f.id] else { continue }
            SketchOverlayBuilder.constructionPlane(frame, size: planeSize, id: PickID(plane: OriginPlane.allCases.count + slot).raw, into: &o)
        }
        if let h = dragHandle {
            let a = h.base, b = h.base + h.direction * h.value
            let fa = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)), fb = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
            let id = PickID.handle.raw
            o.handle = [SegmentInstance(ax: fa.x, ay: fa.y, az: fa.z, bx: fb.x, by: fb.y, bz: fb.z, id: id),
                        SegmentInstance(ax: fb.x, ay: fb.y, az: fb.z, bx: fb.x, by: fb.y, bz: fb.z, id: id)]
            o.handleInvalid = previewInvalid
        }
        if let p = holeMoveDot {
            let f = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)), id = PickID.moveHandle.raw
            o.moveHandle = [SegmentInstance(ax: f.x, ay: f.y, az: f.z, bx: f.x, by: f.y, bz: f.z, id: id)]
            o.handleInvalid = previewInvalid
        }
        for (i, id) in sketchSlots.enumerated() where isSketchShown(id) {
            guard let r = result?.sketches[id] else { continue }
            SketchOverlayBuilder.finished(r, slot: i + 1, parameters: parameterValues, into: &o)
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
        guard picksWholeBodies else { return selection.map(\.raw) }
        // A face or edge picked for a body tool stands for its whole body.
        var out: [UInt32] = []
        for pick in selection {
            let whole = pick.isFace || (pick.isEdge && pendingTool != .pattern)  // Pattern's edges are directions
            let raw = whole ? PickID(wholeBody: pick.body).raw : pick.raw
            if !out.contains(raw) { out.append(raw) }
        }
        return out
    }

    /// The waiting tool works on whole bodies (a click on any face picks its body), so hover and
    /// selection light up whole bodies. Pattern's edges pick a direction, so only its faces do.
    var picksWholeBodies: Bool { pendingTool?.picksBodies == true }

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
        /// A hole dragged over its face (X and Y together), instead of one size.
        var holePosition: SIMD2<Double>?

        /// The dragged value, as the prompt shows it.
        var valueText: String {
            if let uv = holePosition { return "\(formatDimension(uv.x, kind: .length)), \(formatDimension(uv.y, kind: .length))" }
            return formatDimension(value, kind: unit)
        }
    }

    @ObservationIgnored private var handleDragStart: CADDocument?
    /// The document when a hole's move dot was grabbed, and where the dot is being dragged (in the face's u, v).
    @ObservationIgnored var holeMoveStart: CADDocument?
    var holeMovePreview: SIMD2<Double>?
    private(set) var handlePreviewValue: Double?
    /// The latest preview failed (e.g. a fillet too big for its faces); the last good model stays visible.
    private(set) var previewInvalid = false
    /// Why the size typed in the handle's field can't be used, shown under the field.
    private(set) var handleProblem: String?
    /// What's typed in the handle's field and not stored yet (the viewport keeps this up to date).
    @ObservationIgnored var handleDraft: String?
    /// Bumped when the field should drop its typing and show the stored size again.
    private(set) var handleFieldReset = 0

    /// Before an option beside the field changes the feature (another axis, Join/Cut, flip): store
    /// what's typed on the feature as it is now, then let the field show the new state's size.
    func storeTypedSize() {
        defer { handleDraft = nil; handleFieldReset += 1 }
        guard let draft = handleDraft, draft != handleFieldText else { return }
        commitHandle(draft)
    }
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
        guard sketchSession == nil, pendingTool == nil, holeMoveStart == nil, let id = selectedFeature else { return nil }
        return handle(for: id)
    }

    /// The drag handle a feature shows while it's selected.
    func handle(for id: FeatureID) -> DragHandle? {
        guard let f = document.features.first(where: { $0.id == id }), !f.suppressed, let result else { return nil }
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
            let base: SIMD3<Double>, n: SIMD3<Double>
            if let face = e.face {
                guard let body = result.featureInputs[id]?[face.body], let frame = try? body.faceFrame(face.face),
                      let center = try? body.faceCenter(face.face) else { return nil }
                base = center
                n = frame.normal * (e.flipped ? -1 : 1)
            } else {
                guard let sr = result.sketches[e.sketch], let ref = e.profiles.first,
                      let region = Regenerator.region(ref, in: sr) else { return nil }
                n = sr.frame.normal * (e.flipped ? -1 : 1)
                base = sr.frame.point(region.sample.x, region.sample.y)
            }
            switch e.extent {
            case .distance(let d): return handle("Distance", base, n, d, negative: true)
            case .symmetric(let d): return handle("Distance", base, n, d, per: 0.5)
            case .twoSides(let d, _): return handle("Distance", base, n, d, negative: true)
            case .throughAll, .toFace: return nil  // the length comes from the model, not a size
            }
        case .fillet(let ef), .chamfer(let ef):
            // On the first edge, or the first edge around the first face.
            let ref = ef.edges.first ?? ef.faces.first.flatMap { face in
                (try? result.edgeFeatureInputs[id]?[face.body]?.faceEdges(face.face))?.first.map { EdgeRef(body: face.body, edge: $0) }
            }
            guard let ref, let body = result.edgeFeatureInputs[id]?[ref.body],
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
        case .move(let mf):
            let bodies = Array((result.featureInputs[id] ?? [:]).values), sketches = Array((result.sketchInputs[id] ?? [:]).values)
            guard let center = Regenerator.center(of: bodies, sketches: sketches) else { return nil }
            let offset = SIMD3((try? params.value(of: mf.dx, kind: .length)) ?? 0, (try? params.value(of: mf.dy, kind: .length)) ?? 0,
                               (try? params.value(of: mf.dz, kind: .length)) ?? 0)
            let dir = Regenerator.direction(mf.arrow)
            let along = simd_dot(offset, dir)
            // The arrow starts where the body is, apart from the part of the move along the arrow.
            return handle("Move \(mf.arrow.rawValue)", center + offset - along * dir, dir, Self.component(mf, mf.arrow), negative: true)
        case .rotate(let rf):
            guard let inputs = result.featureInputs[id], let center = Regenerator.center(of: Array(inputs.values)),
                  let box = inputs.values.first?.bounds else { return nil }
            let axis = Regenerator.direction(rf.axis)
            let radial: SIMD3<Double> = rf.axis == .z ? SIMD3(1, 0, 0) : rf.axis == .x ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
            let r = max(simd_reduce_max(box.max - box.min) * 0.6, 1)
            var h = handle("Angle", center + r * radial, simd_cross(axis, radial), rf.angle, unit: .angle, per: r, max: 2 * .pi)
            h.allowsNegative = true
            return h
        case .plane(let pf):
            // From where the plane is with no offset, along its normal. Worked out from the plane it
            // starts from (not from the plane as last built), so it holds still while being dragged.
            var unmoved = pf
            unmoved.offset = "0 mm"
            guard let start = try? Regenerator.plane(unmoved, result) else { return nil }
            return handle("Offset", start.origin, start.normal, pf.offset, negative: true)
        case .pattern(let pf) where pf.kind == .linear:
            // From the middle of the bodies to where the first copy's middle lands.
            let bodies = Array((result.featureInputs[id] ?? [:]).values)
            guard let center = Regenerator.center(of: bodies), let axis = try? Regenerator.line(pf.axis, result) else { return nil }
            return handle("Spacing", center, axis.direction, pf.spacing, negative: true)
        case .sketch, .sweep, .loft, .combine, .mirror, .pattern, .shell, .importBody:
            return nil
        }
    }

    // MARK: moving a hole

    /// The selected hole, when its move dot shows (as with the drag handle: no sketch, no tool waiting).
    var selectedHole: (id: FeatureID, hole: HoleFeature)? {
        guard sketchSession == nil, pendingTool == nil, let id = selectedFeature,
              let f = document.features.first(where: { $0.id == id }), !f.suppressed, case .hole(let hole) = f.kind else { return nil }
        return (id, hole)
    }

    /// The plane of a hole's face; the hole's (u, v) are in it.
    func holeFace(_ id: FeatureID, _ hole: HoleFeature) -> Frame? {
        guard let result, let body = result.featureInputs[id]?[hole.face.body] ?? result.body(hole.face.body) else { return nil }
        return try? body.faceFrame(hole.face.face)
    }

    /// The middle of a hole's face outline (as it was before the hole), in the face's (u, v).
    func holeFaceCenter(_ id: FeatureID, _ hole: HoleFeature, on face: Frame) -> SIMD2<Double>? {
        guard let body = result?.featureInputs[id]?[hole.face.body], let c = try? body.faceOutlineCenter(hole.face.face) else { return nil }
        return Self.uv(of: c, on: face)
    }

    /// Where the selected hole's move dot is: the hole's centre, or where it's being dragged.
    var holeMoveDot: SIMD3<Double>? {
        guard let (id, hole) = selectedHole, let face = holeFace(id, hole) else { return nil }
        if let uv = holeMovePreview { return face.point(uv.x, uv.y) }
        guard let result, let frame = try? Regenerator.holeFrame(hole, result) else { return nil }
        return frame.origin
    }

    func beginHoleMove() {
        guard selectedHole != nil else { return }
        holeMoveStart = document
    }

    /// Slides the hole to where the mouse ray meets its face, in round steps of about 6 points
    /// (`pointsPerMM`: how long 1 mm on the face looks), and onto the face's centre lines when within
    /// 10 points of them. Previews the result.
    func moveHole(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, pointsPerMM: Double?) {
        guard let start = holeMoveStart, let (id, hole) = selectedHole, let face = holeFace(id, hole),
              let hit = Self.intersect(ray: (o, d), with: face) else { return }
        var uv = hit
        if let ppm = pointsPerMM, ppm > 1e-9 {
            let center = holeFaceCenter(id, hole, on: face)
            let c = center ?? .zero
            let step = ViewportMTKView.niceStep(6 / ppm)
            uv = c + ((uv - c) / step).rounded(.toNearestOrAwayFromZero) * step
            if let center { uv = Self.snap(uv, to: center, tolerance: 10 / ppm) }
        }
        holeMovePreview = uv
        var preview = start
        Self.setHolePosition(uv, of: id, in: &preview)
        regenerate(preview: preview, previewFeature: id)
        overlayRevision += 1
    }

    func endHoleMove() {
        guard holeMoveStart != nil else { return }
        defer { holeMoveStart = nil; holeMovePreview = nil; overlayRevision += 1 }
        guard let (id, hole) = selectedHole, let uv = holeMovePreview else { return }
        if previewInvalid {
            // Dropped where the hole can't be made: go back to where it was.
            previewInvalid = false
            regenerate()
            return
        }
        if Self.isParametric(hole.u) || Self.isParametric(hole.v) {
            unlinkPrompt = UnlinkPrompt(featureID: id, label: "Position", unit: .length, expression: "\(hole.u), \(hole.v)",
                                        value: 0, holePosition: uv)
            return  // the preview stays on screen until the user answers
        }
        commitHoleMove(id, to: uv)
    }

    func commitHoleMove(_ id: FeatureID, to uv: SIMD2<Double>) {
        mutate("Move Hole") { Self.setHolePosition(uv, of: id, in: &$0) }
    }

    static func setHolePosition(_ uv: SIMD2<Double>, of id: FeatureID, in doc: inout CADDocument) {
        guard let i = doc.index(of: id), case .hole(var h) = doc.features[i].kind else { return }
        h.u = formatDimension(uv.x, kind: .length)
        h.v = formatDimension(uv.y, kind: .length)
        doc.features[i].kind = .hole(h)
    }

    /// Moves each coordinate onto the centre's when it's within `tolerance` of it: the point lands on
    /// the centre, or on one of the lines through it.
    static func snap(_ p: SIMD2<Double>, to center: SIMD2<Double>, tolerance: Double) -> SIMD2<Double> {
        SIMD2(abs(p.x - center.x) <= tolerance ? center.x : p.x, abs(p.y - center.y) <= tolerance ? center.y : p.y)
    }

    /// A point in a plane's (u, v).
    static func uv(of point: SIMD3<Double>, on frame: Frame) -> SIMD2<Double> {
        let p = point - frame.origin
        return SIMD2(simd_dot(p, frame.xAxis), simd_dot(p, frame.yAxis))
    }

    /// Where a ray meets a plane, in the plane's (u, v); nil when the ray runs along the plane.
    static func intersect(ray: (origin: SIMD3<Double>, direction: SIMD3<Double>), with frame: Frame) -> SIMD2<Double>? {
        let denom = simd_dot(ray.direction, frame.normal)
        guard abs(denom) > 1e-9 else { return nil }
        let t = simd_dot(frame.origin - ray.origin, frame.normal) / denom
        return uv(of: ray.origin + t * ray.direction, on: frame)
    }

    /// A move's distance along one axis, as stored.
    static func component(_ m: MoveFeature, _ a: Axis3) -> String {
        switch a {
        case .x: return m.dx
        case .y: return m.dy
        case .z: return m.dz
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
    /// `pointsPerMM`: how long 1 mm along the arrow looks on screen. The size then goes in round
    /// steps (1, 2 or 5 × 10ⁿ mm or degrees) of about 6 points, not in whatever fraction the pointer lands on.
    func dragHandle(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, pointsPerMM: Double? = nil) {
        guard let start = handleDragStart, let h = dragHandle else { return }
        let a = h.direction, w = h.base - o
        let b = simd_dot(a, d)
        guard 1 - b * b > 1e-6 else { return }  // looking straight down the handle
        let s = (b * simd_dot(d, w) - simd_dot(a, w)) / (1 - b * b)
        var length = h.allowsNegative ? (abs(s) < 0.01 ? (s < 0 ? -0.01 : 0.01) : s) : max(s, 0.01)
        if let ppm = pointsPerMM, ppm > 1e-9, h.lengthPerUnit > 1e-12 {
            // In the feature's own units: mm, or degrees for angles (radians underneath).
            let degrees = h.unit == .angle ? 180 / Double.pi : 1
            let perPoint = degrees / (ppm * h.lengthPerUnit)
            let step = ViewportMTKView.niceStep(6 * perPoint) / degrees
            let value = (length / h.lengthPerUnit / step).rounded() * step
            if value != 0 || h.allowsNegative == false { length = value * h.lengthPerUnit }
            if !h.allowsNegative { length = max(length, step * h.lengthPerUnit) }
        }
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
        if useValue, let uv = p.holePosition {
            commitHoleMove(p.featureID, to: uv)
        } else if useValue {
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

    /// Why a typed size can't be used: an unknown name, the wrong kind of value, or out of range.
    func handleSizeProblem(_ text: String, _ h: DragHandle) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "Type a size" }
        let needed = h.unit == .angle ? "an angle" : "a length"
        do {
            let v = try parameterValues.value(of: t, kind: h.unit)
            if h.allowsNegative ? abs(v) <= 1e-9 : v <= 1e-9 { return h.allowsNegative ? "It can't be zero" : "It must be more than zero" }
            if let m = h.maxValue, v > m + 1e-9 { return "It can be at most \(h.unit.format(m))" }
            return nil
        } catch {
            // The right expression with the wrong kind of value, e.g. a length parameter in an angle field.
            for other in [UnitKind.length, .angle, .none] where other != h.unit {
                if let v = try? parameterValues.value(of: t, kind: other) {
                    let got = other == .angle ? "an angle" : other == .length ? "a length" : "a plain number"
                    return "That's \(got) (\(other.format(v))), but this needs \(needed)"
                }
            }
            return "\(error)".prefix(1).uppercased() + "\(error)".dropFirst()
        }
    }

    /// Previews a size typed in the handle's field. Returns false if the text isn't a usable size.
    @discardableResult
    func previewHandle(_ text: String) -> Bool {
        guard let h = dragHandle, handleDragStart == nil else { return false }
        guard let size = handleSize(text, h) else {
            handleProblem = handleSizeProblem(text, h)
            return false
        }
        handleProblem = nil
        handlePreviewValue = size.value * h.lengthPerUnit
        var preview = document
        Self.set(expression: size.expression, of: h.featureID, in: &preview)
        Self.turnRound(h.featureID, from: h.featureValue((try? parameterValues.value(of: h.expression, kind: h.unit)) ?? 0), to: size.value, in: &preview)
        regenerate(preview: preview, previewFeature: h.featureID)
        overlayRevision += 1
        return true
    }

    /// Return in the handle's field: stores the typed size (an expression may use parameters).
    /// `feature` is the feature the field was for, which may no longer be selected (OK, or a
    /// click elsewhere, closes the handle before the field hands over its text).
    @discardableResult
    func commitHandle(_ text: String, for feature: FeatureID? = nil) -> Bool {
        guard let h = feature.flatMap({ handle(for: $0) }) ?? dragHandle else { return false }
        guard let size = handleSize(text, h) else {
            handleProblem = handleSizeProblem(text, h)
            return false
        }
        handleProblem = nil
        handleDraft = nil
        handlePreviewValue = nil
        let old = (try? parameterValues.value(of: h.expression, kind: h.unit)) ?? 0
        if size.expression == h.expression { regenerate() } else { commitHandle(h.featureID, h.label, size.expression, from: old, to: size.value) }
        overlayRevision += 1
        return true
    }

    /// Esc in the handle's field: drop the preview and show the stored size again.
    func cancelHandleEdit() {
        handleProblem = nil
        handleDraft = nil
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
            case .throughAll, .toFace: break
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
        case .move(var m):
            switch m.arrow {
            case .x: m.dx = text
            case .y: m.dy = text
            case .z: m.dz = text
            }
            doc.features[i].kind = .move(m)
        case .rotate(var r):
            r.angle = text
            doc.features[i].kind = .rotate(r)
        case .plane(var p):
            p.offset = text
            doc.features[i].kind = .plane(p)
        case .pattern(var p):
            p.spacing = text
            doc.features[i].kind = .pattern(p)
        case .sketch, .sweep, .loft, .combine, .mirror, .shell, .importBody:
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

    /// Asks for a STEP file and adds it to the timeline as a body of its own.
    func importSTEP() {
        guard let url = Self.chooseSTEP("Import") else { return }
        Task { await importSTEP(from: url) }
    }

    /// Reads a STEP file and adds it as an Import feature, at the timeline marker, with the body
    /// named after the file. False if it can't be read (an alert says why).
    @discardableResult
    func importSTEP(from url: URL) async -> Bool {
        let id = IDs.make()
        guard let data = await loadSTEP(url, featureID: id) else { return false }
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        let feature = Feature(id: id, name: document.nextName("Import"),
                              .importBody(ImportFeature(fileName: url.lastPathComponent, data: data)))
        mutate("Import \(url.lastPathComponent)") { doc in
            if let r = doc.rollback, r < doc.features.count {
                doc.features.insert(feature, at: r)
                doc.rollback = r + 1
            } else {
                doc.features.append(feature)
            }
            doc.bodyNames[id] = url.deletingPathExtension().lastPathComponent
        }
        selection = []
        selectedFeature = id
        regenerate(fit: true)  // nothing left to build by then; it only brings the new body into view
        return true
    }

    /// Asks for a new version of an imported file. Its faces keep their names as long as the
    /// file lists them in the same order, so features after the import usually hold on.
    func replaceImport(_ id: FeatureID) {
        guard let url = Self.chooseSTEP("Replace") else { return }
        Task { await replaceImport(id, from: url) }
    }

    @discardableResult
    func replaceImport(_ id: FeatureID, from url: URL) async -> Bool {
        guard let data = await loadSTEP(url, featureID: id) else { return false }
        updateFeature(id, "Replace \(url.lastPathComponent)") { f in
            guard case .importBody(var i) = f.kind else { return }
            i.fileName = url.lastPathComponent
            i.data = data
            f.kind = .importBody(i)
        }
        return true
    }

    private static func chooseSTEP(_ prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["step", "stp"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = prompt
        panel.message = "Choose a STEP file (.step or .stp)."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Reads a STEP file and checks that the kernel can make a body of it, off the main thread.
    /// The body is kept for the rebuild that follows, so the file is read only once.
    private func loadSTEP(_ url: URL, featureID: FeatureID) async -> Data? {
        isImporting = true
        defer { isImporting = false }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Data, any Error> in
            Result {
                let data = try Data(contentsOf: url)
                _ = try Regenerator.importedBody(data, featureID: featureID)
                return data
            }
        }.value
        switch outcome {
        case .success(let data):
            return data
        case .failure(let error):
            // Kernel errors read "STEP import: the file has no solids"; make that a sentence.
            var reason = error.localizedDescription
            if let e = error as? KernelError {
                let text = e.message.replacingOccurrences(of: "STEP import: ", with: "")
                reason = text.prefix(1).uppercased() + String(text.dropFirst()) + "."
            }
            alert = AlertInfo(title: "\(url.lastPathComponent) couldn't be imported", message: reason)
            return nil
        }
    }

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

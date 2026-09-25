// App state: the document, undo, background regeneration, selection, files.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import Observation
import simd
import UniformTypeIdentifiers

/// A tessellated body for the viewport.
struct BodyMesh: Sendable {
    var index: Int
    var id: FeatureID
    var name: String
    var mesh: Mesh
}

extension UTType {
    static let simplCAD = UTType(exportedAs: "org.simplcad.document", conformingTo: .json)
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
    /// Camera request: look at a sketch plane.
    private(set) var cameraRequest: (target: SIMD3<Float>, normal: SIMD3<Float>, revision: Int)?
    var fileURL: URL?
    var alert: String?

    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private var generation = 0

    init(document: CADDocument = .demo()) {
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

    func regenerate(fit: Bool = false) {
        generation += 1
        let gen = generation
        var doc = document
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
        guard let pick, pick.kind != .sketchPoint, pick.kind != .sketchCurve else {
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
            alert = "Can't sketch there: \(error)"
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
            case .face: alert = "This sketch's face is missing; fix the features before it first."; return
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
        cameraRequest = (SIMD3(Float(o.x), Float(o.y), Float(o.z)), SIMD3(Float(n.x), Float(n.y), Float(n.z)),
                         (cameraRequest?.revision ?? 0) + 1)
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
        sketchSession.map { SketchOverlayBuilder.labels($0) } ?? []
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

    // MARK: files

    func newDocument(demo: Bool) {
        sketchSession = nil
        document = demo ? .demo() : CADDocument()
        fileURL = nil
        undoManager?.removeAllActions()
        selection = []
        selectedFeature = nil
        regenerate(fit: true)
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.simplCAD, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            document = try CADDocument.decode(try Data(contentsOf: url))
            sketchSession = nil
            fileURL = url
            undoManager?.removeAllActions()
            selection = []
            selectedFeature = nil
            regenerate(fit: true)
        } catch {
            alert = "Could not open \(url.lastPathComponent): \(error)"
        }
    }

    func save(as saveAs: Bool = false) {
        var url = fileURL
        if url == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.simplCAD]
            panel.nameFieldStringValue = "Untitled.simplcad"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        do {
            try document.encoded().write(to: url, options: .atomic)
            fileURL = url
        } catch {
            alert = "Could not save: \(error)"
        }
    }

    func export(stl: Bool) {
        guard let bodies = result?.bodies.map(\.body), !bodies.isEmpty else { alert = "Nothing to export."; return }
        let panel = NSSavePanel()
        let ext = stl ? "stl" : "step"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if stl { try KBody.exportSTL(bodies, to: url) } else { try KBody.exportSTEP(bodies, to: url) }
        } catch {
            alert = "Export failed: \(error)"
        }
    }
}

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
    var selectedFeature: FeatureID?
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
        let doc = document
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
        if fit { fitRevision += 1 }
        isRegenerating = false
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
        guard pick.body >= 0, pick.body < meshes.count else { return nil }
        let m = meshes[pick.body].mesh
        let names = pick.isEdge ? m.edgeNames : m.faceNames
        return pick.element < names.count ? names[pick.element] : nil
    }

    func hover(_ pick: PickID?) { hovered = pick }

    func click(_ pick: PickID?, additive: Bool) {
        guard let pick else { if !additive { selection = [] }; return }
        if additive {
            if let i = selection.firstIndex(of: pick) { selection.remove(at: i) } else { selection.append(pick) }
        } else {
            selection = selection == [pick] ? [] : [pick]
        }
    }

    func clearSelection() { selection = [] }

    // MARK: files

    func newDocument(demo: Bool) {
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

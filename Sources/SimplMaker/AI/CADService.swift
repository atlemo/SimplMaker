// The internal API an AI client works through. It answers questions about the open documents from the model's own
// state (the document and its last rebuild) and, from later steps on, changes them through the same editing path
// the interface uses. It knows nothing of MCP or JSON-RPC; whatever carries the requests calls these functions.
//
// Every call checks the licence first: the AI interface works with a valid licence or a running trial, as editing does.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd

@MainActor
final class CADService {
    private let registry: DocumentRegistry
    private let licensed: @MainActor () -> Bool

    init(registry: DocumentRegistry = .shared, licensed: @escaping @MainActor () -> Bool = { LicenseManager.shared.allowsEditing }) {
        self.registry = registry
        self.licensed = licensed
    }

    // MARK: resolving

    func checkLicense() throws {
        guard licensed() else { throw AIError.licenseRequired }
    }

    /// The document asked for by id, or with no id the one in the front window.
    func resolve(_ id: String?) throws -> (id: String, model: DocumentModel) {
        if let id {
            guard let model = registry.model(withID: id) else {
                throw AIError(.documentNotFound, "There is no open document with the id \(id).",
                              reason: "It may have been closed. Call list_documents for the ids that are open.")
            }
            return (id, model)
        }
        guard let front = registry.frontmost else {
            let open = registry.documents
            throw AIError(.noActiveDocument,
                          open.isEmpty ? "No document is open in SimplMaker." : "Several documents are open and none is in front.",
                          reason: open.isEmpty ? "Ask the user to open or create a part." : "Pass document_id. Open: " + open.map(\.id).joined(separator: ", "))
        }
        return front
    }

    static func name(of model: DocumentModel) -> String {
        model.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    // MARK: documents

    func listDocuments() throws -> DocumentList {
        try checkLicense()
        let front = registry.frontmost?.id
        return DocumentList(documents: registry.documents.map { id, model in
            DocumentSummary(id: id, name: Self.name(of: model), path: model.fileURL?.path, isActive: id == front,
                            featureCount: model.document.features.count)
        })
    }

    func getDocument(id: String? = nil) async throws -> DocumentDescription {
        try checkLicense()
        let (docID, model) = try resolve(id)
        await model.rebuilt()
        let doc = model.document
        let describer = FeatureDescriber(values: model.parameterValues)
        return DocumentDescription(
            documentId: docID, name: Self.name(of: model), path: model.fileURL?.path, units: "mm",
            revision: model.documentRevision,
            timelineMarker: doc.rollback.map { min($0, doc.features.count) },
            parameters: parameters(of: model),
            features: doc.features.indices.map { featureInfo(at: $0, in: model, describer: describer) },
            bodies: bodies(of: model))
    }

    func getFeature(documentID: String? = nil, featureID: FeatureID) async throws -> FeatureDescription {
        try checkLicense()
        let (docID, model) = try resolve(documentID)
        await model.rebuilt()
        guard let index = model.document.index(of: featureID) else {
            throw AIError(.featureNotFound, "There is no feature with the id \(featureID).",
                          reason: "Call get_document for the features that exist. Ids of deleted features are not reused.")
        }
        let describer = FeatureDescriber(values: model.parameterValues)
        return FeatureDescription(documentId: docID, revision: model.documentRevision,
                                  feature: featureInfo(at: index, in: model, describer: describer),
                                  editable: FeatureFields.specs(for: model.document.features[index].kind).map(\.name),
                                  sketch: sketchInfo(featureID, in: model, describer: describer))
    }

    func listParameters(documentID: String? = nil) async throws -> [ParameterInfo] {
        try checkLicense()
        let (_, model) = try resolve(documentID)
        await model.rebuilt()
        return parameters(of: model)
    }

    // MARK: selection

    /// What is selected in the viewport, as ids that mean the same after the model is rebuilt.
    func getSelection(documentID: String? = nil) throws -> SelectionDescription {
        try checkLicense()
        let (docID, model) = try resolve(documentID)
        var entities: [SelectedEntity] = []
        for pick in model.selection {
            if pick.isWholeBody {
                if let body = model.meshes[safe: pick.body] { entities.append(SelectedEntity(id: body.id, type: "body", featureId: body.id)) }
            } else if pick.isFace, let ref = model.faceRef(pick) {
                entities.append(SelectedEntity(id: AIEntityRef.face(ref).string, type: "face", featureId: ref.body))
            } else if pick.isEdge, let name = model.name(of: pick), let body = model.meshes[safe: pick.body] {
                entities.append(SelectedEntity(id: AIEntityRef.edge(EdgeRef(body: body.id, edge: name)).string, type: "edge", featureId: body.id))
            } else if let p = model.profile(of: pick) {
                let id = profileID(p.ref, sketch: p.sketch, in: model)
                entities.append(SelectedEntity(id: id, type: "profile", featureId: p.sketch))
            } else if let c = model.curve(of: pick) {
                entities.append(SelectedEntity(id: AIEntityRef.curve(sketch: c.sketch, id: c.curve).string, type: "curve", featureId: c.sketch))
            } else if pick.kind == .plane, let plane = model.planeRef(of: pick) {
                switch plane {
                case .xy, .xz, .yz, .plane: entities.append(SelectedEntity(id: AIEntityRef.text(for: plane), type: "plane", featureId: plane.featureID))
                case .face: break
                }
            }
        }
        return SelectionDescription(documentId: docID, revision: model.documentRevision, entities: entities,
                                    selectedFeature: model.selectedFeature)
    }

    // MARK: building the answers

    func parameters(of model: DocumentModel) -> [ParameterInfo] {
        let values = model.parameterValues
        return model.document.parameters.map { p in
            let q = values.values[p.name]
            let value: Double?, unit: String
            switch p.unit {
            case .length: value = q?.value; unit = "mm"
            case .angle: value = q.map { $0.value * 180 / .pi }; unit = "deg"
            case .none: value = q?.value; unit = ""
            }
            return ParameterInfo(name: p.name, expression: p.expression, unit: unit, value: value,
                                 comment: p.comment.isEmpty ? nil : p.comment, error: values.errors[p.name],
                                 usedBy: model.document.features(using: p.name).map(\.id))
        }
    }

    func bodies(of model: DocumentModel) -> [BodyInfo] {
        model.bodies.map { b in
            // The tight box (what the Measure tool shows): the quick one the viewport uses is padded by a few hundredths of a
            // millimetre round curved faces, which would make a 35 mm part read as 35.08.
            let bounds = (try? b.body.measure(.body))?.bounds ?? b.body.bounds
            return BodyInfo(id: b.id, name: b.name, visible: !model.isHidden(b.id), volume: b.body.volume,
                            boundsMin: bounds.map { [$0.min.x, $0.min.y, $0.min.z] } ?? [],
                            boundsMax: bounds.map { [$0.max.x, $0.max.y, $0.max.z] } ?? [],
                            faceCount: b.body.faceNames.count, edgeCount: b.body.edgeNames.count, isValid: b.body.isValid)
        }
    }

    func featureInfo(at index: Int, in model: DocumentModel, describer: FeatureDescriber) -> FeatureInfo {
        let doc = model.document
        let f = doc.features[index]
        let error = model.result?.errors[f.id]
        let status = f.suppressed ? "suppressed" : index >= model.markerPosition ? "rolled_back" : error != nil ? "error" : "ok"
        let order = Dictionary(uniqueKeysWithValues: doc.features.enumerated().map { ($1.id, $0) })
        func inTimelineOrder(_ ids: some Sequence<FeatureID>) -> [FeatureID] { ids.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) } }
        return FeatureInfo(
            id: f.id, type: f.typeName, name: f.name, index: index, suppressed: f.suppressed, status: status, error: error,
            createsBody: f.createsBody, parameters: describer.fields(of: f),
            dependencies: inTimelineOrder(f.references.filter { order[$0] != nil }),
            children: doc.features.filter { $0.references.contains(f.id) }.map(\.id))
    }

    func sketchInfo(_ id: FeatureID, in model: DocumentModel, describer: FeatureDescriber) -> SketchInfo? {
        guard let feature = model.document.features.first(where: { $0.id == id }), case .sketch(let sf) = feature.kind else { return nil }
        let built = model.result?.sketches[id]
        let sketch = built?.solved ?? sf.sketch
        var profiles: [ProfileInfo] = []
        if let built {
            let refs = built.regions.map { r in r.tags.split(separator: ",").map(String.init).sorted() }
            var seen: [[String]: Int] = [:]
            for (r, curves) in zip(built.regions, refs) {
                let same = refs.filter { $0 == curves }.count
                seen[curves, default: 0] += 1
                profiles.append(ProfileInfo(
                    id: AIEntityRef.profile(sketch: id, curves: curves, copy: same > 1 ? seen[curves]! : 0).string,
                    area: r.area, inside: [r.sample.x, r.sample.y], bounds: Self.bounds(ofRegion: r.index, in: built), insideProfile: nil))
            }
            for (i, container) in Self.enclosingRegions(in: built, profiles: profiles) { profiles[i].insideProfile = profiles[container].id }
        }
        return SketchInfo(points: sketch.points.filter { $0.id != "origin" }.count, curves: sketch.curves.count,
                          constraints: sketch.constraints.count,
                          texts: sketch.texts.map { TextInfo(id: $0.id, text: $0.text, height: describer.length($0.height), font: $0.font) },
                          dimensions: describer.dimensions(of: sketch), profiles: profiles,
                          degreesOfFreedom: built?.solve.degreesOfFreedom)
    }

    /// For each profile that lies inside another one (its bounds within the other's, and smaller): the index of the smallest such
    /// profile. That is the shape of a hole's filling: the disc in a ring, the inside of an o.
    static func enclosingRegions(in built: SketchResult, profiles: [ProfileInfo]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (i, p) in profiles.enumerated() where p.bounds.count == 4 {
            let candidates = profiles.indices.filter { j in
                let q = profiles[j]
                return j != i && q.bounds.count == 4 && q.area > p.area + 1e-9
                    && q.bounds[0] <= p.bounds[0] + 1e-6 && q.bounds[1] <= p.bounds[1] + 1e-6
                    && q.bounds[2] >= p.bounds[2] - 1e-6 && q.bounds[3] >= p.bounds[3] - 1e-6
            }
            if let best = candidates.min(by: { profiles[$0].area < profiles[$1].area }) { out.append((i, best)) }
        }
        return out
    }

    /// [min u, min v, max u, max v] of a region, in the sketch's own coordinates.
    static func bounds(ofRegion index: Int, in built: SketchResult) -> [Double] {
        guard index < built.regionMeshes.count else { return [] }
        let positions = built.regionMeshes[index].positions
        var lo = SIMD2(Double.infinity, Double.infinity), hi = SIMD2(-Double.infinity, -Double.infinity)
        for i in stride(from: 0, to: positions.count - 2, by: 3) {
            let p = SIMD3(Double(positions[i]), Double(positions[i + 1]), Double(positions[i + 2])) - built.frame.origin
            let uv = SIMD2(simd_dot(p, built.frame.xAxis), simd_dot(p, built.frame.yAxis))
            lo = simd_min(lo, uv); hi = simd_max(hi, uv)
        }
        guard lo.x.isFinite else { return [] }
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        return [r(lo.x), r(lo.y), r(hi.x), r(hi.y)]
    }

    private func profileID(_ ref: ProfileRef, sketch: FeatureID, in model: DocumentModel) -> String {
        guard let built = model.result?.sketches[sketch] else { return AIEntityRef.profile(sketch: sketch, curves: ref.curves, copy: 0).string }
        let curves = ref.curves.sorted()
        let group = built.regions.indices.filter { built.regions[$0].tags.split(separator: ",").map(String.init).sorted() == curves }
        func distance(_ i: Int) -> Double {
            let s = built.regions[i].sample
            return (s.x - ref.hintU) * (s.x - ref.hintU) + (s.y - ref.hintV) * (s.y - ref.hintV)
        }
        var copy = 0
        if group.count > 1, let nearest = group.min(by: { distance($0) < distance($1) }), let at = group.firstIndex(of: nearest) { copy = at + 1 }
        return AIEntityRef.profile(sketch: sketch, curves: curves, copy: copy).string
    }
}

extension PlaneRef {
    /// The feature a plane comes from (a construction plane's, or the body of a face), nil for an origin plane.
    var featureID: FeatureID? {
        switch self {
        case .xy, .xz, .yz: return nil
        case .plane(let id): return id
        case .face(let f): return f.body
        }
    }
}

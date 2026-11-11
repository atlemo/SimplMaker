// Operations that finish a body: round or bevel its edges. Both are the app's own Fillet and Chamfer features, with the
// same settings, so they appear in the timeline and the inspector like the ones the user makes.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

struct EdgeFinishOperation: AIOperation {
    let fillet: Bool
    /// Edge ids ("edge:<body>/<name>").
    let edges: [String]
    /// Face ids: every edge around each of them is finished.
    let faces: [String]
    let size: String
    let mode: ChamferMode
    let second: String?
    let flipped: Bool
    /// A fillet that curves the other way (see EdgeFeature.concave).
    var concave = false
    let name: String?
    let id: String?
    private var kindName: String { fillet ? "Fillet" : "Chamfer" }
    var toolName: String { fillet ? "create_fillet" : "create_chamfer" }
    var label: String { "Create \(name?.nonEmpty ?? kindName)" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a \(kindName.lowercased())")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard !edges.isEmpty || !faces.isEmpty else {
            throw AIError(.invalidArguments, "Nothing to \(fillet ? "round" : "bevel"): edges and faces are both empty.",
                          reason: "Pass edges (ids like \"edge:<body>/<name>\") and/or faces (ids like \"face:<body>/<name>\", every edge around the face is used). get_body lists both.")
        }
        _ = try AIValues.evaluate(size, kind: .length, field: "size", positive: true, values: context.values)
        var feature = EdgeFeature(edges: [], faces: [], size: size, flipped: flipped, concave: concave)
        if !fillet {
            feature.setMode(mode)
            if let kind = mode.secondKind {
                guard let second else {
                    throw AIError(.invalidArguments, "second is required for the chamfer mode \"\(Self.modeName(mode))\".",
                                  reason: kind == .angle ? "The angle the chamfer makes with the first face, for example 45." : "The distance on the other face, for example 3.")
                }
                _ = try AIValues.evaluate(second, kind: kind, field: "second", positive: true, values: context.values)
                feature.second = second
            } else if second != nil {
                throw AIError(.invalidArguments, "second is not used by the chamfer mode \"equal_distance\".",
                              reason: "Use mode \"two_distances\" or \"distance_angle\" to give a second value.")
            }
        } else if mode != .equalDistance || second != nil {
            throw AIError(.invalidArguments, "A fillet has only a size: mode and second are for chamfers.")
        }
        if concave && !fillet { throw AIError(.invalidArguments, "concave is for fillets only.") }

        var edgeCount = Set<String>()
        for text in edges {
            guard case .edge(let ref)? = AIEntityRef(text) else {
                throw AIError(.invalidArguments, "\"\(text)\" is not an edge id.", reason: "Edge ids look like \"edge:<body>/<name>\"; get_body lists them.")
            }
            guard let body = context.built.body(ref.body) else {
                throw AIError(.featureNotFound, "There is no body with the id \(ref.body).", reason: "Call get_document for the bodies the part has.")
            }
            guard body.hasEdge(ref.edge) else {
                throw AIError(.featureNotFound, "\"\(text)\" is not an edge of \(ref.body).", reason: "Edge names change when the part is edited; read them again with get_body.")
            }
            if !feature.edges.contains(ref) { feature.edges.append(ref) }
            edgeCount.insert("\(ref.body)/\(ref.edge)")
        }
        for text in faces {
            guard case .face(let ref)? = AIEntityRef(text) else {
                throw AIError(.invalidArguments, "\"\(text)\" is not a face id.", reason: "Face ids look like \"face:<body>/<name>\"; get_body lists them.")
            }
            guard let body = context.built.body(ref.body) else {
                throw AIError(.featureNotFound, "There is no body with the id \(ref.body).", reason: "Call get_document for the bodies the part has.")
            }
            guard body.hasFace(ref.face) else {
                throw AIError(.featureNotFound, "\"\(text)\" is not a face of \(ref.body).", reason: "Face names change when the part is edited; read them again with get_body.")
            }
            if !feature.faces.contains(ref) { feature.faces.append(ref) }
            for edge in (try? body.faceEdges(ref.face)) ?? [] { edgeCount.insert("\(ref.body)/\(edge)") }
        }

        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName(kindName)
        doc.addFeature(Feature(id: featureID, name: featureName, fillet ? .fillet(feature) : .chamfer(feature)))
        let how = fillet ? "radius \(size)\(concave ? ", concave" : "")" : (mode == .equalDistance ? "distance \(size)" : "\(size) and \(feature.second) (\(Self.modeName(mode)))")
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(fillet ? "rounded" : "bevelled") \(edgeCount.count) edge\(edgeCount.count == 1 ? "" : "s"), \(how).")
    }

    nonisolated static func modeName(_ mode: ChamferMode) -> String {
        switch mode {
        case .equalDistance: return "equal_distance"
        case .distanceAngle: return "distance_angle"
        case .twoDistances: return "two_distances"
        }
    }
}

extension CADService {
    /// One fillet or chamfer, as one transaction (the tools and the tests use this).
    func createEdgeFinish(documentID: String, expectedRevision: Int? = nil, fillet: Bool, edges: [String] = [], faces: [String] = [], size: String,
                          mode: ChamferMode = .equalDistance, second: String? = nil, flipped: Bool = false, concave: Bool = false,
                          name: String? = nil, id: String? = nil) async throws -> ChangeResult {
        try await change(documentID: documentID, expectedRevision: expectedRevision,
                         EdgeFinishOperation(fillet: fillet, edges: edges, faces: faces, size: size, mode: mode, second: second,
                                             flipped: flipped, concave: concave, name: name, id: id))
    }
}

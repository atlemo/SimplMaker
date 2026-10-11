// Operations on sketches and what is made from them: a new sketch, shapes added to one, an extrude of its profiles.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd

struct CreateSketchOperation: AIOperation {
    let plane: String?
    let name: String?
    let id: String?
    var toolName: String { "create_sketch" }
    var label: String { "Create \(name?.nonEmpty ?? "Sketch")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a sketch")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let planeRef = try plane.map { try AIValues.plane($0, in: doc) } ?? .xy
        if case .face(let face) = planeRef {
            guard let body = context.built.body(face.body), (try? body.faceFrame(face.face)) != nil else {
                throw AIError(.invalidArguments, "\"\(AIEntityRef.face(face).string)\" is not a flat face of a body that exists.",
                              reason: "Only flat faces can hold a sketch. get_body lists a body's faces with their shape and direction.")
            }
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Sketch")
        doc.addFeature(Feature(id: featureID, name: featureName, .sketch(SketchFeature(plane: planeRef, sketch: Sketch()))))
        return OperationOutcome(featureID: featureID, message: "Created \(featureName) on \(AIEntityRef.text(for: planeRef)). It is empty: add shapes with edit_sketch.",
                                created: ["sketch_id": .string(featureID)])
    }
}

struct EditSketchOperation: AIOperation {
    let sketchID: FeatureID
    let add: [SketchShape]
    var sketchName: String?
    var toolName: String { "edit_sketch" }
    var label: String { "Edit \(sketchName ?? "Sketch")" }
    var activity: String { "Drawing in \(sketchName ?? "a sketch")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        guard !add.isEmpty else {
            throw AIError(.invalidArguments, "add is empty: there is nothing to draw.", reason: "Pass a list of shapes, for example [{\"type\": \"circle\", \"center\": [0, 0], \"diameter\": 5}].")
        }
        guard let index = doc.index(of: sketchID), case .sketch(var sf) = doc.features[index].kind else {
            throw AIError(.featureNotFound, "There is no sketch with the id \(sketchID).", reason: "Create one with create_sketch, or take the id from get_document.")
        }
        var sketch = sf.sketch
        var made: [ShapeResult] = []
        for (n, shape) in add.enumerated() {
            do { made.append(try SketchBuilder.build(shape, into: &sketch, values: context.values)) } catch var error as AIError {
                if add.count > 1 { error.message = "Shape \(n + 1) of \(add.count) (\(shape.typeName)): " + error.message }
                throw error
            }
        }
        sf.sketch = sketch
        doc.features[index].kind = .sketch(sf)
        let summary = made.map { "\($0.type) \($0.id)" }.joined(separator: ", ")
        return OperationOutcome(featureID: sketchID, message: "Added \(summary) to \(doc.features[index].name).",
                                created: ["shapes": .array(made.map(\.json))])
    }
}

/// Which profiles (closed regions) of a sketch to use.
enum ProfileSelector: Sendable {
    /// A profile id from get_feature ("profile:<sketch>/<curves>").
    case id(String)
    /// Whichever profile contains this point of the sketch.
    case at(SketchPoint2)
    /// Every profile that is not the filling of a hole in another (the shape of the whole drawing: a plate with its hole, the rings
    /// of the letters and not their insides).
    case solid
}

struct CreateExtrudeOperation: AIOperation {
    enum Direction: String, Sendable { case forward, backward, symmetric }
    let sketchID: FeatureID
    let profiles: [ProfileSelector]
    /// Nil: through all (cut only).
    let distance: String?
    let direction: Direction
    let operation: BodyOperation
    let target: FeatureID?
    let startFace: String?
    let name: String?
    let id: String?
    var toolName: String { "create_extrude" }
    var label: String { "Create \(name?.nonEmpty ?? "Extrude")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "an extrude")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard let sketchFeature = doc.features.first(where: { $0.id == sketchID }), case .sketch = sketchFeature.kind else {
            throw AIError(.featureNotFound, "There is no sketch with the id \(sketchID).", reason: "Create one with create_sketch, or take the id from get_document.")
        }
        guard let built = context.built.sketches[sketchID] else {
            throw AIError(.invalidValue, "\(sketchFeature.name) has no profiles to extrude: it is empty or failed to build.",
                          reason: "Add closed shapes with edit_sketch first, and check the sketch's status with get_feature.")
        }
        guard !profiles.isEmpty else {
            throw AIError(.invalidArguments, "profiles is empty.", reason: "Pick at least one profile: an id from get_feature, or {\"at\": [u, v]} for the profile containing a point.")
        }
        var refs: [ProfileRef] = []
        for selector in profiles {
            for ref in try resolve(selector, in: built, sketchName: sketchFeature.name, values: context.values) where !refs.contains(ref) { refs.append(ref) }
        }
        var extent: ExtrudeExtent
        if let distance {
            _ = try AIValues.evaluate(distance, kind: .length, field: "distance", positive: true, values: context.values)
            extent = direction == .symmetric ? .symmetric(distance) : .distance(distance)
        } else {
            guard operation == .cut else {
                throw AIError(.invalidArguments, "Without a distance an extrude goes through everything, which only makes sense as a cut.",
                              reason: "Send distance, or use operation \"cut\" with through_all.")
            }
            extent = .throughAll
        }
        if let target {
            guard doc.features.contains(where: { $0.id == target && $0.createsBody }) else {
                throw AIError(.invalidArguments, "target \"\(target)\" is not a body.", reason: "Use the id of a body from get_document.")
            }
        }
        if operation != .newBody, !doc.features.contains(where: \.createsBody) {
            throw AIError(.invalidArguments, "operation \"\(operation.rawValue)\" needs a body to work on, and the part has none.", reason: "Use operation \"new_body\" for the first body.")
        }
        var feature = ExtrudeFeature(sketch: sketchID, profiles: refs, extent: extent, flipped: direction == .backward,
                                     operation: operation, target: target)
        if let startFace {
            guard case .face(let face)? = AIEntityRef(startFace), context.built.body(face.body) != nil,
                  (try? context.built.body(face.body)?.faceFrame(face.face)) != nil else {
                throw AIError(.invalidArguments, "start_face \"\(startFace)\" is not a flat face of a body that exists.", reason: "Take it from get_body.")
            }
            feature.start = FaceRef(body: face.body, face: face.face)
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Extrude")
        doc.addFeature(Feature(id: featureID, name: featureName, .extrude(feature)))
        let how = distance.map { "by \($0)" } ?? "through all"
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): extruded \(refs.count) profile\(refs.count == 1 ? "" : "s") of \(sketchFeature.name) \(how) (\(AIOperationNames.name(operation))).",
                                created: ["profiles": .array(refs.map { .string(AIEntityRef.profile(sketch: sketchID, curves: $0.curves, copy: 0).string) })])
    }

    private func resolve(_ selector: ProfileSelector, in built: SketchResult, sketchName: String, values: ParameterValues) throws -> [ProfileRef] {
        switch selector {
        case .solid:
            let infos = built.regions.map { r in ProfileInfo(id: "", area: r.area, inside: [], bounds: CADService.bounds(ofRegion: r.index, in: built), insideProfile: nil) }
            let enclosed = Set(CADService.enclosingRegions(in: built, profiles: infos).map(\.0))
            let solid = built.regions.indices.filter { !enclosed.contains($0) }.map { built.regions[$0] }
            guard !solid.isEmpty else {
                throw AIError(.invalidArguments, "\(sketchName) has no profiles to extrude.", reason: "Add closed shapes with edit_sketch first.")
            }
            return solid.map { ProfileRef(curves: $0.tags.split(separator: ",").map(String.init), hintU: $0.sample.x, hintV: $0.sample.y) }
        case .id(let text):
            guard case .profile(let sketch, let curves, let copy)? = AIEntityRef(text) else {
                throw AIError(.invalidArguments, "\"\(text)\" is not a profile id.", reason: "Profile ids look like \"profile:<sketch>/<curves>\"; get_feature lists them for a sketch.")
            }
            guard sketch == sketchID else {
                throw AIError(.invalidArguments, "The profile \"\(text)\" belongs to the sketch \(sketch), not \(sketchID).")
            }
            let matches = built.regions.filter { Set($0.tags.split(separator: ",").map(String.init)) == Set(curves) }
            guard !matches.isEmpty else {
                throw AIError(.invalidArguments, "\(sketchName) has no profile \"\(text)\".", reason: "The sketch may have changed: read its current profiles with get_feature.")
            }
            let region = copy > 0 && copy <= matches.count ? matches[copy - 1] : matches[0]
            return [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)]
        case .at(let p):
            let point = SIMD2(try SketchBuilder.value(p.x, "at.x", values), try SketchBuilder.value(p.y, "at.y", values))
            let probe = ProfileRef(curves: [], hintU: point.x, hintV: point.y)
            guard let region = Regenerator.region(probe, in: built) else {
                throw AIError(.invalidArguments, "No profile of \(sketchName) contains the point (\(AIValues.number(point.x)), \(AIValues.number(point.y))).",
                              reason: "Profiles are the closed regions of the sketch; get_feature lists each with a point inside it and its bounds.")
            }
            return [ProfileRef(curves: region.tags.split(separator: ",").map(String.init), hintU: region.sample.x, hintV: region.sample.y)]
        }
    }
}

extension CADService {
    /// One extrude, as one transaction (the tool and the tests use this).
    func createExtrude(documentID: String, expectedRevision: Int? = nil, sketchID: FeatureID, profiles: [ProfileSelector], distance: String?,
                       direction: CreateExtrudeOperation.Direction = .forward, operation: BodyOperation = .newBody, target: FeatureID? = nil,
                       startFace: String? = nil, name: String? = nil, id: String? = nil) async throws -> ChangeResult {
        try await change(documentID: documentID, expectedRevision: expectedRevision,
                         CreateExtrudeOperation(sketchID: sketchID, profiles: profiles, distance: distance, direction: direction,
                                                operation: operation, target: target, startFace: startFace, name: name, id: id))
    }
}

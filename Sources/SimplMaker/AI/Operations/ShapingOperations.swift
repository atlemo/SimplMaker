// More ways to make and change shapes: a sweep along a path, a loft between sections, a thread, a draft angle, a construction
// plane, a move (with turns) and a scale. Each makes the app's own feature, with the settings the app has.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation

// MARK: sweep

struct CreateSweepOperation: AIOperation {
    let sketchID: FeatureID
    let profiles: [ProfileSelector]
    /// Curve ids ("curve:<sketch>/<id>") of one sketch, which together make one connected path.
    let path: [String]
    let operation: BodyOperation
    let target: FeatureID?
    let name: String?
    let id: String?
    var toolName: String { "create_sweep" }
    var label: String { "Create \(name?.nonEmpty ?? "Sweep")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a sweep")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard let sketchFeature = doc.features.first(where: { $0.id == sketchID }), case .sketch = sketchFeature.kind else {
            throw AIError(.featureNotFound, "There is no sketch with the id \(sketchID).", reason: "Create one with create_sketch, or take the id from get_document.")
        }
        guard let built = context.built.sketches[sketchID] else {
            throw AIError(.invalidValue, "\(sketchFeature.name) has no profiles to sweep: it is empty or failed to build.", reason: "Add a closed shape with edit_sketch first.")
        }
        let refs = try CreateExtrudeOperation.resolve(profiles, sketchID: sketchID, in: built, sketchName: sketchFeature.name, values: context.values)
        guard !refs.isEmpty else { throw AIError(.invalidArguments, "profiles is empty.") }
        let (pathSketch, curves) = try AIChecks.curves(path, field: "path", context)
        guard pathSketch != sketchID else {
            throw AIError(.invalidArguments, "The path and the profile are in the same sketch (\(sketchID)).",
                          reason: "Draw the profile in one sketch and the path in another: the profile on a plane square to the start of the path, the path on the plane it runs in.")
        }
        try AIChecks.requireBody(for: operation, target: target, in: doc)
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Sweep")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .sweep(SweepFeature(sketch: sketchID, profiles: refs, path: CurveRef(sketch: pathSketch, curves: curves), operation: operation, target: target))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): swept \(refs.count) profile\(refs.count == 1 ? "" : "s") of \(sketchFeature.name) along \(curves.count) curve\(curves.count == 1 ? "" : "s") of \(pathSketch) (\(AIOperationNames.name(operation))).")
    }
}

// MARK: loft

struct LoftSectionRequest: Sendable {
    let sketchID: FeatureID
    let profile: ProfileSelector
}

struct CreateLoftOperation: AIOperation {
    let sections: [LoftSectionRequest]
    let ruled: Bool
    let operation: BodyOperation
    let target: FeatureID?
    let name: String?
    let id: String?
    var toolName: String { "create_loft" }
    var label: String { "Create \(name?.nonEmpty ?? "Loft")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a loft")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard sections.count >= 2 else {
            throw AIError(.invalidArguments, "A loft needs at least two sections (sketches with a closed shape each).", reason: "Draw each section in its own sketch, on planes at different heights, and pass them in order.")
        }
        var made: [LoftSection] = []
        for (n, section) in sections.enumerated() {
            guard let sketchFeature = doc.features.first(where: { $0.id == section.sketchID }), case .sketch = sketchFeature.kind else {
                throw AIError(.featureNotFound, "sections[\(n)]: there is no sketch with the id \(section.sketchID).")
            }
            guard let built = context.built.sketches[section.sketchID] else {
                throw AIError(.invalidValue, "sections[\(n)]: \(sketchFeature.name) has no profiles: it is empty or failed to build.")
            }
            let refs = try CreateExtrudeOperation.resolve([section.profile], sketchID: section.sketchID, in: built, sketchName: sketchFeature.name, values: context.values)
            guard refs.count == 1, let ref = refs.first else {
                throw AIError(.invalidArguments, "sections[\(n)]: the profile has to be one closed shape; \"\(sketchFeature.name)\" gave \(refs.count).",
                              reason: "Use a profile id from get_feature, or {\"at\": [u, v]} for the one containing a point.")
            }
            made.append(LoftSection(sketch: section.sketchID, profile: ref))
        }
        try AIChecks.requireBody(for: operation, target: target, in: doc)
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Loft")
        doc.addFeature(Feature(id: featureID, name: featureName, .loft(LoftFeature(sections: made, ruled: ruled, operation: operation, target: target))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): a \(ruled ? "ruled" : "smooth") loft through \(made.count) sections (\(AIOperationNames.name(operation))).")
    }
}

// MARK: thread

struct CreateThreadOperation: AIOperation {
    let faces: [String]
    let standard: ThreadStandard
    let size: String
    let length: String?
    let flipped: Bool
    let leftHanded: Bool
    /// An offset for printing: a percentage of the diameter, or a distance on the diameter.
    let tolerance: String?
    let toleranceUnit: ThreadToleranceUnit
    let name: String?
    let id: String?
    var toolName: String { "create_thread" }
    var label: String { "Create \(name?.nonEmpty ?? "Thread")" }
    var activity: String { "Cutting \(name?.nonEmpty ?? "a thread")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard !faces.isEmpty else {
            throw AIError(.invalidArguments, "faces is empty.", reason: "Pass the round face to thread: the outside of a shaft or the inside of a hole (get_body lists faces with shape \"cylinder\").")
        }
        guard standard.size(size) != nil else {
            let names = standard.sizes.map(\.name).joined(separator: ", ")
            throw AIError(.invalidArguments, "\(size) is not a size in \(standard.rawValue).", reason: "The sizes are: \(names).")
        }
        if let length { _ = try AIValues.evaluate(length, kind: .length, field: "length", positive: true, values: context.values) }
        if let tolerance {
            _ = try AIValues.evaluate(tolerance, kind: toleranceUnit == .percent ? .none : .length, field: "tolerance", positive: false, values: context.values)
        }
        var refs: [FaceRef] = []
        for text in faces {
            let (ref, body) = try AIChecks.face(text, field: "faces", context)
            guard (try? body.faceCylinder(ref.face, flipped: flipped)) != nil else {
                throw AIError(.invalidArguments, "\"\(text)\" is not a round (cylindrical) face.", reason: "A thread goes on the outside of a shaft or the inside of a hole; get_body shows each face's shape.")
            }
            if !refs.contains(ref) { refs.append(ref) }
        }
        let feature = ThreadFeature(face: refs[0], moreFaces: Array(refs.dropFirst()), standard: standard, size: size, length: length, flipped: flipped,
                                    leftHanded: leftHanded, tolerance: tolerance, toleranceUnit: toleranceUnit)
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Thread")
        doc.addFeature(Feature(id: featureID, name: featureName, .thread(feature)))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(size) (\(standard.rawValue)) thread on \(refs.count) face\(refs.count == 1 ? "" : "s")" + (length.map { ", \($0) long" } ?? "") + ".")
    }
}

// MARK: draft

struct CreateDraftOperation: AIOperation {
    let body: String
    let faces: [String]
    let fixedFace: String
    let angle: String
    let name: String?
    let id: String?
    var toolName: String { "create_draft" }
    var label: String { "Create \(name?.nonEmpty ?? "Draft")" }
    var activity: String { "Drafting \(body)" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        _ = try AIChecks.body(body, field: "body", context)
        guard !faces.isEmpty else {
            throw AIError(.invalidArguments, "faces is empty.", reason: "Pass the side faces to lean, for example the four walls of a box.")
        }
        let degrees = try AIValues.evaluate(angle, kind: .angle, field: "angle", positive: false, values: context.values) * 180 / .pi
        guard abs(degrees) > 1e-9, abs(degrees) < 89.9 else {
            throw AIError(.invalidValue, "angle must be more than 0 and less than 90 degrees (\"\(angle)\" comes to \(AIValues.number(degrees))).",
                          reason: "A draft is usually 1 to 5 degrees. A negative angle leans the faces the other way.")
        }
        var refs: [FaceRef] = []
        for text in faces {
            let (ref, _) = try AIChecks.face(text, field: "faces", context)
            guard ref.body == body else { throw AIError(.invalidArguments, "\"\(text)\" belongs to \(ref.body), not to \(body).") }
            if !refs.contains(ref) { refs.append(ref) }
        }
        let (fixed, fixedBody) = try AIChecks.face(fixedFace, field: "fixed_face", context)
        guard fixed.body == body, (try? fixedBody.faceFrame(fixed.face)) != nil else {
            throw AIError(.invalidArguments, "fixed_face \"\(fixedFace)\" must be a flat face of \(body).",
                          reason: "It is the face that stays put (usually the bottom or the parting face); the faces lean away from it.")
        }
        guard !refs.contains(fixed) else { throw AIError(.invalidArguments, "fixed_face cannot also be one of the faces to lean.") }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Draft")
        doc.addFeature(Feature(id: featureID, name: featureName, .draft(DraftFeature(body: body, faces: refs, fixed: fixed, angle: angle))))
        return OperationOutcome(featureID: featureID, message: "Created \(featureName): \(refs.count) face\(refs.count == 1 ? "" : "s") of \(body) leaned by \(angle) away from \(fixedFace).")
    }
}

// MARK: plane

struct CreatePlaneOperation: AIOperation {
    let base: String
    let offset: String
    let angle: String
    let vertical: Bool
    let name: String?
    let id: String?
    var toolName: String { "create_plane" }
    var label: String { "Create \(name?.nonEmpty ?? "Plane")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a plane")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let baseRef = try AIValues.plane(base, in: doc)
        if case .face(let face) = baseRef {
            guard let body = context.built.body(face.body), (try? body.faceFrame(face.face)) != nil else {
                throw AIError(.invalidArguments, "\"\(base)\" is not a flat face of a body that exists.")
            }
        }
        _ = try AIValues.evaluate(offset, kind: .length, field: "offset", positive: false, values: context.values)
        _ = try AIValues.evaluate(angle, kind: .angle, field: "angle", positive: false, values: context.values)
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Plane")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .plane(PlaneFeature(base: baseRef, offset: offset, angle: angle, axis: vertical ? .vertical : .horizontal))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(offset) from \(AIEntityRef.text(for: baseRef)), turned \(angle). Use it as plane \"plane:\(featureID)\" in create_sketch, create_mirror or create_plane.")
    }
}

// MARK: move and scale

struct CreateMoveOperation: AIOperation {
    var pivot: [String]? = nil
    let bodies: [String]
    let sketches: [String]
    let dx: String, dy: String, dz: String
    let rx: String, ry: String, rz: String
    let name: String?
    let id: String?
    var toolName: String { "create_move" }
    var label: String { "Create \(name?.nonEmpty ?? "Move")" }
    var activity: String { "Moving" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard !bodies.isEmpty || !sketches.isEmpty else {
            throw AIError(.invalidArguments, "bodies and sketches are both empty: there is nothing to move.", reason: "Pass body ids from get_document, and/or sketch ids.")
        }
        for b in bodies { _ = try AIChecks.body(b, field: "bodies", context) }
        for s in sketches {
            guard doc.features.contains(where: { $0.id == s && { if case .sketch = $0.kind { return true } else { return false } }($0) }) else {
                throw AIError(.featureNotFound, "sketches: \"\(s)\" is not a sketch.", reason: "Take sketch ids from get_document.")
            }
        }
        for (field, text) in zip(["px", "py", "pz"], pivot ?? []) { _ = try AIValues.evaluate(text, kind: .length, field: field, positive: false, values: context.values) }
        var total = 0.0
        for (field, text) in [("dx", dx), ("dy", dy), ("dz", dz)] { total += abs(try AIValues.evaluate(text, kind: .length, field: field, positive: false, values: context.values)) }
        for (field, text) in [("rx", rx), ("ry", ry), ("rz", rz)] { total += abs(try AIValues.evaluate(text, kind: .angle, field: field, positive: false, values: context.values)) }
        guard total > 1e-12 else {
            throw AIError(.invalidArguments, "Every distance and angle is zero: nothing would move.", reason: "Send dx, dy, dz (mm) and/or rx, ry, rz (degrees).")
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Move")
        doc.addFeature(Feature(id: featureID, name: featureName, .move(MoveFeature(bodies: bodies, sketches: sketches, dx: dx, dy: dy, dz: dz, rx: rx, ry: ry, rz: rz, pivot: pivot))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): moved \((bodies + sketches).joined(separator: ", ")) by (\(dx), \(dy), \(dz)) after turning by (\(rx), \(ry), \(rz)).")
    }
}

struct CreateScaleOperation: AIOperation {
    let bodies: [String]
    let sketches: [String]
    let factor: String
    let name: String?
    let id: String?
    var toolName: String { "create_scale" }
    var label: String { "Create \(name?.nonEmpty ?? "Scale")" }
    var activity: String { "Scaling" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard !bodies.isEmpty || !sketches.isEmpty else {
            throw AIError(.invalidArguments, "bodies and sketches are both empty: there is nothing to scale.", reason: "Pass body ids from get_document, and/or sketch ids.")
        }
        for b in bodies { _ = try AIChecks.body(b, field: "bodies", context) }
        for s in sketches {
            guard doc.features.contains(where: { $0.id == s && { if case .sketch = $0.kind { return true } else { return false } }($0) }) else {
                throw AIError(.featureNotFound, "sketches: \"\(s)\" is not a sketch.", reason: "Take sketch ids from get_document.")
            }
        }
        let value = try AIValues.evaluate(factor, kind: .none, field: "factor", positive: true, values: context.values)
        guard abs(value - 1) > 1e-12 else { throw AIError(.invalidValue, "factor 1 would leave everything as it is.") }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Scale")
        doc.addFeature(Feature(id: featureID, name: featureName, .scale(ScaleFeature(sketches: sketches, bodies: bodies, factor: factor))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \((bodies + sketches).joined(separator: ", ")) scaled by \(factor) (\(AIValues.number(value))×), bodies about the middle of their bounding box.")
    }
}

extension AIChecks {
    /// Curve ids ("curve:<sketch>/<id>") that all belong to one sketch, which exists and has them.
    static func curves(_ texts: [String], field: String, _ context: OperationContext) throws -> (sketch: FeatureID, curves: [EntityID]) {
        guard !texts.isEmpty else {
            throw AIError(.invalidArguments, "\(field) is empty.", reason: "Pass curve ids such as \"curve:<sketch>/<curve>\"; get_feature lists a sketch's shapes with their ids.")
        }
        var sketch: FeatureID?
        var curves: [EntityID] = []
        for text in texts {
            guard case .curve(let s, let c)? = AIEntityRef(text) else {
                throw AIError(.invalidArguments, "\(field) \"\(text)\" is not a curve id.", reason: "Curve ids look like \"curve:<sketch>/<curve>\".")
            }
            if let sketch, sketch != s { throw AIError(.invalidArguments, "\(field) mixes curves of two sketches (\(sketch) and \(s)).", reason: "A path has to be drawn in one sketch.") }
            sketch = s
            guard let built = context.built.sketches[s] else { throw AIError(.featureNotFound, "There is no built sketch \(s).", reason: "Check its status with get_feature.") }
            guard built.solved.curve(c) != nil else {
                throw AIError(.featureNotFound, "\(s) has no curve \"\(c)\".", reason: "get_feature lists the sketch's shapes and their curves.")
            }
            if !curves.contains(c) { curves.append(c) }
        }
        return (sketch!, curves)
    }
}

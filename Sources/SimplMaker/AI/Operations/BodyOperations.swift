// Operations that work on whole bodies or on a face of one: a drilled hole, a shell, a mirror, a pattern of copies, a combine
// of bodies, a revolve of sketch profiles. Each makes the app's own feature, with the settings the app has.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// Checks shared by the operations here.
enum AIChecks {
    /// A body that exists as the part is now.
    static func body(_ id: String, field: String, _ context: OperationContext) throws -> KBody {
        guard let body = context.built.body(id) else {
            let known = context.built.bodies.map(\.id).joined(separator: ", ")
            throw AIError(.featureNotFound, "\(field) \"\(id)\" is not a body of the part.",
                          reason: known.isEmpty ? "The part has no bodies yet." : "The bodies are: \(known). get_document lists them.")
        }
        return body
    }

    static func bodies(_ ids: [String], field: String, _ context: OperationContext) throws {
        guard !ids.isEmpty else {
            throw AIError(.invalidArguments, "\(field) is empty.", reason: "Pass the ids of one or more bodies (get_document lists them).")
        }
        for id in ids { _ = try body(id, field: field, context) }
    }

    /// A face that exists, as a FaceRef.
    static func face(_ text: String, field: String, _ context: OperationContext) throws -> (ref: FaceRef, body: KBody) {
        guard case .face(let ref)? = AIEntityRef(text) else {
            throw AIError(.invalidArguments, "\(field) \"\(text)\" is not a face id.", reason: "Face ids look like \"face:<body>/<name>\"; get_body lists them.")
        }
        let body = try self.body(ref.body, field: field, context)
        guard body.hasFace(ref.face) else {
            throw AIError(.featureNotFound, "\"\(text)\" is not a face of \(ref.body).", reason: "Face names change when the part is edited; read them again with get_body.")
        }
        return (ref, body)
    }

    static func requireBody(for operation: BodyOperation, target: FeatureID?, in doc: CADDocument) throws {
        if let target {
            guard doc.features.contains(where: { $0.id == target && $0.createsBody }) else {
                throw AIError(.invalidArguments, "target \"\(target)\" is not a body.", reason: "Use the id of a body from get_document.")
            }
        }
        if operation != .newBody, !doc.features.contains(where: \.createsBody) {
            throw AIError(.invalidArguments, "operation \"\(AIOperationNames.name(operation))\" needs a body to work on, and the part has none.",
                          reason: "Use operation \"new_body\" for the first body.")
        }
    }
}

// MARK: hole

struct CreateHoleOperation: AIOperation {
    let face: String
    /// A point in the part's coordinates [x, y, z] (mm); the hole goes where it meets the face.
    let at: [Double]?
    let u: String?
    let v: String?
    let kind: HoleKind
    let diameter: String
    /// Nil: through the whole body.
    let depth: String?
    let tipAngle: String?
    let headDiameter: String?
    let headDepth: String?
    let headAngle: String?
    let name: String?
    let id: String?
    var toolName: String { "create_hole" }
    var label: String { "Create \(name?.nonEmpty ?? "Hole")" }
    var activity: String { "Drilling \(name?.nonEmpty ?? "a hole")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let (ref, body) = try AIChecks.face(face, field: "face", context)
        guard let frame = try? body.faceFrame(ref.face) else {
            throw AIError(.invalidArguments, "\"\(face)\" is not a flat face, and a hole can only start on a flat one.",
                          reason: "get_body shows each face's shape: pick a \"plane\" face. For a hole in a curved wall, add a flat there first or cut with a sketch.")
        }
        let values = context.values
        let diameterValue = try AIValues.evaluate(diameter, kind: .length, field: "diameter", positive: true, values: values)
        if let depth { _ = try AIValues.evaluate(depth, kind: .length, field: "depth", positive: true, values: values) }

        // Where: a world point, or u and v in the face's own frame, or the middle of the face.
        var uText = u, vText = v
        if let at {
            guard at.count == 3, at.allSatisfy(\.isFinite) else {
                throw AIError(.invalidArguments, "at must be a point [x, y, z] in mm.", reason: "For example [10, 5, 20]. It is projected onto the face.")
            }
            guard u == nil, v == nil else { throw AIError(.invalidArguments, "Send at, or u and v, not both.") }
            let p = SIMD3(at[0], at[1], at[2]) - frame.origin
            uText = AIValues.number(simd_dot(p, frame.xAxis)) + " mm"
            vText = AIValues.number(simd_dot(p, frame.yAxis)) + " mm"
        } else if u == nil && v == nil {
            let p = ((try? body.faceOutlineCenter(ref.face)) ?? frame.origin) - frame.origin
            uText = AIValues.number(simd_dot(p, frame.xAxis)) + " mm"
            vText = AIValues.number(simd_dot(p, frame.yAxis)) + " mm"
        }
        let uValue = try AIValues.evaluate(uText ?? "0", kind: .length, field: "u", positive: false, values: values)
        let vValue = try AIValues.evaluate(vText ?? "0", kind: .length, field: "v", positive: false, values: values)
        let place = frame.point(uValue, vValue)
        if let bounds = try? body.measure(.face(ref.face)).bounds {
            let slack = 1e-3
            let inside = (0..<3).allSatisfy { place[$0] >= bounds.min[$0] - slack && place[$0] <= bounds.max[$0] + slack }
            guard inside else {
                throw AIError(.invalidArguments, "The hole's position (\(AIValues.number(place.x)), \(AIValues.number(place.y)), \(AIValues.number(place.z))) is outside the face.",
                              reason: "The face spans x \(AIValues.number(bounds.min.x))…\(AIValues.number(bounds.max.x)), y \(AIValues.number(bounds.min.y))…\(AIValues.number(bounds.max.y)), z \(AIValues.number(bounds.min.z))…\(AIValues.number(bounds.max.z)). Leave position out to use the middle of the face.")
            }
        }

        var hole = HoleFeature(face: ref, u: uText ?? "0 mm", v: vText ?? "0 mm", kind: kind, diameter: diameter, depth: depth)
        if let tipAngle {
            guard depth != nil else { throw AIError(.invalidArguments, "tip_angle only applies to a blind hole (one with a depth).") }
            _ = try AIValues.evaluate(tipAngle, kind: .angle, field: "tip_angle", positive: false, values: values)
            hole.tipAngle = tipAngle
        }
        switch kind {
        case .simple:
            guard headDiameter == nil, headDepth == nil, headAngle == nil else {
                throw AIError(.invalidArguments, "head_diameter, head_depth and head_angle are for counterbore and countersink holes.", reason: "Set kind to \"counterbore\" or \"countersink\".")
            }
        case .counterbore, .countersink:
            guard let headDiameter else {
                throw AIError(.invalidArguments, "head_diameter is required for a \(kind.rawValue.lowercased()) hole.", reason: "The diameter of the wider part, for example 9.")
            }
            let head = try AIValues.evaluate(headDiameter, kind: .length, field: "head_diameter", positive: true, values: values)
            guard head > diameterValue else {
                throw AIError(.invalidValue, "head_diameter (\(AIValues.number(head))) must be larger than diameter (\(AIValues.number(diameterValue))).")
            }
            hole.headDiameter = headDiameter
            if kind == .counterbore {
                guard let headDepth else { throw AIError(.invalidArguments, "head_depth is required for a counterbore hole.", reason: "How deep the wider part goes, for example 3.") }
                _ = try AIValues.evaluate(headDepth, kind: .length, field: "head_depth", positive: true, values: values)
                guard headAngle == nil else { throw AIError(.invalidArguments, "head_angle is for countersink holes.") }
                hole.headDepth = headDepth
            } else {
                guard headDepth == nil else { throw AIError(.invalidArguments, "head_depth is for counterbore holes; a countersink is set by head_diameter and head_angle.") }
                if let headAngle {
                    _ = try AIValues.evaluate(headAngle, kind: .angle, field: "head_angle", positive: true, values: values)
                    hole.headAngle = headAngle
                }
            }
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Hole")
        doc.addFeature(Feature(id: featureID, name: featureName, .hole(hole)))
        let how = depth.map { "\($0) deep" } ?? "through"
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): a \(kind.rawValue.lowercased()) hole, diameter \(diameter), \(how), at (\(AIValues.number(uValue)), \(AIValues.number(vValue))) on \(face).")
    }
}

// MARK: shell

struct CreateShellOperation: AIOperation {
    let body: String
    let openFaces: [String]
    let thickness: String
    let inside: Bool
    let name: String?
    let id: String?
    var toolName: String { "create_shell" }
    var label: String { "Create \(name?.nonEmpty ?? "Shell")" }
    var activity: String { "Hollowing \(body)" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        _ = try AIChecks.body(body, field: "body", context)
        guard !openFaces.isEmpty else {
            throw AIError(.invalidArguments, "open_faces is empty: a shell needs at least one face to leave open.",
                          reason: "Pick the face that becomes the opening, for example the top face of a box (get_body shows each face's facing).")
        }
        _ = try AIValues.evaluate(thickness, kind: .length, field: "thickness", positive: true, values: context.values)
        var refs: [FaceRef] = []
        for text in openFaces {
            let (ref, _) = try AIChecks.face(text, field: "open_faces", context)
            guard ref.body == body else {
                throw AIError(.invalidArguments, "\"\(text)\" belongs to \(ref.body), not to \(body).", reason: "All open faces must be faces of the body being hollowed.")
            }
            if !refs.contains(ref) { refs.append(ref) }
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Shell")
        doc.addFeature(Feature(id: featureID, name: featureName, .shell(ShellFeature(body: body, faces: refs, thickness: thickness, inside: inside))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): hollowed \(body) with walls of \(thickness) growing \(inside ? "inwards" : "outwards"), \(refs.count) face\(refs.count == 1 ? "" : "s") left open.")
    }
}

// MARK: mirror

struct CreateMirrorOperation: AIOperation {
    let bodies: [String]
    /// Exactly one of `plane` and `line`.
    let plane: String?
    /// "x", "y", "z" or a straight edge id: mirror along it.
    var line: String?
    let operation: BodyOperation
    let name: String?
    let id: String?
    var toolName: String { "create_mirror" }
    var label: String { "Create \(name?.nonEmpty ?? "Mirror")" }
    var activity: String { "Mirroring" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        try AIChecks.bodies(bodies, field: "bodies", context)
        if let line {
            guard plane == nil else { throw AIError(.invalidArguments, "Give plane or line, not both.", reason: "A plane mirrors across it; a line (an axis or a straight edge) mirrors along it.") }
            let lineAxis: PatternAxis
            switch line.lowercased() {
            case "x": lineAxis = .x
            case "y": lineAxis = .y
            case "z": lineAxis = .z
            default:
                guard case .edge(let ref)? = AIEntityRef(line) else {
                    throw AIError(.invalidArguments, "line \"\(line)\" is not \"x\", \"y\", \"z\" or an edge id.", reason: "An edge id looks like \"edge:<body>/<name>\" and must be a straight edge.")
                }
                let body = try AIChecks.body(ref.body, field: "line", context)
                guard body.hasEdge(ref.edge), (try? body.edgeLine(ref.edge)) != nil else {
                    throw AIError(.invalidArguments, "\"\(line)\" is not a straight edge of \(ref.body).", reason: "Take a line-shaped edge from get_body, or use \"x\", \"y\" or \"z\".")
                }
                lineAxis = .edge(ref)
            }
            let featureID = try AIValues.newFeatureID(id, in: doc)
            let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Mirror")
            doc.addFeature(Feature(id: featureID, name: featureName, .mirror(MirrorFeature(bodies: bodies, operation: operation, line: lineAxis))))
            let result = operation == .newBody ? "the copy is a new body with the id \(featureID)" : "the copy is joined to \(bodies.count == 1 ? bodies[0] : "its body")"
            return OperationOutcome(featureID: featureID, message: "Created \(featureName): mirrored \(bodies.joined(separator: ", ")) along \(line); \(result).")
        }
        guard let plane else { throw AIError(.invalidArguments, "Give a plane to mirror across, or a line to mirror along.", reason: "plane is \"xy\", \"xz\", \"yz\", a construction plane or a flat face; line is \"x\", \"y\", \"z\" or a straight edge.") }
        let planeRef = try AIValues.plane(plane, in: doc)
        if case .face(let face) = planeRef {
            guard let body = context.built.body(face.body), (try? body.faceFrame(face.face)) != nil else {
                throw AIError(.invalidArguments, "\"\(plane)\" is not a flat face of a body that exists.", reason: "Mirror across \"xy\", \"xz\", \"yz\", a construction plane or a flat face.")
            }
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Mirror")
        doc.addFeature(Feature(id: featureID, name: featureName, .mirror(MirrorFeature(bodies: bodies, plane: planeRef, operation: operation))))
        let result = operation == .newBody ? "the copy is a new body with the id \(featureID)" : "the copy is joined to \(bodies.count == 1 ? bodies[0] : "its body")"
        return OperationOutcome(featureID: featureID, message: "Created \(featureName): mirrored \(bodies.joined(separator: ", ")) across \(AIEntityRef.text(for: planeRef)); \(result).")
    }
}

// MARK: pattern

struct CreatePatternOperation: AIOperation {
    let circular: Bool
    let bodies: [String]
    /// Features to repeat instead of bodies (a projection, cut, join or hole).
    var features: [String] = []
    /// "x", "y", "z" or an edge id.
    let axis: String
    let count: String
    /// A distance between copies (linear), or the angle they are spread over (circular, default 360).
    let spacing: String?
    let operation: BodyOperation
    let name: String?
    let id: String?
    var toolName: String { "create_pattern" }
    var label: String { "Create \(name?.nonEmpty ?? (circular ? "Circular Pattern" : "Pattern"))" }
    var activity: String { "Repeating" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        if features.isEmpty {
            try AIChecks.bodies(bodies, field: "bodies", context)
        } else {
            guard bodies.isEmpty else {
                throw AIError(.invalidArguments, "Give bodies or features, not both.", reason: "bodies repeats whole bodies; features repeats a projection, cut, join or hole.")
            }
            for id in features {
                guard doc.features.contains(where: { $0.id == id }) else {
                    throw AIError(.featureNotFound, "features: \"\(id)\" is not a feature of the part.", reason: "get_document lists the features.")
                }
                guard context.built.toolRecords[id] != nil else {
                    throw AIError(.invalidArguments, "features: \(id) cannot be repeated.",
                                  reason: "Only features that join, cut or intersect a solid into a body can be repeated (create_project, a cut or join extrude, create_hole). It must also have built without error; to repeat a body, pass bodies.")
                }
            }
        }
        let n = try AIValues.evaluate(count, kind: .none, field: "count", positive: true, values: context.values)
        guard n.rounded() == n, n >= 2, n <= 500 else {
            throw AIError(.invalidValue, "count must be a whole number from 2 to 500 (it includes the original); \"\(count)\" comes to \(AIValues.number(n)).")
        }
        let patternAxis: PatternAxis
        switch axis.lowercased() {
        case "x": patternAxis = .x
        case "y": patternAxis = .y
        case "z": patternAxis = .z
        default:
            switch AIEntityRef(axis) {
            case .face(let ref)?:
                let body = try AIChecks.body(ref.body, field: "axis", context)
                let geometry = body.hasFace(ref.face) ? (try? body.measure(.face(ref.face)))?.geometry : nil
                guard geometry == .cylinder || geometry == .plane else {
                    throw AIError(.invalidArguments, "\"\(axis)\" is not a round (cylindrical) or flat face of \(ref.body).", reason: "Take a cylinder's side face (goes round its axis) or a flat face (goes round the line through its middle, square to it) from get_body, or use \"x\", \"y\" or \"z\".")
                }
                patternAxis = .cylinder(ref)
            case .edge(let ref)?:
                let body = try AIChecks.body(ref.body, field: "axis", context)
                guard body.hasEdge(ref.edge), (try? body.edgeLine(ref.edge)) != nil || (try? body.edgeCircle(ref.edge)) != nil else {
                    throw AIError(.invalidArguments, "\"\(axis)\" is not a straight or circular edge of \(ref.body).", reason: "Take a line-shaped or circular edge from get_body, or use \"x\", \"y\" or \"z\".")
                }
                patternAxis = .edge(ref)
            default:
                throw AIError(.invalidArguments, "axis \"\(axis)\" is not \"x\", \"y\", \"z\", an edge id or a round face id.", reason: "An edge id looks like \"edge:<body>/<name>\" (straight, or circular to go round it); a round face id looks like \"face:<body>/<name>\".")
            }
        }
        let spacingText: String
        if circular {
            spacingText = spacing ?? "360 deg"
            _ = try AIValues.evaluate(spacingText, kind: .angle, field: "spacing", positive: true, values: context.values)
        } else {
            guard let spacing else {
                throw AIError(.invalidArguments, "spacing is required for a linear pattern: the distance between copies.", reason: "A number in mm, for example 20.")
            }
            spacingText = spacing
            _ = try AIValues.evaluate(spacingText, kind: .length, field: "spacing", positive: true, values: context.values)
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Pattern")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .pattern(PatternFeature(kind: circular ? .circular : .linear, bodies: bodies, axis: patternAxis, count: count,
                                                       spacing: spacingText, operation: operation,
                                                       features: features.isEmpty ? nil : features))))
        let shape = circular ? "around the \(axis) axis through the origin over \(spacingText)" : "along \(axis), \(spacingText) apart"
        if !features.isEmpty {
            return OperationOutcome(featureID: featureID,
                                    message: "Created \(featureName): \(Int(n)) copies of \(features.joined(separator: ", ")) (the original included) \(shape); each copy goes in the same way as the original (same cut or join, same bodies).")
        }
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(Int(n)) copies of \(bodies.joined(separator: ", ")) (the original included) \(shape); \(operation == .newBody ? "the copies are a new body with the id \(featureID)" : "joined to their body").")
    }
}

// MARK: combine

struct CreateCombineOperation: AIOperation {
    let target: String
    let tools: [String]
    let operation: BodyOperation
    let keepTools: Bool
    let name: String?
    let id: String?
    var toolName: String { "create_combine" }
    var label: String { "Create \(name?.nonEmpty ?? "Combine")" }
    var activity: String { "Combining bodies" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        _ = try AIChecks.body(target, field: "target", context)
        try AIChecks.bodies(tools, field: "tools", context)
        guard !tools.contains(target) else {
            throw AIError(.invalidArguments, "\(target) is both the target and a tool.", reason: "The tools are the other bodies; the result keeps the target's id.")
        }
        guard operation != .newBody else {
            throw AIError(.invalidArguments, "operation must be join, cut or intersect.")
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Combine")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .combine(CombineFeature(target: target, tools: tools, operation: operation, keepTools: keepTools))))
        let verb = operation == .join ? "joined" : operation == .cut ? "cut from" : "intersected with"
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(tools.joined(separator: ", ")) \(verb) \(target)" + (keepTools ? ", the tool bodies kept." : ", the tool bodies used up."))
    }
}

// MARK: revolve

struct CreateRevolveOperation: AIOperation {
    let sketchID: FeatureID
    let profiles: [ProfileSelector]
    /// "x", "y", "z", "sketch_x", "sketch_y" or a line of the sketch ("curve:<sketch>/<id>").
    let axis: String
    let angle: String
    let operation: BodyOperation
    let target: FeatureID?
    let name: String?
    let id: String?
    var toolName: String { "create_revolve" }
    var label: String { "Create \(name?.nonEmpty ?? "Revolve")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a revolve")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard let sketchFeature = doc.features.first(where: { $0.id == sketchID }), case .sketch = sketchFeature.kind else {
            throw AIError(.featureNotFound, "There is no sketch with the id \(sketchID).", reason: "Create one with create_sketch, or take the id from get_document.")
        }
        guard let built = context.built.sketches[sketchID] else {
            throw AIError(.invalidValue, "\(sketchFeature.name) has no profiles to revolve: it is empty or failed to build.",
                          reason: "Add closed shapes with edit_sketch first, and check the sketch's status with get_feature.")
        }
        guard !profiles.isEmpty else {
            throw AIError(.invalidArguments, "profiles is empty.", reason: "Pick at least one profile: an id from get_feature, or {\"at\": [u, v]} for the profile containing a point.")
        }
        let refs = try CreateExtrudeOperation.resolve(profiles, sketchID: sketchID, in: built, sketchName: sketchFeature.name, values: context.values)
        let degrees = try AIValues.evaluate(angle, kind: .angle, field: "angle", positive: true, values: context.values) * 180 / .pi
        guard degrees <= 360 + 1e-6 else {
            throw AIError(.invalidValue, "angle must be 360 degrees or less (\"\(angle)\" comes to \(AIValues.number(degrees))).")
        }
        let axisRef: AxisRef
        switch axis.lowercased() {
        case "x": axisRef = .x
        case "y": axisRef = .y
        case "z": axisRef = .z
        case "sketch_x": axisRef = .sketchX
        case "sketch_y": axisRef = .sketchY
        default:
            // A curve id as edit_sketch returned it ("axis_line"), or written out as "curve:<sketch>/<id>".
            let reference = axis.contains(":") ? axis : AIEntityRef.curve(sketch: sketchID, id: axis).string
            guard case .curve(let sketch, let curve)? = AIEntityRef(reference), sketch == sketchID else {
                throw AIError(.invalidArguments, "axis \"\(axis)\" is not \"x\", \"y\", \"z\", \"sketch_x\", \"sketch_y\" or a line of this sketch.",
                              reason: "A line of the sketch is written as its id from edit_sketch (for example \"axis_line\"). sketch_x and sketch_y are the sketch's own horizontal and vertical axes through its origin.")
            }
            guard built.solved.lineEnds(curve) != nil else {
                throw AIError(.invalidArguments, "\"\(axis)\" is not a straight line of \(sketchFeature.name).", reason: "get_feature lists the sketch's shapes and their ids.")
            }
            axisRef = .line(curve)
        }
        try AIChecks.requireBody(for: operation, target: target, in: doc)
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Revolve")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .revolve(RevolveFeature(sketch: sketchID, profiles: refs, axis: axisRef, angle: angle, operation: operation, target: target))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): revolved \(refs.count) profile\(refs.count == 1 ? "" : "s") of \(sketchFeature.name) \(angle) about \(axis) (\(AIOperationNames.name(operation))).")
    }
}

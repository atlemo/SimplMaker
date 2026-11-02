// The rest of what the app can make: a rib, a pipe, a split, a body laid on the floor, text or shapes projected onto a surface, a
// reference image, and how a body looks (name, colour, shown or hidden). Each makes the app's own feature, with its own settings.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

// MARK: rib

struct CreateRibOperation: AIOperation {
    /// Curve ids ("curve:<sketch>/<id>") of one sketch: the rib's centre line.
    let path: [String]
    let thickness: String
    let target: FeatureID?
    let name: String?
    let id: String?
    var toolName: String { "create_rib" }
    var label: String { "Create \(name?.nonEmpty ?? "Rib")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a rib")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let (sketch, curves) = try AIChecks.curves(path, field: "path", context)
        try AIChecks.requireBody(for: .join, target: target, in: doc)
        let value = try AIValues.evaluate(thickness, kind: .length, field: "thickness", positive: true, values: context.values)
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Rib")
        doc.addFeature(Feature(id: featureID, name: featureName, .rib(RibFeature(path: CurveRef(sketch: sketch, curves: curves), thickness: thickness, target: target))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): a rib \(AIValues.number(value)) mm thick along \(curves.count) curve\(curves.count == 1 ? "" : "s") of \(sketch), grown until it meets the body.")
    }
}

// MARK: pipe

struct CreatePipeOperation: AIOperation {
    let path: [String]
    let diameter: String
    /// Nil: solid. A wall thickness makes it hollow.
    let wall: String?
    let operation: BodyOperation
    let target: FeatureID?
    let name: String?
    let id: String?
    var toolName: String { "create_pipe" }
    var label: String { "Create \(name?.nonEmpty ?? "Pipe")" }
    var activity: String { "Creating \(name?.nonEmpty ?? "a pipe")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let (sketch, curves) = try AIChecks.curves(path, field: "path", context)
        try AIChecks.requireBody(for: operation, target: target, in: doc)
        let outer = try AIValues.evaluate(diameter, kind: .length, field: "diameter", positive: true, values: context.values)
        if let wall {
            let w = try AIValues.evaluate(wall, kind: .length, field: "wall", positive: true, values: context.values)
            guard w * 2 < outer else {
                throw AIError(.invalidValue, "wall (\(AIValues.number(w)) mm) is too thick for a pipe \(AIValues.number(outer)) mm across: twice the wall has to be less than the diameter.",
                              reason: "Leave wall out for a solid rod.")
            }
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Pipe")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .pipe(PipeFeature(path: CurveRef(sketch: sketch, curves: curves), diameter: diameter, wall: wall, operation: operation, target: target))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): a \(wall == nil ? "solid" : "hollow") pipe \(AIValues.number(outer)) mm across along \(curves.count) curve\(curves.count == 1 ? "" : "s") of \(sketch) (\(AIOperationNames.name(operation))).")
    }
}

// MARK: split

struct CreateSplitOperation: AIOperation {
    enum Tool: Sendable { case plane(String), face(String), sketch(FeatureID), parts }
    let bodies: [String]
    let tool: Tool
    let name: String?
    let id: String?
    var toolName: String { "create_split" }
    var label: String { "Create \(name?.nonEmpty ?? "Split")" }
    var activity: String { "Splitting \(name?.nonEmpty ?? "bodies")" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        try AIChecks.bodies(bodies, field: "bodies", context)
        let splitTool: SplitFeature.Tool
        let what: String
        switch tool {
        case .plane(let text):
            let ref = try AIValues.plane(text, in: doc)
            if case .face(let face) = ref {
                let body = try AIChecks.body(face.body, field: "plane", context)
                guard (try? body.faceFrame(face.face)) != nil else {
                    throw AIError(.invalidArguments, "\"\(text)\" is not a flat face.", reason: "A plane or a flat face cuts all the way through; use face for a curved one.")
                }
            }
            splitTool = .plane(ref); what = "the plane \(text)"
        case .face(let text):
            let (ref, _) = try AIChecks.face(text, field: "face", context)
            splitTool = .face(ref); what = "the face \(text)"
        case .parts:
            splitTool = .parts; what = "its separate parts"
        case .sketch(let sketch):
            guard doc.features.contains(where: { $0.id == sketch && { if case .sketch = $0.kind { return true } else { return false } }($0) }) else {
                throw AIError(.featureNotFound, "There is no sketch with the id \(sketch).", reason: "Take sketch ids from get_document.")
            }
            splitTool = .profile(sketch); what = "the plane of sketch \(sketch)"
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Split")
        doc.addFeature(Feature(id: featureID, name: featureName, .split(SplitFeature(bodies: bodies, tool: splitTool))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): split \(bodies.joined(separator: ", ")) along \(what). The first piece keeps the body's id; the others get ids of their own (read get_document). A flat tool cuts all the way through.")
    }
}

// MARK: lay on floor

struct CreateLayOnFloorOperation: AIOperation {
    let face: String
    let name: String?
    let id: String?
    var toolName: String { "create_lay_on_floor" }
    var label: String { "Create \(name?.nonEmpty ?? "Lay on Floor")" }
    var activity: String { "Laying a body on the floor" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let (ref, body) = try AIChecks.face(face, field: "face", context)
        guard (try? body.faceFrame(ref.face)) != nil else {
            throw AIError(.invalidArguments, "\"\(face)\" is not a flat face.", reason: "Pick a face whose shape is \"plane\" in get_body.")
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("LayOnFloor")
        doc.addFeature(Feature(id: featureID, name: featureName, .layOnFloor(LayOnFloorFeature(face: ref))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(ref.body) turned so that \(face) looks straight down and sits flat on the floor (z = 0). It stays where it is sideways.")
    }
}

// MARK: project

struct CreateProjectOperation: AIOperation {
    let sketchID: FeatureID
    let profiles: [ProfileSelector]
    let target: FeatureID
    let faces: [String]
    let mode: ProjectMode
    let height: String
    let flipped: Bool
    let name: String?
    let id: String?
    var toolName: String { "create_project" }
    var label: String { "Create \(name?.nonEmpty ?? "Project")" }
    var activity: String { "Projecting onto a surface" }

    nonisolated static func modeName(_ mode: ProjectMode) -> String { mode == .emboss ? "emboss" : "deboss" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard let sketchFeature = doc.features.first(where: { $0.id == sketchID }), case .sketch = sketchFeature.kind else {
            throw AIError(.featureNotFound, "There is no sketch with the id \(sketchID).", reason: "Create one with create_sketch, or take the id from get_document.")
        }
        guard let built = context.built.sketches[sketchID] else {
            throw AIError(.invalidValue, "\(sketchFeature.name) has no profiles to project: it is empty or failed to build.", reason: "Add closed shapes or text with edit_sketch first.")
        }
        _ = try AIChecks.body(target, field: "target", context)
        let refs = try CreateExtrudeOperation.resolve(profiles, sketchID: sketchID, in: built, sketchName: sketchFeature.name, values: context.values)
        guard !refs.isEmpty else { throw AIError(.invalidArguments, "profiles is empty.") }
        let value = try AIValues.evaluate(height, kind: .length, field: "height", positive: true, values: context.values)
        var faceRefs: [FaceRef] = []
        for text in faces {
            let (ref, _) = try AIChecks.face(text, field: "faces", context)
            guard ref.body == target else { throw AIError(.invalidArguments, "faces: \"\(text)\" is a face of \(ref.body), not of the target \(target).") }
            if !faceRefs.contains(ref) { faceRefs.append(ref) }
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Project")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .project(ProjectFeature(sketch: sketchID, profiles: refs, target: target, faces: faceRefs, mode: mode, height: height, flipped: flipped))))
        return OperationOutcome(featureID: featureID,
                                message: "Created \(featureName): \(refs.count) profile\(refs.count == 1 ? "" : "s") of \(sketchFeature.name) projected onto \(target) and \(mode == .emboss ? "raised" : "cut in") \(AIValues.number(value)) mm"
                                    + (faceRefs.isEmpty ? " (every face that faces the sketch)." : " (\(faceRefs.count) face\(faceRefs.count == 1 ? "" : "s")).")
                                    + " Projection goes along the sketch's normal\(flipped ? ", turned round" : ""); flip it if nothing lands.")
    }
}

// MARK: how a body looks

struct SetBodyOperation: AIOperation {
    let body: String
    let newName: String?
    /// "#RRGGBB", or "default" to go back to the standard colour.
    let color: String?
    let visible: Bool?
    var toolName: String { "set_body" }
    var label: String { "Change \(body)" }
    var activity: String { "Changing how \(body) looks" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        _ = try AIChecks.body(body, field: "body", context)
        guard newName != nil || color != nil || visible != nil else {
            throw AIError(.invalidArguments, "Nothing to change: send a name, a color and/or visible.", reason: "For example {\"body\": \"lid\", \"color\": \"#E9C53A\"}.")
        }
        var said: [String] = []
        if let newName {
            let trimmed = newName.trimmingCharacters(in: .whitespaces)
            guard trimmed.count <= 80 else { throw AIError(.invalidValue, "name is too long (at most 80 characters).") }
            doc.bodyNames[body] = trimmed.isEmpty ? nil : trimmed
            said.append(trimmed.isEmpty ? "name back to the default" : "named \"\(trimmed)\"")
        }
        if let color {
            if color.lowercased() == "default" {
                doc.bodyColors[body] = nil; said.append("standard color")
            } else if let parsed = BodyColor(hex: color) {
                doc.bodyColors[body] = parsed; said.append("color \(parsed.hex)")
            } else {
                throw AIError(.invalidValue, "color \"\(color)\" is not a color.", reason: "Use #RRGGBB such as \"#E9C53A\", or \"default\" for the standard color.")
            }
        }
        if let visible {
            if visible { doc.hidden.remove(body) } else { doc.hidden.insert(body) }
            said.append(visible ? "shown" : "hidden")
        }
        return OperationOutcome(message: "\(body): \(said.joined(separator: ", ")). This only changes how it is drawn and what it is called; the shape is the same.")
    }
}

// MARK: reference image

struct CreateImageOperation: AIOperation {
    let path: String
    let plane: String
    let u: String
    let v: String
    let width: String
    let angle: String
    let opacity: Double
    let name: String?
    let id: String?
    var toolName: String { "create_image" }
    var label: String { "Insert \((path as NSString).lastPathComponent)" }
    var activity: String { "Placing \((path as NSString).lastPathComponent)" }
    static let maxBytes = 30_000_000
    static let extensions = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard path.hasPrefix("/") else {
            throw AIError(.invalidArguments, "path must be an absolute path (it starts with /).", reason: "For example /Users/me/Pictures/logo.png.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard Self.extensions.contains(url.pathExtension.lowercased()) else {
            throw AIError(.invalidArguments, "Only \(Self.extensions.joined(separator: ", ")) pictures can be placed, not \"\(url.pathExtension)\".")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AIError(.invalidArguments, "There is no file at \(url.path).", reason: "Check the path; the file has to exist on this Mac.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0, size <= Self.maxBytes else {
            throw AIError(.invalidArguments, size == 0 ? "The file is empty." : "The picture is too large (\(size / 1_000_000) MB; at most \(Self.maxBytes / 1_000_000) MB).")
        }
        guard let data = try? Data(contentsOf: url) else {
            throw AIError(.invalidArguments, "The file could not be read.", reason: "SimplMaker may not be allowed to read that folder.")
        }
        guard let image = ReferenceImage.decode(data) else {
            throw AIError(.invalidArguments, "\(url.lastPathComponent) is not a picture SimplMaker can show.", reason: "Use a PNG, JPEG, HEIC or TIFF file.")
        }
        let planeRef = try AIValues.plane(plane, in: doc)
        if case .face(let face) = planeRef {
            guard let body = context.built.body(face.body), (try? body.faceFrame(face.face)) != nil else {
                throw AIError(.invalidArguments, "\"\(plane)\" is not a flat face of a body that exists.")
            }
        }
        for (field, text) in [("u", u), ("v", v)] { _ = try AIValues.evaluate(text, kind: .length, field: field, positive: false, values: context.values) }
        let w = try AIValues.evaluate(width, kind: .length, field: "width", positive: true, values: context.values)
        _ = try AIValues.evaluate(angle, kind: .angle, field: "angle", positive: false, values: context.values)
        guard (0...1).contains(opacity) else { throw AIError(.invalidValue, "opacity must be between 0 (see-through) and 1 (solid).") }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? doc.nextName("Canvas")
        doc.addFeature(Feature(id: featureID, name: featureName,
                               .image(ImageFeature(plane: planeRef, fileName: url.lastPathComponent, data: data, pixelWidth: image.width, pixelHeight: image.height,
                                                   u: u, v: v, width: width, angle: angle, opacity: opacity))))
        let height = w * Double(image.height) / Double(image.width)
        return OperationOutcome(featureID: featureID,
                                message: "Placed \(url.lastPathComponent) (\(image.width) × \(image.height) pixels) on \(plane), \(AIValues.number(w)) × \(AIValues.number(height)) mm, centred at (\(u), \(v)). "
                                    + "It builds nothing: it is there to trace and to measure against, and you cannot see it in get_viewport_image.")
    }
}

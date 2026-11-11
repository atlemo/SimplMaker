// Turns what an AI sends into operations. One parser for the single-change tools and for batch, so a step in a batch
// accepts exactly what its own tool accepts, and refuses exactly what it refuses.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation

extension AIArguments {
    func array(_ key: String) throws -> [JSONValue]? {
        guard let v = json[key], v != .null else { return nil }
        guard let a = v.array else { throw AIError(.invalidArguments, "\(key) must be a list.") }
        return a
    }

    /// A position: [x, y] (numbers in mm, or expressions) or {"x": …, "y": …}.
    static func point(_ v: JSONValue, field: String) throws -> SketchPoint2 {
        let parts: [JSONValue]
        if let a = v.array { parts = a } else if let x = v["x"], let y = v["y"] { parts = [x, y] } else { parts = [] }
        guard parts.count == 2 else {
            throw AIError(.invalidArguments, "\(field) must be a position: [x, y] in mm, for example [10, 5].",
                          reason: "Each coordinate is a number (mm) or an expression such as \"w / 2\".")
        }
        return SketchPoint2(x: try AIValues.expression(parts[0], kind: .length, field: "\(field).x"),
                            y: try AIValues.expression(parts[1], kind: .length, field: "\(field).y"))
    }

    func point(_ key: String) throws -> SketchPoint2? {
        guard let v = json[key], v != .null else { return nil }
        return try Self.point(v, field: key)
    }

    func requiredPoint(_ key: String) throws -> SketchPoint2 {
        guard let p = try point(key) else {
            throw AIError(.invalidArguments, "\(key) is required.", reason: "A position as [x, y] in mm, for example [0, 0].")
        }
        return p
    }

    /// Refuses keys that are not known: a misspelled one (a "diameter_mm") would otherwise be ignored and the shape come out wrong.
    func rejectUnknown(_ allowed: [String], in what: String) throws {
        guard let object = json.object else { return }
        let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw AIError(.invalidArguments, "\(what) has no setting called \(unknown.map { "\"\($0)\"" }.joined(separator: ", ")).",
                          reason: "The settings are: \(allowed.joined(separator: ", ")).")
        }
    }
}

enum AIOperationParser {
    /// The tools that make changes, which a batch can run.
    static let changeTools = ["create_box", "create_sketch", "edit_sketch", "create_extrude", "create_fillet", "create_chamfer", "create_hole", "create_shell", "create_mirror", "create_pattern", "create_combine", "create_revolve", "create_sweep", "create_twist_sweep", "create_loft", "create_sections", "create_thread", "create_draft", "create_plane", "create_move", "create_scale", "create_rib", "create_pipe", "create_split", "create_lay_on_floor", "create_project", "create_image", "set_body", "import_file", "modify_feature", "set_parameter", "delete_feature"]

    /// `names` are the part's feature names by id, for naming steps in Undo.
    static func parse(tool: String, arguments: JSONValue, names: [FeatureID: String] = [:]) throws -> any AIOperation {
        let a = AIArguments(arguments)
        switch tool {
        case "create_box":
            try a.rejectUnknown(["document_id", "width", "length", "height", "plane", "u", "v", "name", "id", "operation", "target", "expected_revision"], in: "create_box")
            let operationText = try a.string("operation") ?? "new_body"
            guard let operation = BodyOperation.allCases.first(where: { AIOperationNames.name($0) == operationText }) else {
                throw AIError(.invalidArguments, "operation \"\(operationText)\" is not one of new_body, join, cut, intersect.")
            }
            return CreateBoxOperation(box: CADService.BoxRequest(
                width: try a.requiredQuantity("width", kind: .length), length: try a.requiredQuantity("length", kind: .length),
                height: try a.requiredQuantity("height", kind: .length), u: try a.quantity("u", kind: .length), v: try a.quantity("v", kind: .length),
                plane: try a.string("plane"), name: try a.string("name"), id: try a.string("id"), operation: operation, target: try a.string("target")))

        case "create_sketch":
            try a.rejectUnknown(["document_id", "plane", "name", "id", "expected_revision"], in: "create_sketch")
            return CreateSketchOperation(plane: try a.string("plane"), name: try a.string("name"), id: try a.string("id"))

        case "edit_sketch":
            try a.rejectUnknown(["document_id", "sketch_id", "add", "expected_revision"], in: "edit_sketch")
            let id = try a.requiredString("sketch_id", hint: "Take it from create_sketch or get_document.")
            guard let list = try a.array("add"), !list.isEmpty else {
                throw AIError(.invalidArguments, "add is required: a list of shapes to draw.", reason: "For example [{\"type\": \"circle\", \"center\": [0, 0], \"diameter\": 5}].")
            }
            return EditSketchOperation(sketchID: id, add: try list.enumerated().map { try shape($1, index: $0) }, sketchName: names[id])

        case "create_extrude":
            try a.rejectUnknown(["document_id", "sketch_id", "profiles", "distance", "direction", "through_all", "operation", "target", "start_face", "name", "id", "expected_revision"], in: "create_extrude")
            let operationText = try a.string("operation") ?? "new_body"
            guard let operation = BodyOperation.allCases.first(where: { AIOperationNames.name($0) == operationText }) else {
                throw AIError(.invalidArguments, "operation \"\(operationText)\" is not one of new_body, join, cut, intersect.")
            }
            let directionText = try a.string("direction") ?? "forward"
            guard let direction = CreateExtrudeOperation.Direction(rawValue: directionText) else {
                throw AIError(.invalidArguments, "direction \"\(directionText)\" is not one of forward, backward, symmetric.")
            }
            let selectors = try profileSelectors(a, arguments)
            let throughAll = try a.bool("through_all") ?? false
            let distance = try a.quantity("distance", kind: .length)
            guard throughAll || distance != nil else {
                throw AIError(.invalidArguments, "distance is required (or through_all: true for a cut).", reason: "A number in mm or an expression such as \"3\" or \"wall\".")
            }
            guard !(throughAll && distance != nil) else {
                throw AIError(.invalidArguments, "Send either distance or through_all, not both.")
            }
            return CreateExtrudeOperation(sketchID: try a.requiredString("sketch_id", hint: "Take it from create_sketch or get_document."),
                                          profiles: selectors, distance: throughAll ? nil : distance, direction: direction, operation: operation,
                                          target: try a.string("target"), startFace: try a.string("start_face"), name: try a.string("name"), id: try a.string("id"))

        case "create_fillet", "create_chamfer":
            let fillet = tool == "create_fillet"
            try a.rejectUnknown(["document_id", "edges", "faces", "size", "name", "id", "expected_revision"]
                                + (fillet ? ["concave"] : ["mode", "second", "flipped"]), in: tool)
            func ids(_ key: String) throws -> [String] {
                try (a.array(key) ?? []).enumerated().map { index, item in
                    guard let text = item.string else { throw AIError(.invalidArguments, "\(key)[\(index)] must be an id text.") }
                    return text
                }
            }
            var mode = ChamferMode.equalDistance
            if let text = try a.string("mode") {
                guard let found = ChamferMode.allCases.first(where: { EdgeFinishOperation.modeName($0) == text }) else {
                    throw AIError(.invalidArguments, "mode \"\(text)\" is not one of equal_distance, distance_angle, two_distances.")
                }
                mode = found
            }
            let secondKind = mode.secondKind
            return EdgeFinishOperation(fillet: fillet, edges: try ids("edges"), faces: try ids("faces"),
                                       size: try a.requiredQuantity("size", kind: .length, hint: fillet ? "The radius in mm, for example 2." : "The distance in mm, for example 1."),
                                       mode: mode, second: try a.quantity("second", kind: secondKind ?? .length),
                                       flipped: try a.bool("flipped") ?? false, concave: try a.bool("concave") ?? false,
                                       name: try a.string("name"), id: try a.string("id"))

        case "create_hole":
            try a.rejectUnknown(["document_id", "face", "at", "u", "v", "kind", "diameter", "depth", "through_all", "tip_angle", "head_diameter", "head_depth",
                                 "head_angle", "name", "id", "expected_revision"], in: tool)
            let kindText = try a.string("kind") ?? "simple"
            guard let kind = HoleKind.allCases.first(where: { $0.rawValue.lowercased() == kindText }) else {
                throw AIError(.invalidArguments, "kind \"\(kindText)\" is not one of simple, counterbore, countersink.")
            }
            let throughAll = try a.bool("through_all") ?? false
            let depth = try a.quantity("depth", kind: .length)
            guard throughAll != (depth != nil) else {
                throw AIError(.invalidArguments, throughAll ? "Send either depth or through_all, not both." : "depth is required (or through_all: true).",
                              reason: "depth is how far the full diameter goes, in mm; through_all drills through the whole body.")
            }
            var at: [Double]?
            if let list = try a.array("at") {
                let numbers = list.compactMap(\.number)
                guard list.count == 3, numbers.count == 3 else {
                    throw AIError(.invalidArguments, "at must be three numbers [x, y, z] in mm.", reason: "A point in the part's coordinates; it is projected onto the face. Or send u and v in the face's own frame.")
                }
                at = numbers
            }
            return CreateHoleOperation(face: try a.requiredString("face", hint: "A flat face id from get_body, such as \"face:base/base.end\"."),
                                       at: at, u: try a.quantity("u", kind: .length), v: try a.quantity("v", kind: .length), kind: kind,
                                       diameter: try a.requiredQuantity("diameter", kind: .length), depth: throughAll ? nil : depth,
                                       tipAngle: try a.quantity("tip_angle", kind: .angle), headDiameter: try a.quantity("head_diameter", kind: .length),
                                       headDepth: try a.quantity("head_depth", kind: .length), headAngle: try a.quantity("head_angle", kind: .angle),
                                       name: try a.string("name"), id: try a.string("id"))

        case "create_shell":
            try a.rejectUnknown(["document_id", "body", "open_faces", "thickness", "inside", "name", "id", "expected_revision"], in: tool)
            return CreateShellOperation(body: try a.requiredString("body", hint: "The id of the body to hollow, from get_document."),
                                        openFaces: try ids(a, "open_faces"), thickness: try a.requiredQuantity("thickness", kind: .length),
                                        inside: try a.bool("inside") ?? true, name: try a.string("name"), id: try a.string("id"))

        case "create_mirror":
            try a.rejectUnknown(["document_id", "bodies", "plane", "line", "operation", "name", "id", "expected_revision"], in: tool)
            let mirrorPlane = try a.string("plane"), mirrorLine = try a.string("line")
            if mirrorPlane == nil, mirrorLine == nil {
                throw AIError(.invalidArguments, "Give plane (to mirror across) or line (to mirror along).", reason: "plane: \"xy\", \"xz\", \"yz\", \"plane:<id>\" or a flat face id. line: \"x\", \"y\", \"z\" or a straight edge id.")
            }
            return CreateMirrorOperation(bodies: try ids(a, "bodies"), plane: mirrorPlane, line: mirrorLine,
                                         operation: try bodyOperation(a, allowed: [.join, .newBody], default: .join), name: try a.string("name"), id: try a.string("id"))

        case "create_pattern":
            try a.rejectUnknown(["document_id", "kind", "bodies", "features", "axis", "count", "spacing", "operation", "name", "id", "expected_revision"], in: tool)
            let kindText = try a.string("kind") ?? "linear"
            guard kindText == "linear" || kindText == "circular" else { throw AIError(.invalidArguments, "kind \"\(kindText)\" is not linear or circular.") }
            let patternFeatures = try ids(a, "features")
            if patternFeatures.isEmpty, try ids(a, "bodies").isEmpty {
                throw AIError(.invalidArguments, "Give bodies (to repeat bodies) or features (to repeat a projection, cut, join or hole).")
            }
            return CreatePatternOperation(circular: kindText == "circular", bodies: try ids(a, "bodies"), features: patternFeatures,
                                          axis: try a.requiredString("axis", hint: "\"x\", \"y\", \"z\" or a straight edge id."),
                                          count: try a.requiredQuantity("count", kind: .none, hint: "How many bodies in all, the original included, for example 4."),
                                          spacing: try a.quantity("spacing", kind: kindText == "circular" ? .angle : .length),
                                          operation: try bodyOperation(a, allowed: [.join, .newBody], default: .join), name: try a.string("name"), id: try a.string("id"))

        case "create_combine":
            try a.rejectUnknown(["document_id", "target", "tools", "operation", "keep_tools", "name", "id", "expected_revision"], in: tool)
            return CreateCombineOperation(target: try a.requiredString("target", hint: "The body that keeps its id, from get_document."), tools: try ids(a, "tools"),
                                          operation: try bodyOperation(a, allowed: [.join, .cut, .intersect], default: .join), keepTools: try a.bool("keep_tools") ?? false,
                                          name: try a.string("name"), id: try a.string("id"))

        case "create_revolve":
            try a.rejectUnknown(["document_id", "sketch_id", "profiles", "axis", "angle", "operation", "target", "name", "id", "expected_revision"], in: tool)
            return CreateRevolveOperation(sketchID: try a.requiredString("sketch_id", hint: "Take it from create_sketch or get_document."),
                                          profiles: try profileSelectors(a, arguments),
                                          axis: try a.requiredString("axis", hint: "\"x\", \"y\", \"z\", \"sketch_x\", \"sketch_y\" or a line of the sketch as \"curve:<sketch>/<id>\"."),
                                          angle: try a.quantity("angle", kind: .angle) ?? "360 deg", operation: try bodyOperation(a, allowed: BodyOperation.allCases, default: .newBody),
                                          target: try a.string("target"), name: try a.string("name"), id: try a.string("id"))

        case "create_sweep":
            try a.rejectUnknown(["document_id", "sketch_id", "profiles", "path_sketch", "path", "operation", "target", "name", "id", "expected_revision"], in: tool)
            let pathSketch = try a.string("path_sketch")
            let path = try ids(a, "path").map { $0.contains(":") || pathSketch == nil ? $0 : AIEntityRef.curve(sketch: pathSketch!, id: $0).string }
            return CreateSweepOperation(sketchID: try a.requiredString("sketch_id", hint: "The sketch holding the profile to sweep."),
                                        profiles: try profileSelectors(a, arguments), path: path,
                                        operation: try bodyOperation(a, allowed: BodyOperation.allCases, default: .newBody), target: try a.string("target"),
                                        name: try a.string("name"), id: try a.string("id"))

        case "create_twist_sweep":
            try a.rejectUnknown(["document_id", "sketch_id", "profiles", "distance", "end_angle", "start_angle", "curve", "shift", "pivot", "flipped", "operation", "target", "name", "id", "expected_revision"], in: tool)
            return CreateTwistSweepOperation(
                sketchID: try a.requiredString("sketch_id", hint: "The sketch holding the profile to sweep, drawn on the plane the sweep starts from."),
                profiles: try profileSelectors(a, arguments),
                distance: try a.requiredQuantity("distance", kind: .length, hint: "How far the sweep runs along the sketch's normal, in mm."),
                startAngle: try a.quantity("start_angle", kind: .angle) ?? "0 deg",
                endAngle: try a.requiredQuantity("end_angle", kind: .angle, hint: "The turn at the far end, in degrees (counter-clockwise seen from the sketch's front); the twist is end_angle minus start_angle."),
                curve: try a.quantity("curve", kind: .none) ?? "1", shift: try a.point("shift"), pivot: try a.point("pivot"),
                flipped: try a.bool("flipped") ?? false, operation: try bodyOperation(a, allowed: BodyOperation.allCases, default: .newBody),
                target: try a.string("target"), name: try a.string("name"), id: try a.string("id"))

        case "create_sections":
            try a.rejectUnknown(["document_id", "body", "axis", "offsets", "from", "to", "count", "tolerance", "id", "expected_revision"], in: tool)
            return CreateSectionsOperation(
                body: try a.requiredString("body", hint: "The body to cut, from get_document: an imported mesh, say."),
                axis: try a.requiredString("axis", hint: "\"x\", \"y\" or \"z\": the planes are square to it."), offsets: try a.sliceOffsets(),
                tolerance: arguments["tolerance"]?.number ?? 0.05, id: try a.string("id") ?? "sec")

        case "create_loft":
            try a.rejectUnknown(["document_id", "sections", "stations", "axis", "path_sketch", "path", "ruled", "operation", "target", "name", "id", "expected_revision"], in: tool)
            let loftPathSketch = try a.string("path_sketch")
            let loftPath = arguments["path"] == nil ? [] : try ids(a, "path").map {
                $0.contains(":") || loftPathSketch == nil ? $0 : AIEntityRef.curve(sketch: loftPathSketch!, id: $0).string
            }
            if let list = try a.array("stations") {
                guard try a.array("sections") == nil else { throw AIError(.invalidArguments, "Send either sections (sketches you made) or stations (outlines given here), not both.") }
                let stations: [SectionStation] = try list.enumerated().map { index, item in
                    let s = AIArguments(item)
                    try s.rejectUnknown(["offset", "points", "loops"], in: "stations[\(index)]")
                    var loops: [[SketchPoint2]] = []
                    func outline(_ v: JSONValue, _ field: String) throws -> [SketchPoint2] {
                        guard let points = v.array else { throw AIError(.invalidArguments, "\(field) must be a list of [u, v] points.") }
                        return try points.enumerated().map { try AIArguments.point($1, field: "\(field)[\($0)]") }
                    }
                    if let points = item["points"] { loops = [try outline(points, "stations[\(index)].points")] }
                    if let more = try s.array("loops") {
                        guard loops.isEmpty else { throw AIError(.invalidArguments, "stations[\(index)] has both points and loops: send one outline as points, or several (outer first, then holes) as loops.") }
                        loops = try more.enumerated().map { try outline($1, "stations[\(index)].loops[\($0)]") }
                    }
                    guard !loops.isEmpty else {
                        throw AIError(.invalidArguments, "stations[\(index)] needs points (one closed outline, [[u, v], …]) or loops (outer outline first, then holes).")
                    }
                    return SectionStation(offset: try s.requiredQuantity("offset", kind: .length, hint: "Where the station is along the axis, mm."), loops: loops)
                }
                return CreateLoftOperation(sections: [], stations: stations, axis: try a.requiredString("axis", hint: "\"x\", \"y\" or \"z\": the stations lie in planes square to it, in the sketch coordinates of the \"yz\", \"xz\" or \"xy\" plane."),
                                           path: loftPath, ruled: try a.bool("ruled") ?? false, operation: try bodyOperation(a, allowed: BodyOperation.allCases, default: .newBody),
                                           target: try a.string("target"), name: try a.string("name"), id: try a.string("id"))
            }
            let sections: [LoftSectionRequest] = try (a.array("sections") ?? []).enumerated().map { index, item in
                let sectionArgs = AIArguments(item)
                try sectionArgs.rejectUnknown(["sketch_id", "profile"], in: "sections[\(index)]")
                let selector: ProfileSelector
                if let text = item["profile"]?.string { selector = text == "solid" ? .solid : .id(text) } else if let at = item["profile"]?["at"] {
                    selector = .at(try AIArguments.point(at, field: "sections[\(index)].profile.at"))
                } else {
                    throw AIError(.invalidArguments, "sections[\(index)] needs a \"profile\": a profile id, \"solid\", or {\"at\": [u, v]}.")
                }
                return LoftSectionRequest(sketchID: try sectionArgs.requiredString("sketch_id"), profile: selector)
            }
            return CreateLoftOperation(sections: sections, path: loftPath, ruled: try a.bool("ruled") ?? false,
                                       operation: try bodyOperation(a, allowed: BodyOperation.allCases, default: .newBody), target: try a.string("target"),
                                       name: try a.string("name"), id: try a.string("id"))

        case "create_thread":
            try a.rejectUnknown(["document_id", "faces", "standard", "size", "length", "flipped", "left_handed", "tolerance", "tolerance_unit", "name", "id", "expected_revision"], in: tool)
            let standards: [String: ThreadStandard] = ["metric": .metric, "metric_fine": .metricFine, "unc": .unc, "unf": .unf]
            let standardText = try a.string("standard") ?? "metric"
            guard let standard = standards[standardText] else {
                throw AIError(.invalidArguments, "standard \"\(standardText)\" is not one of metric, metric_fine, unc, unf.")
            }
            let unitText = try a.string("tolerance_unit") ?? "percent"
            guard unitText == "percent" || unitText == "mm" else { throw AIError(.invalidArguments, "tolerance_unit must be \"percent\" or \"mm\".") }
            return CreateThreadOperation(faces: try ids(a, "faces"), standard: standard,
                                         size: try a.requiredString("size", hint: "A size from the standard, such as \"M6x1\" (metric) or \"1/4-20\" (unc)."),
                                         length: try a.quantity("length", kind: .length), flipped: try a.bool("flipped") ?? false,
                                         leftHanded: try a.bool("left_handed") ?? false,
                                         tolerance: try a.quantity("tolerance", kind: unitText == "percent" ? .none : .length),
                                         toleranceUnit: unitText == "percent" ? .percent : .distance, name: try a.string("name"), id: try a.string("id"))

        case "create_draft":
            try a.rejectUnknown(["document_id", "body", "faces", "fixed_face", "angle", "name", "id", "expected_revision"], in: tool)
            return CreateDraftOperation(body: try a.requiredString("body", hint: "The body whose faces lean."), faces: try ids(a, "faces"),
                                        fixedFace: try a.requiredString("fixed_face", hint: "The flat face that stays put, from get_body."),
                                        angle: try a.requiredQuantity("angle", kind: .angle, hint: "Degrees, usually 1 to 5."),
                                        name: try a.string("name"), id: try a.string("id"))

        case "create_plane":
            try a.rejectUnknown(["document_id", "base", "offset", "angle", "axis", "name", "id", "expected_revision"], in: tool)
            let axisText = try a.string("axis") ?? "horizontal"
            guard axisText == "horizontal" || axisText == "vertical" else { throw AIError(.invalidArguments, "axis must be \"horizontal\" or \"vertical\".") }
            return CreatePlaneOperation(base: try a.string("base") ?? "xy", offset: try a.quantity("offset", kind: .length) ?? "0 mm",
                                        angle: try a.quantity("angle", kind: .angle) ?? "0 deg", vertical: axisText == "vertical",
                                        name: try a.string("name"), id: try a.string("id"))

        case "create_move":
            try a.rejectUnknown(["document_id", "bodies", "sketches", "dx", "dy", "dz", "rx", "ry", "rz", "px", "py", "pz", "name", "id", "expected_revision"], in: tool)
            let pivot = [try a.quantity("px", kind: .length), try a.quantity("py", kind: .length), try a.quantity("pz", kind: .length)]
            guard pivot.allSatisfy({ $0 != nil }) || pivot.allSatisfy({ $0 == nil }) else {
                throw AIError(.invalidArguments, "px, py and pz go together: a pivot point needs all three.", reason: "Send all three, or none to turn about the middle.")
            }
            return CreateMoveOperation(pivot: pivot.contains { $0 != nil } ? pivot.compactMap { $0 } : nil, bodies: try ids(a, "bodies"), sketches: try ids(a, "sketches"),
                                       dx: try a.quantity("dx", kind: .length) ?? "0 mm", dy: try a.quantity("dy", kind: .length) ?? "0 mm", dz: try a.quantity("dz", kind: .length) ?? "0 mm",
                                       rx: try a.quantity("rx", kind: .angle) ?? "0 deg", ry: try a.quantity("ry", kind: .angle) ?? "0 deg", rz: try a.quantity("rz", kind: .angle) ?? "0 deg",
                                       name: try a.string("name"), id: try a.string("id"))

        case "create_scale":
            try a.rejectUnknown(["document_id", "bodies", "sketches", "factor", "name", "id", "expected_revision"], in: tool)
            return CreateScaleOperation(bodies: try ids(a, "bodies"), sketches: try ids(a, "sketches"),
                                        factor: try a.requiredQuantity("factor", kind: .none, hint: "A number such as 2 (twice as big) or 0.5."),
                                        name: try a.string("name"), id: try a.string("id"))

        case "create_rib", "create_pipe":
            let rib = tool == "create_rib"
            try a.rejectUnknown(["document_id", "path_sketch", "path", "target", "name", "id", "expected_revision"]
                                + (rib ? ["thickness"] : ["diameter", "wall", "operation"]), in: tool)
            let pathSketch = try a.string("path_sketch")
            let path = try ids(a, "path").map { $0.contains(":") || pathSketch == nil ? $0 : AIEntityRef.curve(sketch: pathSketch!, id: $0).string }
            if rib {
                return CreateRibOperation(path: path, thickness: try a.quantity("thickness", kind: .length) ?? "2 mm", target: try a.string("target"),
                                          name: try a.string("name"), id: try a.string("id"))
            }
            return CreatePipeOperation(path: path, diameter: try a.requiredQuantity("diameter", kind: .length, hint: "The outside diameter in mm."),
                                       wall: try a.quantity("wall", kind: .length),
                                       operation: try bodyOperation(a, allowed: BodyOperation.allCases, default: .newBody), target: try a.string("target"),
                                       name: try a.string("name"), id: try a.string("id"))

        case "create_split":
            try a.rejectUnknown(["document_id", "bodies", "plane", "face", "sketch_id", "parts", "name", "id", "expected_revision"], in: tool)
            let plane = try a.string("plane"), face = try a.string("face"), sketch = try a.string("sketch_id")
            let parts = try a.bool("parts") ?? false
            let tools: [CreateSplitOperation.Tool] = [plane.map { .plane($0) }, face.map { .face($0) }, sketch.map { .sketch($0) }, parts ? .parts : nil].compactMap { $0 }
            guard tools.count == 1, let splitTool = tools.first else {
                throw AIError(.invalidArguments, "Send exactly one of plane, face, sketch_id or parts: what divides the bodies.",
                              reason: "plane: \"xy\", \"xz\", \"yz\" or \"plane:<id>\" (create_plane makes one at any height); face: a face id (its plane if flat); sketch_id: cut along the plane that sketch lies on; parts: true separates a body that is really several loose pieces into one body each, no cut.")
            }
            return CreateSplitOperation(bodies: try ids(a, "bodies"), tool: splitTool, name: try a.string("name"), id: try a.string("id"))

        case "create_lay_on_floor":
            try a.rejectUnknown(["document_id", "face", "name", "id", "expected_revision"], in: tool)
            return CreateLayOnFloorOperation(face: try a.requiredString("face", hint: "A flat face id from get_body: the one that should sit on the floor."),
                                             name: try a.string("name"), id: try a.string("id"))

        case "create_project":
            try a.rejectUnknown(["document_id", "sketch_id", "profiles", "target", "faces", "mode", "height", "flipped", "name", "id", "expected_revision"], in: tool)
            let modeText = try a.string("mode") ?? "emboss"
            guard let mode = ProjectMode.allCases.first(where: { CreateProjectOperation.modeName($0) == modeText }) else {
                throw AIError(.invalidArguments, "mode \"\(modeText)\" is not one of emboss, deboss.")
            }
            return CreateProjectOperation(sketchID: try a.requiredString("sketch_id", hint: "The sketch with the text or shapes to project."),
                                          profiles: try profileSelectors(a, arguments),
                                          target: try a.requiredString("target", hint: "The body to project onto, from get_document."), faces: try ids(a, "faces"),
                                          mode: mode, height: try a.quantity("height", kind: .length) ?? "1 mm", flipped: try a.bool("flipped") ?? false,
                                          name: try a.string("name"), id: try a.string("id"))

        case "set_body":
            try a.rejectUnknown(["document_id", "body", "name", "color", "visible", "expected_revision"], in: tool)
            return SetBodyOperation(body: try a.requiredString("body", hint: "A body id from get_document."), newName: try a.string("name"),
                                    color: try a.string("color"), visible: try a.bool("visible"))

        case "create_image":
            try a.rejectUnknown(["document_id", "path", "plane", "u", "v", "width", "angle", "opacity", "name", "id", "expected_revision"], in: tool)
            var opacity = 0.5
            if let value = a.json["opacity"], value != .null {
                guard let number = value.number else { throw AIError(.invalidArguments, "opacity must be a number from 0 to 1.") }
                opacity = number
            }
            return CreateImageOperation(path: try a.requiredString("path", hint: "The absolute path of a PNG, JPEG, HEIC or TIFF picture."), plane: try a.string("plane") ?? "xy",
                                        u: try a.quantity("u", kind: .length) ?? "0 mm", v: try a.quantity("v", kind: .length) ?? "0 mm",
                                        width: try a.quantity("width", kind: .length) ?? "100 mm", angle: try a.quantity("angle", kind: .angle) ?? "0 deg",
                                        opacity: opacity, name: try a.string("name"), id: try a.string("id"))

        case "import_file":
            try a.rejectUnknown(["document_id", "path", "name", "id", "expected_revision"], in: tool)
            return ImportFileOperation(path: try a.requiredString("path", hint: "The absolute path of a .step, .stp or .stl file."), name: try a.string("name"), id: try a.string("id"))

        case "modify_feature":
            try a.rejectUnknown(["document_id", "feature_id", "parameters", "unlink", "expected_revision"], in: "modify_feature")
            guard let settings = try a.object("parameters") else {
                throw AIError(.invalidArguments, "parameters is required.", reason: "For example {\"width\": 120}.")
            }
            let id = try a.requiredString("feature_id", hint: "Take it from get_document.")
            return ModifyFeatureOperation(featureID: id, settings: settings, unlink: try a.bool("unlink") ?? false, featureName: names[id])

        case "delete_feature":
            try a.rejectUnknown(["document_id", "feature_id", "with_children", "expected_revision"], in: "delete_feature")
            let id = try a.requiredString("feature_id", hint: "Take it from get_document.")
            return DeleteFeatureOperation(featureID: id, withChildren: try a.bool("with_children") ?? false, featureName: names[id])

        case "set_parameter":
            try a.rejectUnknown(["document_id", "name", "value", "unit", "comment", "expected_revision"], in: "set_parameter")
            guard let value = arguments["value"], value != .null else { throw AIError(.invalidArguments, "value is required.") }
            let unit: UnitKind? = try (try a.string("unit")).map { text in
                switch text {
                case "mm": return .length
                case "deg": return .angle
                case "none", "": return .none
                default: throw AIError(.invalidArguments, "unit \"\(text)\" is not mm, deg or none.")
                }
            }
            return SetParameterOperation(name: try a.requiredString("name"), value: value, unit: unit, comment: try a.string("comment"))

        default:
            throw AIError(.invalidArguments, "\"\(tool)\" is not a tool a batch can run.", reason: "A batch can run: \(changeTools.joined(separator: ", ")).")
        }
    }

    /// The "profiles" argument: "solid", or a list of profile ids and {"at": [u, v]} points.
    static func profileSelectors(_ a: AIArguments, _ arguments: JSONValue) throws -> [ProfileSelector] {
        let items: [JSONValue]
        if arguments["profiles"]?.string == "solid" { items = ["solid"] } else if let list = try a.array("profiles"), !list.isEmpty { items = list } else {
            throw AIError(.invalidArguments, "profiles is required: the profiles of the sketch to use.",
                          reason: "\"solid\" for every profile that is not the filling of a hole, or a list of ids from get_feature (\"profile:<sketch>/<curves>\") and {\"at\": [x, y]} points.")
        }
        return try items.enumerated().map { index, item in
            if item.string == "solid" { return .solid }
            if let text = item.string { return .id(text) }
            if let at = item["at"] { return .at(try AIArguments.point(at, field: "profiles[\(index)].at")) }
            throw AIError(.invalidArguments, "profiles[\(index)] must be a profile id or {\"at\": [u, v]}.")
        }
    }

    static func bodyOperation(_ a: AIArguments, allowed: [BodyOperation], default def: BodyOperation) throws -> BodyOperation {
        let text = try a.string("operation") ?? AIOperationNames.name(def)
        guard let found = allowed.first(where: { AIOperationNames.name($0) == text }) else {
            throw AIError(.invalidArguments, "operation \"\(text)\" is not one of \(allowed.map { AIOperationNames.name($0) }.joined(separator: ", ")).")
        }
        return found
    }

    static func ids(_ a: AIArguments, _ key: String) throws -> [String] {
        try (a.array(key) ?? []).enumerated().map { index, item in
            guard let text = item.string else { throw AIError(.invalidArguments, "\(key)[\(index)] must be an id text.") }
            return text
        }
    }

    // MARK: shapes

    static func shape(_ v: JSONValue, index: Int) throws -> SketchShape {
        let a = AIArguments(v)
        guard v.object != nil, let type = try a.string("type") else {
            throw AIError(.invalidArguments, "add[\(index)] must be an object with a \"type\".",
                          reason: "Types: rectangle, circle, polygon, line, polyline, spline, arc, text.")
        }
        let id = try a.string("id")
        let context = "add[\(index)] (\(type))"
        let origin = SketchPoint2(x: "0 mm", y: "0 mm")
        switch type {
        case "rectangle":
            try a.rejectUnknown(["type", "id", "center", "corner", "width", "height", "corner_radius"], in: context)
            if try a.point("center") != nil, try a.point("corner") != nil {
                throw AIError(.invalidArguments, "\(context): send center or corner, not both.", reason: "center puts the middle of the rectangle there; corner puts its lower left corner there.")
            }
            return .rectangle(id: id, center: try a.point("center"), corner: try a.point("corner"), width: try a.requiredQuantity("width", kind: .length),
                              height: try a.requiredQuantity("height", kind: .length), cornerRadius: try a.quantity("corner_radius", kind: .length))
        case "circle":
            try a.rejectUnknown(["type", "id", "center", "diameter", "radius"], in: context)
            return .circle(id: id, center: try a.point("center") ?? origin, diameter: try a.quantity("diameter", kind: .length), radius: try a.quantity("radius", kind: .length))
        case "polygon":
            try a.rejectUnknown(["type", "id", "center", "radius", "sides", "rotation"], in: context)
            guard let sides = try a.integer("sides") else { throw AIError(.invalidArguments, "\(context): sides is required.") }
            return .polygon(id: id, center: try a.point("center") ?? origin, radius: try a.requiredQuantity("radius", kind: .length), sides: sides,
                            rotation: try a.quantity("rotation", kind: .angle))
        case "line":
            try a.rejectUnknown(["type", "id", "from", "to"], in: context)
            return .line(id: id, from: try a.requiredPoint("from"), to: try a.requiredPoint("to"))
        case "polyline":
            try a.rejectUnknown(["type", "id", "points", "closed"], in: context)
            guard let points = try a.array("points") else { throw AIError(.invalidArguments, "\(context): points is required: a list of [x, y] positions.") }
            return .polyline(id: id, points: try points.enumerated().map { try AIArguments.point($1, field: "points[\($0)]") }, closed: try a.bool("closed") ?? false)
        case "spline":
            try a.rejectUnknown(["type", "id", "points", "closed"], in: context)
            guard let points = try a.array("points") else { throw AIError(.invalidArguments, "\(context): points is required: a list of [x, y] positions the curve passes through.") }
            return .spline(id: id, points: try points.enumerated().map { try AIArguments.point($1, field: "points[\($0)]") }, closed: try a.bool("closed") ?? false)
        case "arc":
            try a.rejectUnknown(["type", "id", "from", "through", "to"], in: context)
            return .arc(id: id, from: try a.requiredPoint("from"), through: try a.requiredPoint("through"), to: try a.requiredPoint("to"))
        case "text":
            try a.rejectUnknown(["type", "id", "text", "at", "height", "font", "angle", "anchor"], in: context)
            let anchor = try a.string("anchor") ?? "start"
            guard anchor == "start" || anchor == "center" else {
                throw AIError(.invalidArguments, "\(context): anchor must be \"start\" or \"center\".", reason: "start puts the beginning of the baseline at the position; center puts the middle of the letters there.")
            }
            return .text(id: id, text: try a.requiredString("text"), at: try a.point("at") ?? origin, height: try a.quantity("height", kind: .length) ?? "5 mm",
                         font: try a.string("font"), angle: try a.quantity("angle", kind: .angle), centered: anchor == "center")
        default:
            throw AIError(.invalidArguments, "\(context): \"\(type)\" is not a shape type.", reason: "Types: rectangle, circle, polygon, line, polyline, spline, arc, text.")
        }
    }
}

extension CADService {
    /// The names of the part's features by id, for labelling steps.
    func featureNames(documentID: String) -> [FeatureID: String] {
        guard let model = try? resolve(documentID).model else { return [:] }
        return Dictionary(model.document.features.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
}

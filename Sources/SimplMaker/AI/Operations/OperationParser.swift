// Turns what an AI sends into operations. One parser for the single-change tools and for batch, so a step in a batch
// accepts exactly what its own tool accepts, and refuses exactly what it refuses.
// Copyright © 2026 Atle Mo. All rights reserved.
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
    static let changeTools = ["create_box", "create_sketch", "edit_sketch", "create_extrude", "modify_feature", "set_parameter", "delete_feature"]

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
            let items: [JSONValue]
            if arguments["profiles"]?.string == "solid" { items = ["solid"] } else if let list = try a.array("profiles"), !list.isEmpty { items = list } else {
                throw AIError(.invalidArguments, "profiles is required: the profiles of the sketch to extrude.",
                              reason: "\"solid\" for every profile that is not the filling of a hole, or a list of ids from get_feature (\"profile:<sketch>/<curves>\") and {\"at\": [x, y]} points.")
            }
            let selectors: [ProfileSelector] = try items.enumerated().map { index, item in
                if item.string == "solid" { return .solid }
                if let text = item.string { return .id(text) }
                if let at = item["at"] { return .at(try AIArguments.point(at, field: "profiles[\(index)].at")) }
                throw AIError(.invalidArguments, "profiles[\(index)] must be a profile id or {\"at\": [u, v]}.")
            }
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

    // MARK: shapes

    static func shape(_ v: JSONValue, index: Int) throws -> SketchShape {
        let a = AIArguments(v)
        guard v.object != nil, let type = try a.string("type") else {
            throw AIError(.invalidArguments, "add[\(index)] must be an object with a \"type\".",
                          reason: "Types: rectangle, circle, polygon, line, polyline, arc, text.")
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
            throw AIError(.invalidArguments, "\(context): \"\(type)\" is not a shape type.", reason: "Types: rectangle, circle, polygon, line, polyline, arc, text.")
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

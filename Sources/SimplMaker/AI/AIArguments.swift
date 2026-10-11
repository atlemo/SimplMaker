// Reading a tool's arguments, and turning what an AI writes into what the document stores. An AI sends a size as a number
// (millimetres, or degrees for an angle) or as an expression ("2 in", "wall * 2"); the document stores expressions, so a
// number becomes "120 mm". Every mistake comes back as an AIError that says what to send instead.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

struct AIArguments {
    let json: JSONValue

    init(_ json: JSONValue) { self.json = json }

    private func value(_ key: String) -> JSONValue? {
        guard let v = json[key], v != .null else { return nil }
        return v
    }

    func string(_ key: String) throws -> String? {
        guard let v = value(key) else { return nil }
        guard let s = v.string else { throw AIError(.invalidArguments, "\(key) must be a string.") }
        return s
    }

    func requiredString(_ key: String, hint: String? = nil) throws -> String {
        guard let s = try string(key), !s.isEmpty else {
            throw AIError(.invalidArguments, "\(key) is required.", reason: hint)
        }
        return s
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = value(key) else { return nil }
        guard let b = v.bool else { throw AIError(.invalidArguments, "\(key) must be true or false.") }
        return b
    }

    func integer(_ key: String) throws -> Int? {
        guard let v = value(key) else { return nil }
        if case .int(let i) = v { return i }
        if case .double(let d) = v, d == d.rounded() { return Int(d) }
        throw AIError(.invalidArguments, "\(key) must be a whole number.")
    }

    func object(_ key: String) throws -> [String: JSONValue]? {
        guard let v = value(key) else { return nil }
        guard let o = v.object else { throw AIError(.invalidArguments, "\(key) must be a JSON object.") }
        return o
    }

    /// A size or angle: a number, or an expression text. Nil when it isn't there.
    func quantity(_ key: String, kind: UnitKind) throws -> String? {
        guard let v = value(key) else { return nil }
        return try AIValues.expression(v, kind: kind, field: key)
    }

    func requiredQuantity(_ key: String, kind: UnitKind, hint: String? = nil) throws -> String {
        guard let q = try quantity(key, kind: kind) else {
            throw AIError(.invalidArguments, "\(key) is required.", reason: hint ?? "Send a number (millimetres) or an expression such as \"2 in\".")
        }
        return q
    }

    /// The document the call is about. Changes never go to "the front window": the caller has to say which.
    func requiredDocumentID() throws -> String {
        guard let id = try string("document_id"), !id.isEmpty else {
            throw AIError(.invalidArguments, "document_id is required for changes.",
                          reason: "Changes are never made to \"the front window\" by guesswork. Call list_documents and pass the id of the part to change.")
        }
        return id
    }

    func expectedRevision() throws -> Int? { try integer("expected_revision") }
}

enum AIValues {
    /// A number (mm, degrees, or plain) or an expression, as the text the document stores.
    static func expression(_ value: JSONValue, kind: UnitKind, field: String) throws -> String {
        switch value {
        case .int, .double:
            let n = value.number ?? 0
            guard n.isFinite else { throw AIError(.invalidValue, "\(field) must be a finite number.") }
            switch kind {
            case .length: return number(n) + " mm"
            case .angle: return number(n) + " deg"
            case .none: return number(n)
            }
        case .string(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw AIError(.invalidValue, "\(field) is empty.", reason: "Send a number or an expression.") }
            return t
        default:
            throw AIError(.invalidValue, "\(field) must be a number or an expression text.",
                          reason: "A number means millimetres (degrees for an angle); text is an expression such as \"2 in\" or \"wall * 2\".")
        }
    }

    /// 120 → "120", 0.5 → "0.5", never "120.0000000001".
    static func number(_ n: Double) -> String {
        var s = String(format: "%.6f", n)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" || s.isEmpty ? "0" : s
    }

    /// What an expression comes to in `values`, or why it doesn't.
    static func evaluate(_ expression: String, kind: UnitKind, field: String, positive: Bool, values: ParameterValues) throws -> Double {
        let result: Double
        do { result = try values.value(of: expression, kind: kind) } catch {
            let why = (error as? ExpressionError)?.message ?? "\(error)"
            throw AIError(.invalidValue, "\(field) \"\(expression)\" is not a valid \(kind == .angle ? "angle" : kind == .length ? "length" : "number"): \(why).",
                          reason: "Send a number (\(kind == .angle ? "degrees" : "millimetres")), or an expression using the part's parameters and units such as mm, cm, m, in, ft, deg.")
        }
        guard result.isFinite, !positive || result > 0 else {
            throw AIError(.invalidValue, "\(field) must be greater than 0 (\"\(expression)\" comes to \(number(result))).",
                          reason: "A size has to be positive. To make something smaller, send a smaller positive number; to remove it, delete the feature instead.")
        }
        return result
    }

    /// The plane a feature stands on: "xy", "xz", "yz", "plane:xy", "plane:<construction plane id>" or a flat face ("face:<body>/<name>").
    static func plane(_ text: String, in doc: CADDocument) throws -> PlaneRef {
        let lowered = text.lowercased()
        switch lowered {
        case "xy", "plane:xy": return .xy
        case "xz", "plane:xz": return .xz
        case "yz", "plane:yz": return .yz
        default: break
        }
        guard let ref = AIEntityRef(text) else {
            throw AIError(.invalidArguments, "plane \"\(text)\" is not a plane.",
                          reason: "Use \"xy\", \"xz\", \"yz\", the id of a construction plane as \"plane:<id>\", or a flat face as \"face:<body>/<name>\" from get_document or get_selection.")
        }
        switch ref {
        case .plane(let id):
            guard let f = doc.features.first(where: { $0.id == id }), case .plane = f.kind else {
                throw AIError(.invalidArguments, "There is no construction plane with the id \"\(id)\".")
            }
            return .plane(id)
        case .face(let face):
            guard doc.features.contains(where: { $0.id == face.body }) else {
                throw AIError(.invalidArguments, "There is no body with the id \"\(face.body)\".")
            }
            return .face(face)
        default:
            throw AIError(.invalidArguments, "\"\(text)\" is not a plane or a face.")
        }
    }

    /// An id the caller wants a new feature to have: short, plain, and not taken.
    static func newFeatureID(_ id: String?, in doc: CADDocument) throws -> FeatureID {
        guard let id else { return IDs.make() }
        guard id.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil else {
            throw AIError(.invalidArguments, "id \"\(id)\" is not allowed.", reason: "Use 1 to 40 letters, digits, underscores or hyphens.")
        }
        guard !doc.features.contains(where: { $0.id == id }), id != "origin" else {
            throw AIError(.invalidArguments, "id \"\(id)\" is already used by a feature.", reason: "Leave id out to get one made for you.")
        }
        return id
    }
}

enum AIOperationNames {
    /// "new_body", "join", "cut", "intersect".
    static func name(_ op: BodyOperation) -> String { op.rawValue.lowercased().replacingOccurrences(of: " ", with: "_") }
}

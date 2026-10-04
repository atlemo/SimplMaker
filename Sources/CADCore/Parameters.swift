// User parameters: named expressions, evaluated in dependency order.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

public struct Parameter: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var expression: String
    public var unit: UnitKind
    public var comment: String

    public init(_ name: String, _ expression: String, unit: UnitKind = .length, comment: String = "") {
        self.name = name; self.expression = expression; self.unit = unit; self.comment = comment
    }
}

/// Result of evaluating a parameter table.
public struct ParameterValues: Sendable {
    public var values: [String: Quantity] = [:]
    public var errors: [String: String] = [:]

    public init() {}

    public func lookup(_ name: String) throws -> Quantity {
        if let q = values[name] { return q }
        if errors[name] != nil { throw ExpressionError("parameter '\(name)' has an error") }
        throw ExpressionError("unknown parameter '\(name)'")
    }

    /// Evaluates a field expression (e.g. an extrude distance) against these parameters.
    public func value(of text: String, kind: UnitKind) throws -> Double {
        try Expressions.value(of: text, kind: kind, lookup: lookup)
    }
}

public enum ParameterEvaluator {
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !Expressions.isReserved(name)
    }

    public static func evaluate(_ params: [Parameter]) -> ParameterValues {
        var out = ParameterValues()
        var byName: [String: Parameter] = [:]
        for p in params {
            if !isValidName(p.name) { out.errors[p.name] = "invalid name"; continue }
            if byName[p.name] != nil { out.errors[p.name] = "duplicate name"; continue }
            byName[p.name] = p
        }
        var visiting: Set<String> = []

        func eval(_ name: String) throws -> Quantity {
            if let q = out.values[name] { return q }
            if let e = out.errors[name] { throw ExpressionError("'\(name)': \(e)") }
            guard let p = byName[name] else { throw ExpressionError("unknown parameter '\(name)'") }
            if visiting.contains(name) { throw ExpressionError("circular reference through '\(name)'") }
            visiting.insert(name)
            defer { visiting.remove(name) }
            do {
                let v = try Expressions.value(of: p.expression, kind: p.unit, lookup: eval)
                let q = Quantity(v, length: p.unit == .length ? 1 : 0, angle: p.unit == .angle ? 1 : 0)
                out.values[name] = q
                return q
            } catch let e as ExpressionError {
                if out.errors[name] == nil { out.errors[name] = e.message }
                throw e
            }
        }
        for p in params where byName[p.name] == p { _ = try? eval(p.name) }
        return out
    }
}

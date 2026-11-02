// Expressions with units, e.g. "width / 2 + 3 mm", "atan(h / w)", "45 deg".
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A value with a (length, angle) dimension. Internal base units: millimetres and radians.
public struct Quantity: Equatable, Sendable {
    public var value: Double
    public var length: Int  // exponent of length
    public var angle: Int   // exponent of angle

    public init(_ value: Double, length: Int = 0, angle: Int = 0) {
        self.value = value; self.length = length; self.angle = angle
    }
    public var isDimensionless: Bool { length == 0 && angle == 0 }
    public static func mm(_ v: Double) -> Quantity { Quantity(v, length: 1) }
    public static func rad(_ v: Double) -> Quantity { Quantity(v, angle: 1) }
}

/// The kind of value a field or parameter holds; decides how bare numbers are read.
public enum UnitKind: String, Codable, Sendable, CaseIterable {
    case length, angle, none

    /// "10" in a length field means 10 mm, in an angle field 10°.
    func promote(_ q: Quantity) -> Quantity {
        guard q.isDimensionless else { return q }
        switch self {
        case .length: return .mm(q.value)
        case .angle: return .rad(q.value * .pi / 180)
        case .none: return q
        }
    }
    func accepts(_ q: Quantity) -> Bool {
        switch self {
        case .length: return q.length == 1 && q.angle == 0
        case .angle: return q.length == 0 && q.angle == 1
        case .none: return q.isDimensionless
        }
    }
    /// Formats a base-unit value for display.
    public func format(_ v: Double) -> String {
        switch self {
        case .length: return String(format: "%g mm", (v * 1e6).rounded() / 1e6)
        case .angle: return String(format: "%g deg", (v * 180 / .pi * 1e6).rounded() / 1e6)
        case .none: return String(format: "%g", (v * 1e6).rounded() / 1e6)
        }
    }
}

public struct ExpressionError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

enum Units {
    static let table: [String: Quantity] = [
        "mm": .mm(1), "cm": .mm(10), "m": .mm(1000), "in": .mm(25.4), "ft": .mm(304.8),
        "deg": .rad(.pi / 180), "rad": .rad(1),
    ]
}

/// Parsed expression tree.
public indirect enum Expr: Equatable, Sendable {
    case number(Double)
    case unit(Expr, String)
    case ref(String)
    case neg(Expr)
    case binary(Character, Expr, Expr)
    case call(String, [Expr])

    /// Parameter names this expression refers to.
    public var references: Set<String> {
        switch self {
        case .number: return []
        case .ref(let n): return [n]
        case .unit(let e, _), .neg(let e): return e.references
        case .binary(_, let a, let b): return a.references.union(b.references)
        case .call(_, let args): return args.reduce(into: Set()) { $0.formUnion($1.references) }
        }
    }
}

public enum Expressions {
    static let constants: [String: Double] = ["pi": .pi, "e": M_E]
    static let functions: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "sqrt", "abs",
                                          "min", "max", "round", "floor", "ceil"]
    public static func isReserved(_ name: String) -> Bool {
        Units.table[name] != nil || constants[name] != nil || functions.contains(name)
    }

    // MARK: parsing

    public static func parse(_ text: String) throws -> Expr {
        var p = Parser(tokens: try tokenize(text))
        let e = try p.expression()
        guard p.pos == p.tokens.count else { throw ExpressionError("unexpected '\(p.tokens[p.pos])'") }
        return e
    }

    enum Token: Equatable, CustomStringConvertible {
        case num(Double), ident(String), op(Character)
        var description: String {
            switch self { case .num(let v): return "\(v)"; case .ident(let s): return s; case .op(let c): return String(c) }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var separator = false  // a number has at most one decimal separator
                while j < chars.count {
                    if chars[j].isNumber { j += 1; continue }
                    // "." always; "," too when it sits between two digits ("12,5" is 12.5, as typed in
                    // locales like Norwegian). Function arguments need a space: max(1, 5).
                    let decimal = chars[j] == "." ||
                        (chars[j] == "," && j > i && chars[j - 1].isNumber && j + 1 < chars.count && chars[j + 1].isNumber)
                    guard decimal, !separator else { break }
                    separator = true
                    j += 1
                }
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {  // exponent, only if digits follow
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isNumber {
                        j = k
                        while j < chars.count, chars[j].isNumber { j += 1 }
                    }
                }
                guard let v = Double(String(chars[i..<j]).replacingOccurrences(of: ",", with: ".")) else { throw ExpressionError("bad number '\(String(chars[i..<j]))'") }
                out.append(.num(v)); i = j; continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                out.append(.ident(String(chars[i..<j]))); i = j; continue
            }
            if "+-*/^(),".contains(c) { out.append(.op(c)); i += 1; continue }
            throw ExpressionError("unexpected character '\(c)'")
        }
        return out
    }

    struct Parser {
        let tokens: [Token]
        var pos = 0
        init(tokens: [Token]) { self.tokens = tokens }

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }
        mutating func eat(_ c: Character) -> Bool {
            if peek == .op(c) { pos += 1; return true }
            return false
        }

        mutating func expression() throws -> Expr {
            var lhs = try term()
            while let t = peek, case .op(let c) = t, c == "+" || c == "-" {
                pos += 1; lhs = .binary(c, lhs, try term())
            }
            return lhs
        }
        mutating func term() throws -> Expr {
            var lhs = try unary()
            while let t = peek, case .op(let c) = t, c == "*" || c == "/" {
                pos += 1; lhs = .binary(c, lhs, try unary())
            }
            return lhs
        }
        mutating func unary() throws -> Expr {
            if eat("-") { return .neg(try unary()) }
            if eat("+") { return try unary() }
            return try power()
        }
        mutating func power() throws -> Expr {
            let base = try withUnit(try primary())
            if eat("^") { return .binary("^", base, try unary()) }
            return base
        }
        /// A unit name directly after a number or parenthesis applies to it: "3 mm", "(a + 1) in".
        mutating func withUnit(_ e: Expr) throws -> Expr {
            if case .ident(let u)? = peek, Units.table[u] != nil {
                if case .ref = e { return e }  // "width mm" is not allowed
                pos += 1
                return .unit(e, u)
            }
            return e
        }
        mutating func primary() throws -> Expr {
            guard let t = peek else { throw ExpressionError("unexpected end of expression") }
            pos += 1
            switch t {
            case .num(let v): return .number(v)
            case .op("("):
                let e = try expression()
                guard eat(")") else { throw ExpressionError("missing ')'") }
                return e
            case .ident(let name):
                if eat("(") {
                    guard Expressions.functions.contains(name) else { throw ExpressionError("unknown function '\(name)'") }
                    var args: [Expr] = []
                    if !eat(")") {
                        repeat { args.append(try expression()) } while eat(",")
                        guard eat(")") else { throw ExpressionError("missing ')'") }
                    }
                    return .call(name, args)
                }
                if Units.table[name] != nil { throw ExpressionError("unit '\(name)' needs a number before it") }
                return .ref(name)
            default:
                throw ExpressionError("unexpected '\(t)'")
            }
        }
    }

    // MARK: evaluation

    /// Evaluates `expr`; `lookup` resolves parameter names to quantities.
    public static func evaluate(_ expr: Expr, lookup: (String) throws -> Quantity) throws -> Quantity {
        switch expr {
        case .number(let v): return Quantity(v)
        case .unit(let e, let u):
            let q = try evaluate(e, lookup: lookup)
            guard q.isDimensionless, let unit = Units.table[u] else { throw ExpressionError("cannot apply unit '\(u)' twice") }
            return Quantity(q.value * unit.value, length: unit.length, angle: unit.angle)
        case .ref(let name):
            if let c = constants[name] { return Quantity(c) }
            return try lookup(name)
        case .neg(let e):
            var q = try evaluate(e, lookup: lookup); q.value = -q.value; return q
        case .binary(let op, let l, let r):
            var a = try evaluate(l, lookup: lookup), b = try evaluate(r, lookup: lookup)
            switch op {
            case "+", "-":
                // A bare number next to a dimensioned value takes its dimension ("width + 5" = +5 mm).
                if a.isDimensionless && !b.isDimensionless { a = Quantity(a.value, length: b.length, angle: b.angle) }
                if b.isDimensionless && !a.isDimensionless { b = Quantity(b.value, length: a.length, angle: a.angle) }
                guard a.length == b.length && a.angle == b.angle else { throw ExpressionError("cannot add values with different units") }
                return Quantity(op == "+" ? a.value + b.value : a.value - b.value, length: a.length, angle: a.angle)
            case "*": return Quantity(a.value * b.value, length: a.length + b.length, angle: a.angle + b.angle)
            case "/":
                guard b.value != 0 else { throw ExpressionError("division by zero") }
                return Quantity(a.value / b.value, length: a.length - b.length, angle: a.angle - b.angle)
            case "^":
                guard b.isDimensionless else { throw ExpressionError("exponent must be unitless") }
                if a.isDimensionless { return Quantity(pow(a.value, b.value)) }
                guard b.value == b.value.rounded() else { throw ExpressionError("fractional power of a unit") }
                let n = Int(b.value)
                return Quantity(pow(a.value, b.value), length: a.length * n, angle: a.angle * n)
            default: throw ExpressionError("unknown operator \(op)")
            }
        case .call(let f, let argExprs):
            let args = try argExprs.map { try evaluate($0, lookup: lookup) }
            func one() throws -> Quantity {
                guard args.count == 1 else { throw ExpressionError("\(f) takes one argument") }
                return args[0]
            }
            func angleArg() throws -> Double {  // trig accepts radians-with-unit or bare degrees
                let q = try one()
                if q.length == 0 && q.angle == 1 { return q.value }
                guard q.isDimensionless else { throw ExpressionError("\(f) needs an angle") }
                return q.value * .pi / 180
            }
            func ratioArg() throws -> Double {
                let q = try one()
                guard q.isDimensionless else { throw ExpressionError("\(f) needs a unitless value") }
                return q.value
            }
            switch f {
            case "sin": return Quantity(sin(try angleArg()))
            case "cos": return Quantity(cos(try angleArg()))
            case "tan": return Quantity(tan(try angleArg()))
            case "asin": return .rad(asin(try ratioArg()))
            case "acos": return .rad(acos(try ratioArg()))
            case "atan": return .rad(atan(try ratioArg()))
            case "sqrt":
                let q = try one()
                guard q.length % 2 == 0, q.angle % 2 == 0 else { throw ExpressionError("sqrt of this unit is undefined") }
                return Quantity(q.value.squareRoot(), length: q.length / 2, angle: q.angle / 2)
            case "abs": var q = try one(); q.value = abs(q.value); return q
            case "round", "floor", "ceil":
                var q = try one()
                q.value = f == "round" ? q.value.rounded() : f == "floor" ? q.value.rounded(.down) : q.value.rounded(.up)
                return q
            case "min", "max":
                // Like + and -, bare numbers take the unit of the dimensioned arguments.
                guard !args.isEmpty else { throw ExpressionError("\(f) needs at least one argument") }
                let unit = args.first { !$0.isDimensionless } ?? args[0]
                guard args.allSatisfy({ $0.isDimensionless || ($0.length == unit.length && $0.angle == unit.angle) }) else {
                    throw ExpressionError("\(f) needs arguments with the same unit")
                }
                let v = f == "min" ? args.map(\.value).min()! : args.map(\.value).max()!
                return Quantity(v, length: unit.length, angle: unit.angle)
            default: throw ExpressionError("unknown function '\(f)'")
            }
        }
    }

    /// Parses and evaluates text for a field of the given kind; returns the value in base units.
    public static func value(of text: String, kind: UnitKind, lookup: (String) throws -> Quantity) throws -> Double {
        let q = kind.promote(try evaluate(try parse(text), lookup: lookup))
        guard kind.accepts(q) else {
            throw ExpressionError("expected \(kind == .none ? "a unitless value" : "a \(kind.rawValue)")")
        }
        return q.value
    }
}

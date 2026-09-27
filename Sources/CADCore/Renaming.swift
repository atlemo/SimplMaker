// Renaming parameters: every expression in the document that uses the old name is rewritten.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension Expressions {
    /// `text` with every use of the name `old` changed to `new`, leaving the rest exactly as typed.
    /// Numbers are skipped whole, so "2e3" never counts as a use of a parameter called "e".
    public static func renaming(_ text: String, _ old: String, to new: String) -> String {
        let chars = Array(text)
        var out = "", i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i + 1
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," { j += 1 }
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {  // an exponent, when digits follow
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isNumber { j = k; while j < chars.count, chars[j].isNumber { j += 1 } }
                }
                out += String(chars[i..<j]); i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let name = String(chars[i..<j])
                out += name == old ? new : name; i = j
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    /// Whether `text` uses the name.
    public static func uses(_ text: String, _ name: String) -> Bool {
        ((try? parse(text))?.references.contains(name)) ?? false
    }
}

extension Feature.Kind {
    /// Every expression the feature holds, each replaced by `change(expression)`.
    public mutating func mapExpressions(_ change: (String) -> String) {
        switch self {
        case .sketch(var f):
            for i in f.sketch.dimensions.indices { f.sketch.dimensions[i].expression = change(f.sketch.dimensions[i].expression) }
            for i in f.sketch.texts.indices { f.sketch.texts[i].height = change(f.sketch.texts[i].height) }
            self = .sketch(f)
        case .extrude(var f):
            switch f.extent {
            case .distance(let d): f.extent = .distance(change(d))
            case .symmetric(let d): f.extent = .symmetric(change(d))
            case .twoSides(let d, let b): f.extent = .twoSides(change(d), back: change(b))
            }
            self = .extrude(f)
        case .fillet(var f): f.size = change(f.size); self = .fillet(f)
        case .chamfer(var f): f.size = change(f.size); self = .chamfer(f)
        case .revolve(var f): f.angle = change(f.angle); self = .revolve(f)
        case .sweep, .loft, .combine: break
        case .rib(var f): f.thickness = change(f.thickness); self = .rib(f)
        case .hole(var f):
            f.u = change(f.u); f.v = change(f.v); f.diameter = change(f.diameter); f.depth = f.depth.map(change)
            f.tipAngle = change(f.tipAngle); f.headDiameter = change(f.headDiameter)
            f.headDepth = change(f.headDepth); f.headAngle = change(f.headAngle)
            self = .hole(f)
        case .primitive(var f):
            f.u = change(f.u); f.v = change(f.v); f.width = change(f.width); f.length = change(f.length)
            f.height = change(f.height); f.diameter = change(f.diameter); f.tube = change(f.tube)
            f.pitch = change(f.pitch); f.turns = change(f.turns)
            self = .primitive(f)
        case .pipe(var f): f.diameter = change(f.diameter); f.wall = f.wall.map(change); self = .pipe(f)
        case .move(var f): f.dx = change(f.dx); f.dy = change(f.dy); f.dz = change(f.dz); self = .move(f)
        case .rotate(var f): f.angle = change(f.angle); self = .rotate(f)
        }
    }

    /// Every expression the feature holds.
    public var expressions: [String] {
        var all: [String] = []
        var copy = self
        copy.mapExpressions { all.append($0); return $0 }
        return all
    }
}

public struct RenameError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
}

extension CADDocument {
    /// Renames a parameter and every use of it (in features, sketch dimensions and other parameters).
    public mutating func renameParameter(_ old: String, to new: String) throws {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard name != old else { return }
        guard let i = parameters.firstIndex(where: { $0.name == old }) else { throw RenameError(message: "No parameter called \(old)") }
        guard ParameterEvaluator.isValidName(name) else {
            throw RenameError(message: Expressions.isReserved(name)
                ? "\(name) is already a unit, constant or function name"
                : "A name starts with a letter and has only letters, digits and _")
        }
        guard !parameters.contains(where: { $0.name == name }) else { throw RenameError(message: "There's already a parameter called \(name)") }
        let change = { (text: String) in Expressions.uses(text, old) ? Expressions.renaming(text, old, to: name) : text }
        parameters[i].name = name
        for j in parameters.indices { parameters[j].expression = change(parameters[j].expression) }
        for j in features.indices { features[j].kind.mapExpressions(change) }
    }

    /// The features whose expressions use a parameter.
    public func features(using parameter: String) -> [Feature] {
        features.filter { $0.kind.expressions.contains { Expressions.uses($0, parameter) } }
    }
}

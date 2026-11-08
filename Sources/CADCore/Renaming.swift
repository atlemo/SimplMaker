// Renaming parameters: every expression in the document that uses the old name is rewritten.
// Copyright © 2026 Atle Mo
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
            case .throughAll, .toFace: break
            }
            if let t = f.taper { f.taper = change(t) }
            self = .extrude(f)
        case .fillet(var f): f.size = change(f.size); self = .fillet(f)
        case .chamfer(var f):
            f.size = change(f.size)
            if !f.second.isEmpty { f.second = change(f.second) }
            self = .chamfer(f)
        case .revolve(var f): f.angle = change(f.angle); self = .revolve(f)
        case .sweep, .loft, .combine, .split, .layOnFloor: break
        case .twistSweep(var f):
            f.distance = change(f.distance); f.startAngle = change(f.startAngle); f.endAngle = change(f.endAngle)
            f.curve = change(f.curve); f.shiftU = change(f.shiftU); f.shiftV = change(f.shiftV)
            f.pivotU = f.pivotU.map(change); f.pivotV = f.pivotV.map(change)
            self = .twistSweep(f)
        case .rib(var f): f.thickness = change(f.thickness); self = .rib(f)
        case .hole(var f):
            f.u = change(f.u); f.v = change(f.v); f.diameter = change(f.diameter); f.depth = f.depth.map(change)
            f.tipAngle = change(f.tipAngle); f.headDiameter = change(f.headDiameter)
            f.headDepth = change(f.headDepth); f.headAngle = change(f.headAngle)
            self = .hole(f)
        case .thread(var f): f.length = f.length.map(change); f.tolerance = f.tolerance.map(change); self = .thread(f)
        case .primitive(var f):
            f.u = change(f.u); f.v = change(f.v); f.width = change(f.width); f.length = change(f.length)
            f.height = change(f.height); f.diameter = change(f.diameter); f.tube = change(f.tube)
            f.pitch = change(f.pitch); f.turns = change(f.turns)
            self = .primitive(f)
        case .pipe(var f): f.diameter = change(f.diameter); f.wall = f.wall.map(change); self = .pipe(f)
        case .move(var f):
            f.dx = change(f.dx); f.dy = change(f.dy); f.dz = change(f.dz)
            f.rx = change(f.rx); f.ry = change(f.ry); f.rz = change(f.rz)
            self = .move(f)
        case .rotate(var f): f.angle = change(f.angle); self = .rotate(f)
        case .scale(var f): f.factor = change(f.factor); self = .scale(f)
        case .plane(var f): f.offset = change(f.offset); f.angle = change(f.angle); self = .plane(f)
        case .mirror: break
        case .pattern(var f): f.count = change(f.count); f.spacing = change(f.spacing); self = .pattern(f)
        case .shell(var f): f.thickness = change(f.thickness); self = .shell(f)
        case .draft(var f): f.angle = change(f.angle); self = .draft(f)
        case .project(var f): f.height = change(f.height); self = .project(f)
        case .importBody: break
        case .image(var f): f.u = change(f.u); f.v = change(f.v); f.width = change(f.width); f.angle = change(f.angle); self = .image(f)
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
        if let home = parameterFolderOf.removeValue(forKey: old) { parameterFolderOf[name] = home }
        for j in parameters.indices { parameters[j].expression = change(parameters[j].expression) }
        for j in features.indices { features[j].kind.mapExpressions(change) }
    }

    /// The features whose expressions use a parameter.
    public func features(using parameter: String) -> [Feature] {
        features.filter { $0.kind.expressions.contains { Expressions.uses($0, parameter) } }
    }
}

extension PlaneRef {
    /// The feature this plane comes from: the body a face is on, or a construction plane.
    var feature: FeatureID? {
        switch self {
        case .xy, .xz, .yz: return nil
        case .face(let f): return f.body
        case .plane(let id): return id
        }
    }
}

extension Feature {
    /// The features this one is built from: its sketches and planes, and the bodies it changes or
    /// reads (a body is named by the feature that made it).
    public var references: Set<FeatureID> {
        var out = Set<FeatureID>()
        func add(_ id: FeatureID?) { if let id, !id.isEmpty { out.insert(id) } }
        switch kind {
        case .sketch(let f): add(f.plane.feature)
        case .extrude(let f):
            add(f.face == nil ? f.sketch : nil); add(f.face?.body); add(f.target)
            if case .toFace(let face) = f.extent { add(face.body) }
            add(f.start?.body)
        case .revolve(let f): add(f.sketch); add(f.target)
        case .sweep(let f): add(f.sketch); add(f.path.sketch); add(f.target)
        case .loft(let f): f.sections.forEach { add($0.sketch) }; add(f.target)
        case .twistSweep(let f): add(f.sketch); add(f.target); f.targets?.forEach { add($0) }
        case .rib(let f): add(f.path.sketch); add(f.target)
        case .hole(let f): add(f.face.body)
        case .thread(let f): add(f.face.body)
        case .primitive(let f): add(f.plane.feature); add(f.target)
        case .pipe(let f): add(f.path.sketch); add(f.target)
        case .fillet(let f), .chamfer(let f): f.edges.forEach { add($0.body) }; f.faces.forEach { add($0.body) }
        case .move(let f): f.bodies.forEach { add($0) }; f.sketches.forEach { add($0) }
        case .rotate(let f): f.bodies.forEach { add($0) }
        case .scale(let f): f.sketches.forEach { add($0) }; f.bodies.forEach { add($0) }
        case .combine(let f): add(f.target); f.tools.forEach { add($0) }
        case .split(let f):
            f.bodies.forEach { add($0) }
            switch f.tool {
            case .plane(let plane): add(plane.feature)
            case .face(let face): add(face.body)
            case .profile(let sketch): add(sketch)
            case .parts: break
            }
        case .layOnFloor(let f): add(f.face.body)
        case .plane(let f): add(f.base.feature)
        case .mirror(let f):
            f.bodies.forEach { add($0) }
            if case .edge(let e)? = f.line { add(e.body) } else if f.line == nil { add(f.plane.feature) }
        case .pattern(let f):
            f.bodies.forEach { add($0) }
            f.features?.forEach { add($0) }
            if case .edge(let e) = f.axis { add(e.body) }
            if case .cylinder(let face) = f.axis { add(face.body) }
        case .shell(let f): add(f.body); f.faces.forEach { add($0.body) }
        case .draft(let f): add(f.body); f.faces.forEach { add($0.body) }; add(f.fixed?.body)
        case .project(let f): add(f.sketch); add(f.target); f.faces.forEach { add($0.body) }
        case .importBody: break
        case .image(let f): add(f.plane.feature)
        }
        out.remove(id)
        return out
    }

    /// The bodies this feature changes (not the ones it makes): joins, cuts, fillets, moves…
    public var changedBodies: Set<FeatureID> {
        var out = Set<FeatureID>()
        func add(_ id: FeatureID?) { if let id { out.insert(id) } }
        switch kind {
        case .extrude(let f): if f.operation != .newBody { add(f.target); add(f.face?.body) }
        case .revolve(let f): if f.operation != .newBody { add(f.target) }
        case .sweep(let f): if f.operation != .newBody { add(f.target) }
        case .loft(let f): if f.operation != .newBody { add(f.target) }
        case .twistSweep(let f): if f.operation != .newBody { add(f.target); f.targets?.forEach { add($0) } }
        case .rib(let f): add(f.target)
        case .hole(let f): out.insert(f.face.body)
        case .thread(let f): out.insert(f.face.body)
        case .primitive(let f): if f.operation != .newBody { add(f.target) }
        case .pipe(let f): if f.operation != .newBody { add(f.target) }
        case .fillet(let f), .chamfer(let f): f.edges.forEach { out.insert($0.body) }; f.faces.forEach { out.insert($0.body) }
        case .move(let f): f.bodies.forEach { out.insert($0) }
        case .rotate(let f): f.bodies.forEach { out.insert($0) }
        case .scale(let f): f.bodies.forEach { out.insert($0) }
        case .combine(let f): out.insert(f.target)
        case .split(let f): f.bodies.forEach { out.insert($0) }
        case .layOnFloor(let f): out.insert(f.face.body)
        case .mirror(let f): if f.operation != .newBody { f.bodies.forEach { out.insert($0) } }
        case .pattern(let f): if f.operation != .newBody { f.bodies.forEach { out.insert($0) } }
        case .shell(let f): out.insert(f.body)
        case .draft(let f): out.insert(f.body)
        case .project(let f): out.insert(f.target)
        case .sketch, .plane, .importBody, .image: break
        }
        return out
    }
}

extension CADDocument {
    /// Why the feature can't move to `index` (its place in the reordered timeline), or nil if it can:
    /// it may not come before what it's built from, nor before a feature that changes a body it
    /// uses; and what's built from it may not end up before it.
    public func reorderProblem(_ id: FeatureID, to index: Int) -> String? {
        guard let from = self.index(of: id) else { return "That feature is missing" }
        var order = features
        let f = order.remove(at: from)
        let to = Swift.min(Swift.max(index, 0), order.count)
        order.insert(f, at: to)
        func name(_ id: FeatureID) -> String { features.first { $0.id == id }?.name ?? "a missing feature" }
        // Looked up once, not per feature: this runs for every item of the timeline's menus.
        let inOrder = Set(order.map(\.id))
        let position = Dictionary(features.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = features.map(\.changedBodies)
        var before = Set<FeatureID>()
        for g in order {
            let usesBodies = g.references
            // What it's built from must come first…
            if let missing = usesBodies.first(where: { r in !before.contains(r) && inOrder.contains(r) }) {
                return g.id == id ? "\(g.name) is built from \(name(missing)), so it has to come after it"
                                  : "\(g.name) is built from \(f.name), so \(f.name) has to come before it"
            }
            // …and so must whatever changes a body it uses before it did.
            if !usesBodies.isEmpty, let own = position[g.id] {
                for j in 0..<own where !changed[j].isDisjoint(with: usesBodies) && !before.contains(features[j].id) {
                    let h = features[j]
                    return h.id == id ? "\(g.name) uses the body as \(h.name) leaves it, so \(h.name) has to stay before it"
                                      : "\(g.name) uses the body as \(h.name) leaves it, so it has to stay after \(h.name)"
                }
            }
            before.insert(g.id)
        }
        return nil
    }
}

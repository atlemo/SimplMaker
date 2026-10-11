// The shapes an assistant can add to a sketch, and how each is built. Every shape is made with the sketch's own builders
// (CADCore), so it carries the same constraints a shape drawn by hand has; sizes and positions become named dimensions
// ("key.width", "hole.diameter", "key.x") that can be changed later, and all of them accept expressions that use the
// part's parameters. Shapes the caller doesn't name get an id such as "rect1".
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd

/// A position in a sketch: each coordinate a number (mm) or an expression, as the text the document stores.
struct SketchPoint2: Equatable, Sendable {
    var x: String
    var y: String
}

enum SketchShape: Sendable {
    /// Centred on `center`, or with its lower left corner at `corner` (default: centred on the origin).
    case rectangle(id: String?, center: SketchPoint2?, corner: SketchPoint2?, width: String, height: String, cornerRadius: String?)
    case circle(id: String?, center: SketchPoint2, diameter: String?, radius: String?)
    case polygon(id: String?, center: SketchPoint2, radius: String, sides: Int, rotation: String?)
    case line(id: String?, from: SketchPoint2, to: SketchPoint2)
    case polyline(id: String?, points: [SketchPoint2], closed: Bool)
    case arc(id: String?, from: SketchPoint2, through: SketchPoint2, to: SketchPoint2)
    case text(id: String?, text: String, at: SketchPoint2, height: String, font: String?, angle: String?, centered: Bool)

    var typeName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .polygon: return "polygon"
        case .line: return "line"
        case .polyline: return "polyline"
        case .arc: return "arc"
        case .text: return "text"
        }
    }

    var requestedID: String? {
        switch self {
        case .rectangle(let id, _, _, _, _, _), .circle(let id, _, _, _), .polygon(let id, _, _, _, _), .line(let id, _, _),
             .polyline(let id, _, _), .arc(let id, _, _, _), .text(let id, _, _, _, _, _, _): return id
        }
    }

    var idPrefix: String {
        switch self {
        case .rectangle: return "rect"
        case .circle: return "circle"
        case .polygon: return "polygon"
        case .line: return "line"
        case .polyline: return "path"
        case .arc: return "arc"
        case .text: return "text"
        }
    }
}

/// What building a shape made.
struct ShapeResult {
    var id: String
    var type: String
    /// The ids of the dimensions that drive it, to use with modify_feature.
    var dimensions: [String] = []
    /// Ids of the curves it is made of that a later step may want ("key.top").
    var curves: [String] = []

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "type": .string(type)]
        if !dimensions.isEmpty { o["dimensions"] = .array(dimensions.map { .string($0) }) }
        if !curves.isEmpty { o["curves"] = .array(curves.map { .string($0) }) }
        return .object(o)
    }
}

enum SketchBuilder {
    // MARK: ids

    /// Every id a sketch already uses, for telling that a new one is free.
    static func usedIDs(_ sk: Sketch) -> Set<String> {
        var ids: Set<String> = ["origin"]
        for p in sk.points { ids.insert(p.id) }
        for c in sk.curves { ids.insert(c.id) }
        for t in sk.texts { ids.insert(t.id) }
        for d in sk.dimensions { ids.insert(d.id) }
        for c in sk.constraints { ids.insert(c.id) }
        return ids
    }

    /// The id for a new shape: the one asked for if it is allowed and free, else "rect1", "rect2"…
    static func shapeID(_ requested: String?, prefix: String, in sk: Sketch) throws -> String {
        let used = usedIDs(sk)
        func taken(_ id: String) -> Bool { used.contains(id) || used.contains { $0.hasPrefix(id + ".") } }
        if let requested {
            guard requested.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,39}$"#, options: .regularExpression) != nil else {
                throw AIError(.invalidArguments, "id \"\(requested)\" is not allowed for a shape.",
                              reason: "Use 1 to 40 letters, digits, underscores or hyphens, starting with a letter.")
            }
            guard !taken(requested) else {
                throw AIError(.invalidArguments, "id \"\(requested)\" is already used in this sketch.", reason: "Leave id out to get one made for you, or pick another.")
            }
            return requested
        }
        var n = 1
        while taken("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    // MARK: values

    static func value(_ expression: String, _ field: String, positive: Bool = false, _ values: ParameterValues) throws -> Double {
        try AIValues.evaluate(expression, kind: .length, field: field, positive: positive, values: values)
    }

    static func point(_ p: SketchPoint2, _ field: String, _ values: ParameterValues) throws -> SIMD2<Double> {
        SIMD2(try value(p.x, "\(field).x", values), try value(p.y, "\(field).y", values))
    }

    /// The size of a distance from the origin, as an expression: the coordinate itself when it is not negative, its magnitude when it is
    /// (a distance dimension keeps the side the geometry is on, so it carries no sign).
    static func magnitude(_ expression: String, _ value: Double) -> String {
        guard value < 0 else { return expression }
        if expression.range(of: #"^-\s*[0-9.]+\s*[A-Za-z]*$"#, options: .regularExpression) != nil {
            return String(expression.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return "-(\(expression))"
    }

    /// Pins a point to a position with two named dimensions from the origin ("<id>.x", "<id>.y").
    static func place(_ pointID: EntityID, at p: SketchPoint2, value: SIMD2<Double>, name: String, in sk: inout Sketch) -> [String] {
        sk.dimension(.horizontalDistance("origin", pointID), magnitude(p.x, value.x), id: "\(name).x")
        sk.dimension(.verticalDistance("origin", pointID), magnitude(p.y, value.y), id: "\(name).y")
        return ["\(name).x", "\(name).y"]
    }

    /// Solves the sketch with its dimensions; the shape is refused if it can't be satisfied.
    static func checkSolves(_ sk: inout Sketch, _ values: ParameterValues, shape: String) throws {
        var trial = sk
        let result = SketchSolver.solve(&trial, dimensionValues: trial.dimensionValues(values))
        guard result.status == .solved else {
            throw AIError(.invalidValue, "The \(shape) can't be built: its sizes and constraints contradict each other.",
                          reason: "Check that the sizes fit together, for example that a corner radius is not larger than half of the shorter side.")
        }
        sk = trial
    }

    // MARK: building

    static func build(_ shape: SketchShape, into sk: inout Sketch, values: ParameterValues) throws -> ShapeResult {
        let id = try shapeID(shape.requestedID, prefix: shape.idPrefix, in: sk)
        var result = ShapeResult(id: id, type: shape.typeName)
        switch shape {
        case .rectangle(_, let center, let corner, let widthText, let heightText, let radiusText):
            let w = try value(widthText, "width", positive: true, values), h = try value(heightText, "height", positive: true, values)
            // A corner radius of exactly half the shorter side makes a slot (a stadium): the corner fillet can't do that,
            // since the short sides would vanish, so it is built with two arcs and two lines.
            if let radiusText, corner == nil {
                let radius = try value(radiusText, "corner_radius", positive: true, values)
                if abs(radius - min(w, h) / 2) < 1e-9 {
                    let c = center ?? SketchPoint2(x: "0 mm", y: "0 mm")
                    return try buildSlot(id: id, center: c, centerValue: try point(c, "center", values), width: (widthText, w), height: (heightText, h),
                                         into: &sk, values: values)
                }
            }
            let lines = ["\(id).bottom", "\(id).right", "\(id).top", "\(id).left"]
            let anchor: SketchPoint2, anchorValue: SIMD2<Double>, x0: Double, y0: Double
            if let corner {
                anchor = corner; anchorValue = try point(corner, "corner", values); x0 = anchorValue.x; y0 = anchorValue.y
            } else {
                anchor = center ?? SketchPoint2(x: "0 mm", y: "0 mm"); anchorValue = try point(anchor, "center", values)
                x0 = anchorValue.x - w / 2; y0 = anchorValue.y - h / 2
            }
            let r = sk.addRectangle(x0, y0, x0 + w, y0 + h, lineIDs: lines)
            sk.dimension(.length(lines[0]), widthText, id: "\(id).width")
            sk.dimension(.length(lines[1]), heightText, id: "\(id).height")
            result.dimensions = ["\(id).width", "\(id).height"]
            result.curves = lines
            // Round the corners first: the routine wants each corner to be where exactly two lines meet, so what pins the
            // shape in place (which touches the corners) comes after.
            if let radiusText {
                let radius = try value(radiusText, "corner_radius", positive: true, values)
                guard radius <= min(w, h) / 2 + 1e-9 else {
                    throw AIError(.invalidValue, "corner_radius \(radiusText) (\(AIValues.number(radius)) mm) is too large for a \(AIValues.number(w)) × \(AIValues.number(h)) mm rectangle.",
                                  reason: "A corner radius can be at most half of the shorter side (\(AIValues.number(min(w, h) / 2)) mm); at exactly half the short ends become half circles, a slot.")
                }
                var firstArc: EntityID?
                for (n, corner) in r.corners.enumerated() {
                    guard let dim = sk.filletCorner(corner, radius: radius, expression: radiusText),
                          let at = sk.dimensions.firstIndex(where: { $0.id == dim }), case .radius(let arc) = sk.dimensions[at].kind else {
                        throw AIError(.invalidValue, "The corners of the rectangle can't be rounded by \(radiusText).",
                                      reason: "Use a radius smaller than half of the shorter side.")
                    }
                    if n == 0 {
                        firstArc = arc
                        sk.dimensions[at].id = "\(id).radius"
                        result.dimensions.append("\(id).radius")
                    } else if let firstArc {
                        // One radius for all four corners: the others are equal to the first, not dimensions of their own.
                        sk.dimensions.remove(at: at)
                        sk.constrain(.equal(firstArc, arc))
                    }
                }
            }
            if corner != nil {
                result.dimensions += place(r.corners[0], at: anchor, value: anchorValue, name: id, in: &sk)
            } else {
                // Centred for good: the middle of a construction diagonal, which then sits at the position asked for.
                let middle = sk.addPoint(anchorValue.x, anchorValue.y)
                let diagonal = sk.addLine(r.corners[0], r.corners[2], construction: true)
                sk.constrain(.midpoint(point: middle, line: diagonal))
                result.dimensions += place(middle, at: anchor, value: anchorValue, name: id, in: &sk)
            }

        case .circle(_, let center, let diameterText, let radiusText):
            guard (diameterText == nil) != (radiusText == nil) else {
                throw AIError(.invalidArguments, "A circle needs exactly one of diameter or radius.", reason: "For a 5 mm hole send diameter 5.")
            }
            let c = try point(center, "center", values)
            let size = try value((diameterText ?? radiusText)!, diameterText != nil ? "diameter" : "radius", positive: true, values)
            let centerID = sk.addPoint(c.x, c.y)
            sk.addCircle(center: centerID, radius: diameterText != nil ? size / 2 : size, id: id)
            if let diameterText { sk.dimension(.diameter(id), diameterText, id: "\(id).diameter"); result.dimensions = ["\(id).diameter"] }
            else if let radiusText { sk.dimension(.radius(id), radiusText, id: "\(id).radius"); result.dimensions = ["\(id).radius"] }
            result.dimensions += place(centerID, at: center, value: c, name: id, in: &sk)
            result.curves = [id]

        case .polygon(_, let center, let radiusText, let sides, let rotationText):
            guard Sketch.polygonSides.contains(sides) else {
                throw AIError(.invalidArguments, "A polygon has \(Sketch.polygonSides.lowerBound) to \(Sketch.polygonSides.upperBound) sides, not \(sides).")
            }
            let c = try point(center, "center", values)
            let radius = try value(radiusText, "radius", positive: true, values)
            let rotation = try rotationText.map { try AIValues.evaluate($0, kind: .angle, field: "rotation", positive: false, values: values) } ?? 0
            let corner = c + radius * SIMD2(cos(rotation), sin(rotation))
            let made = sk.addPolygon(center: SketchSnap(c), corner: SketchSnap(corner), sides: sides)
            // The circle the corners sit on carries the size; the centre is pinned like any other shape's.
            if let at = sk.curves.firstIndex(where: { $0.id == made.circle }), case .circle(let centerID, _) = sk.curves[at].geometry {
                sk.dimension(.radius(made.circle), radiusText, id: "\(id).radius")
                result.dimensions = ["\(id).radius"] + place(centerID, at: center, value: c, name: id, in: &sk)
            }
            result.curves = made.lines

        case .line(_, let from, let to):
            let a = try point(from, "from", values), b = try point(to, "to", values)
            guard simd_length(b - a) > 1e-9 else { throw AIError(.invalidValue, "The line has no length: from and to are the same point.") }
            let pa = sk.addPoint(a.x, a.y), pb = sk.addPoint(b.x, b.y)
            sk.addLine(pa, pb, id: id)
            addAlignment(id, a, b, in: &sk)
            result.curves = [id]

        case .polyline(_, let points, let closed):
            guard points.count >= (closed ? 3 : 2) else {
                throw AIError(.invalidArguments, closed ? "A closed path needs at least 3 points." : "A path needs at least 2 points.")
            }
            let values2 = try points.enumerated().map { try point($1, "points[\($0)]", values) }
            let ids = values2.map { sk.addPoint($0.x, $0.y) }
            let count = closed ? ids.count : ids.count - 1
            for i in 0..<count {
                let j = (i + 1) % ids.count
                guard simd_length(values2[j] - values2[i]) > 1e-9 else {
                    throw AIError(.invalidValue, "Points \(i + 1) and \(j + 1) of the path are the same point.")
                }
                let name = "\(id).\(i + 1)"
                sk.addLine(ids[i], ids[j], id: name)
                addAlignment(name, values2[i], values2[j], in: &sk)
                result.curves.append(name)
            }

        case .arc(_, let from, let through, let to):
            let a = try point(from, "from", values), m = try point(through, "through", values), b = try point(to, "to", values)
            guard let (centre, counterClockwise) = Self.circumcircle(a, m, b) else {
                throw AIError(.invalidValue, "The arc can't be made: the three points are on a straight line.", reason: "Use a line, or move the middle point off the line between the others.")
            }
            let (start, end) = counterClockwise ? (a, b) : (b, a)
            let centreID = sk.addPoint(centre.x, centre.y)
            let startID = sk.addPoint(start.x, start.y), endID = sk.addPoint(end.x, end.y)
            sk.addArc(center: centreID, start: startID, end: endID, id: id)
            result.curves = [id]

        case .text(_, let text, let at, let heightText, let font, let angleText, let centered):
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, content.count <= 200 else {
                throw AIError(.invalidArguments, content.isEmpty ? "The text is empty." : "The text is too long (\(content.count) letters; at most 200).")
            }
            let height = try value(heightText, "height", positive: true, values)
            let position = try point(at, "at", values)
            let angle = try angleText.map { try AIValues.evaluate($0, kind: .angle, field: "angle", positive: false, values: values) } ?? 0
            let fontName = font ?? SketchText.defaultFont
            var origin = position
            if centered {
                // `at` is the middle of the letters: start where that puts their middle there.
                let outline = TextOutline.contours(content, fontName: fontName, height: height, origin: .zero, angle: 0).flatMap { $0 }.flatMap { $0 }
                guard let minX = outline.map(\.x).min(), let maxX = outline.map(\.x).max(),
                      let minY = outline.map(\.y).min(), let maxY = outline.map(\.y).max() else {
                    throw AIError(.invalidValue, "No letters could be made from this text in the font \(fontName).", reason: "Check the text and the font name.")
                }
                let middle = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
                origin = position - SIMD2(cos(angle) * middle.x - sin(angle) * middle.y, sin(angle) * middle.x + cos(angle) * middle.y)
            }
            let pointID = sk.addPoint(origin.x, origin.y)
            sk.texts.append(SketchText(id: id, text: content, position: pointID, height: heightText, font: fontName, angle: angle))
            // Where the text starts is pinned with dimensions in the text's own coordinates, so it can be moved later.
            sk.dimension(.horizontalDistance("origin", pointID), magnitude(AIValues.number(origin.x) + " mm", origin.x), id: "\(id).x")
            sk.dimension(.verticalDistance("origin", pointID), magnitude(AIValues.number(origin.y) + " mm", origin.y), id: "\(id).y")
            result.dimensions = ["\(id).x", "\(id).y", "\(id).height"]
        }
        try checkSolves(&sk, values, shape: "\(shape.typeName) \(id)")
        return result
    }

    /// A slot: a rectangle whose short ends are half circles. `width` and `height` are the overall sizes; the shorter one is the
    /// slot's diameter. Both stay real dimensions ("<id>.width" is the overall width), pinned on the extreme points of the ends.
    private static func buildSlot(id: String, center: SketchPoint2, centerValue c: SIMD2<Double>, width: (String, Double), height: (String, Double),
                                  into sk: inout Sketch, values: ParameterValues) throws -> ShapeResult {
        var result = ShapeResult(id: id, type: "rectangle")
        let (widthText, w) = width, (heightText, h) = height
        guard abs(w - h) > 1e-9 else {
            // A square with a corner radius of half its side is a circle.
            let centerID = sk.addPoint(c.x, c.y)
            sk.addCircle(center: centerID, radius: w / 2, id: id)
            sk.dimension(.diameter(id), widthText, id: "\(id).width")
            result.dimensions = ["\(id).width"] + place(centerID, at: center, value: c, name: id, in: &sk)
            result.curves = [id]
            try checkSolves(&sk, values, shape: "slot \(id)")
            return result
        }
        let horizontal = w > h
        let length = horizontal ? w : h, thickness = horizontal ? h : w, r = thickness / 2
        let axis = horizontal ? SIMD2(1.0, 0.0) : SIMD2(0.0, 1.0)
        let perp = SIMD2(-axis.y, axis.x)
        let cA = c - axis * (length / 2 - r), cB = c + axis * (length / 2 - r)
        let ids = (cA: sk.addPoint(cA.x, cA.y), cB: sk.addPoint(cB.x, cB.y))
        let aPlus = sk.addPoint((cA + perp * r).x, (cA + perp * r).y), aMinus = sk.addPoint((cA - perp * r).x, (cA - perp * r).y)
        let bPlus = sk.addPoint((cB + perp * r).x, (cB + perp * r).y), bMinus = sk.addPoint((cB - perp * r).x, (cB - perp * r).y)
        let (plusName, minusName) = horizontal ? ("top", "bottom") : ("left", "right")
        let (endA, endB) = horizontal ? ("left", "right") : ("bottom", "top")
        let plusLine = sk.addLine(aPlus, bPlus, id: "\(id).\(plusName)"), minusLine = sk.addLine(aMinus, bMinus, id: "\(id).\(minusName)")
        let arcA = sk.addArc(center: ids.cA, start: aPlus, end: aMinus, id: "\(id).\(endA)")     // counter-clockwise round the low end
        let arcB = sk.addArc(center: ids.cB, start: bMinus, end: bPlus, id: "\(id).\(endB)")     // and round the high end
        let aligned: (EntityID) -> SketchConstraint.Kind = { horizontal ? .horizontal($0) : .vertical($0) }
        sk.constrain(aligned(plusLine)); sk.constrain(aligned(minusLine))
        for line in [plusLine, minusLine] { for arc in [arcA, arcB] { sk.constrain(.tangent(line, arc)) } }
        sk.constrain(.equal(arcA, arcB))
        // Each tangent point sits straight across from its arc's centre: the radius to it is square to the straight sides.
        let square: (EntityID) -> SketchConstraint.Kind = { horizontal ? .vertical($0) : .horizontal($0) }
        for (centre, tangent) in [(ids.cA, aPlus), (ids.cA, aMinus), (ids.cB, bPlus), (ids.cB, bMinus)] {
            sk.constrain(square(sk.addLine(centre, tangent, construction: true)))
        }
        // The overall length is measured between the two extreme points, each on its arc and level with its centre.
        let eA = sk.addPoint((cA - axis * r).x, (cA - axis * r).y), eB = sk.addPoint((cB + axis * r).x, (cB + axis * r).y)
        sk.constrain(.pointOnCurve(point: eA, curve: arcA)); sk.constrain(.pointOnCurve(point: eB, curve: arcB))
        for (centre, extreme) in [(ids.cA, eA), (ids.cB, eB)] { sk.constrain(aligned(sk.addLine(centre, extreme, construction: true))) }
        let spine = sk.addLine(ids.cA, ids.cB, construction: true)
        sk.constrain(aligned(spine))
        let middle = sk.addPoint(c.x, c.y)
        sk.constrain(.midpoint(point: middle, line: spine))
        sk.dimension(.diameter(arcA), horizontal ? heightText : widthText, id: "\(id).\(horizontal ? "height" : "width")")
        sk.dimension(horizontal ? .horizontalDistance(eA, eB) : .verticalDistance(eA, eB), horizontal ? widthText : heightText,
                     id: "\(id).\(horizontal ? "width" : "height")")
        result.dimensions = ["\(id).width", "\(id).height"] + place(middle, at: center, value: c, name: id, in: &sk)
        result.curves = ["\(id).\(plusName)", "\(id).\(minusName)", "\(id).\(endA)", "\(id).\(endB)"]
        try checkSolves(&sk, values, shape: "slot \(id)")
        return result
    }

    /// Where the middle of a text's letters is, relative to where it starts.
    static func textCentre(_ text: SketchText, height: Double) -> SIMD2<Double>? {
        let points = TextOutline.contours(text.text, fontName: text.font, height: height, origin: .zero, angle: text.angle).flatMap { $0 }.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
    }

    /// A text whose height or words changed grows, shrinks or changes about its middle, not about the start of its baseline: a name centred on a plate stays
    /// centred when it is made smaller to fit. Its start moves, and so do the two dimensions that pin it.
    static func keepTextCentres(from old: Sketch, in new: inout Sketch, values: ParameterValues) {
        for text in new.texts {
            guard let before = old.texts.first(where: { $0.id == text.id }), before.height != text.height || before.text != text.text,
                  let h0 = try? values.value(of: before.height, kind: .length), let h1 = try? values.value(of: text.height, kind: .length),
                  let c0 = textCentre(before, height: h0), let c1 = textCentre(text, height: h1),
                  let at = new.points.firstIndex(where: { $0.id == text.position }) else { continue }
            let shift = c0 - c1
            new.points[at].x += shift.x
            new.points[at].y += shift.y
            let moved = SIMD2(new.points[at].x, new.points[at].y)
            for (suffix, value) in [("x", moved.x), ("y", moved.y)] {
                if let d = new.dimensions.firstIndex(where: { $0.id == "\(text.id).\(suffix)" }) {
                    new.dimensions[d].expression = magnitude(AIValues.number(value) + " mm", value)
                }
            }
        }
    }

    /// An exactly level or upright line gets the constraint that keeps it so.
    private static func addAlignment(_ line: EntityID, _ a: SIMD2<Double>, _ b: SIMD2<Double>, in sk: inout Sketch) {
        if abs(a.y - b.y) < 1e-9 { sk.constrain(.horizontal(line)) } else if abs(a.x - b.x) < 1e-9 { sk.constrain(.vertical(line)) }
    }

    /// The centre of the circle through three points, and whether going from the first to the last through the middle one turns
    /// counter-clockwise; nil if they are on a line.
    static func circumcircle(_ a: SIMD2<Double>, _ m: SIMD2<Double>, _ b: SIMD2<Double>) -> (SIMD2<Double>, Bool)? {
        let d = 2 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
        guard abs(d) > 1e-9 else { return nil }
        func sq(_ p: SIMD2<Double>) -> Double { p.x * p.x + p.y * p.y }
        let ux = (sq(a) * (m.y - b.y) + sq(m) * (b.y - a.y) + sq(b) * (a.y - m.y)) / d
        let uy = (sq(a) * (b.x - m.x) + sq(m) * (a.x - b.x) + sq(b) * (m.x - a.x)) / d
        let cross = (m.x - a.x) * (b.y - a.y) - (m.y - a.y) * (b.x - a.x)  // > 0: a, m, b turn clockwise round the middle, as seen from the arc
        return (SIMD2(ux, uy), cross < 0)
    }
}

// 2D sketch model: points, curves, geometric constraints and driving dimensions.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Stable identifier of a sketch entity or feature. Never changes once created, so
/// persistent names built from it ("plate.side.<id>") survive every edit.
public typealias EntityID = String

public enum IDs {
    public static func make() -> EntityID {
        String(UInt32.random(in: 0...UInt32.max), radix: 16).leftPadded(to: 8)
    }
}

extension String {
    func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

public struct SketchPoint: Codable, Hashable, Sendable, Identifiable {
    public var id: EntityID
    public var x: Double
    public var y: Double
    /// Fixed points are not moved by the solver (e.g. the sketch origin).
    public var fixed: Bool

    public init(id: EntityID = IDs.make(), x: Double, y: Double, fixed: Bool = false) {
        self.id = id; self.x = x; self.y = y; self.fixed = fixed
    }
    public var position: SIMD2<Double> { SIMD2(x, y) }
}

public struct SketchCurve: Codable, Hashable, Sendable, Identifiable {
    public enum Geometry: Codable, Hashable, Sendable {
        case line(start: EntityID, end: EntityID)
        case circle(center: EntityID, radius: Double)
        /// Counter-clockwise from start to end; the solver keeps |center-start| == |center-end|.
        case arc(center: EntityID, start: EntityID, end: EntityID)
    }
    public var id: EntityID
    public var geometry: Geometry
    /// Construction geometry is solved but never becomes part of a profile.
    public var construction: Bool

    public init(id: EntityID = IDs.make(), _ geometry: Geometry, construction: Bool = false) {
        self.id = id; self.geometry = geometry; self.construction = construction
    }
}

public struct SketchConstraint: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        case coincident(EntityID, EntityID)           // point, point
        case horizontal(EntityID)                     // line
        case vertical(EntityID)                       // line
        case parallel(EntityID, EntityID)             // line, line
        case perpendicular(EntityID, EntityID)        // line, line
        case equal(EntityID, EntityID)                // line/line length or circle/arc radius
        case tangent(EntityID, EntityID)              // line or circle/arc, circle/arc
        case pointOnCurve(point: EntityID, curve: EntityID)
        case midpoint(point: EntityID, line: EntityID)
        case fix(EntityID, x: Double, y: Double)      // point
    }
    public var id: EntityID
    public var kind: Kind
    public init(id: EntityID = IDs.make(), _ kind: Kind) { self.id = id; self.kind = kind }
}

public struct SketchDimension: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        case distance(EntityID, EntityID)             // point–point
        case horizontalDistance(EntityID, EntityID)   // point–point, along sketch x
        case verticalDistance(EntityID, EntityID)     // point–point, along sketch y
        case pointLineDistance(point: EntityID, line: EntityID)
        case length(EntityID)                         // line
        case radius(EntityID)                         // circle/arc
        case diameter(EntityID)                       // circle/arc
        case angle(EntityID, EntityID)                // line, line: counter-clockwise from first to second
        case radialOffset(from: EntityID, to: EntityID)  // circle/arc radii difference (concentric offsets)
    }
    public var id: EntityID
    public var kind: Kind
    /// Driving value as an expression, e.g. "width / 2".
    public var expression: String

    public init(id: EntityID = IDs.make(), _ kind: Kind, _ expression: String) {
        self.id = id; self.kind = kind; self.expression = expression
    }
    public var unitKind: UnitKind {
        if case .angle = kind { return .angle }
        return .length
    }
}

/// Text in a sketch: its letters' outlines become sketch profiles (e.g. to extrude or cut).
public struct SketchText: Codable, Hashable, Sendable, Identifiable {
    public var id: EntityID
    public var text: String
    /// Where the text starts: a sketch point on the baseline, so it can be dragged and constrained.
    public var position: EntityID
    /// Height of the capital letters, as an expression ("10 mm").
    public var height: String
    /// PostScript name of the font ("Helvetica-Bold").
    public var font: String
    public init(id: EntityID = IDs.make(), text: String, position: EntityID, height: String = "10 mm",
                font: String = SketchText.defaultFont) {
        self.id = id; self.text = text; self.position = position; self.height = height; self.font = font
    }
    public static let defaultFont = "Helvetica-Bold"
}

public struct Sketch: Codable, Hashable, Sendable {
    public var points: [SketchPoint] = []
    public var curves: [SketchCurve] = []
    public var constraints: [SketchConstraint] = []
    public var dimensions: [SketchDimension] = []
    public var texts: [SketchText] = []

    private enum CodingKeys: String, CodingKey { case points, curves, constraints, dimensions, texts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([SketchPoint].self, forKey: .points)
        curves = try c.decode([SketchCurve].self, forKey: .curves)
        constraints = try c.decode([SketchConstraint].self, forKey: .constraints)
        dimensions = try c.decode([SketchDimension].self, forKey: .dimensions)
        texts = try c.decodeIfPresent([SketchText].self, forKey: .texts) ?? []  // older files have none
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(curves, forKey: .curves)
        try c.encode(constraints, forKey: .constraints)
        try c.encode(dimensions, forKey: .dimensions)
        if !texts.isEmpty { try c.encode(texts, forKey: .texts) }
    }

    /// Every sketch starts with a fixed origin point, id "origin".
    public init() { points.append(SketchPoint(id: "origin", x: 0, y: 0, fixed: true)) }

    public func point(_ id: EntityID) -> SketchPoint? { points.first { $0.id == id } }
    public func curve(_ id: EntityID) -> SketchCurve? { curves.first { $0.id == id } }

    // MARK: building helpers (used by tools and the demo document)

    @discardableResult
    public mutating func addPoint(_ x: Double, _ y: Double, id: EntityID = IDs.make()) -> EntityID {
        points.append(SketchPoint(id: id, x: x, y: y)); return id
    }

    @discardableResult
    public mutating func addLine(_ a: EntityID, _ b: EntityID, id: EntityID = IDs.make(), construction: Bool = false) -> EntityID {
        curves.append(SketchCurve(id: id, .line(start: a, end: b), construction: construction)); return id
    }

    @discardableResult
    public mutating func addCircle(center: EntityID, radius: Double, id: EntityID = IDs.make()) -> EntityID {
        curves.append(SketchCurve(id: id, .circle(center: center, radius: radius))); return id
    }

    @discardableResult
    public mutating func addArc(center: EntityID, start: EntityID, end: EntityID, id: EntityID = IDs.make()) -> EntityID {
        curves.append(SketchCurve(id: id, .arc(center: center, start: start, end: end))); return id
    }

    public mutating func constrain(_ kind: SketchConstraint.Kind) { constraints.append(SketchConstraint(kind)) }

    public mutating func dimension(_ kind: SketchDimension.Kind, _ expression: String, id: EntityID = IDs.make()) {
        dimensions.append(SketchDimension(id: id, kind, expression))
    }

    /// Axis-aligned rectangle from corner (x0, y0) to (x1, y1): four lines, shared corners,
    /// horizontal/vertical constraints. Returns the line ids (bottom, right, top, left) and corner ids.
    @discardableResult
    public mutating func addRectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                                      lineIDs: [EntityID]? = nil) -> (lines: [EntityID], corners: [EntityID]) {
        let c = [addPoint(x0, y0), addPoint(x1, y0), addPoint(x1, y1), addPoint(x0, y1)]
        let ids = lineIDs ?? (0..<4).map { _ in IDs.make() }
        let l = (0..<4).map { addLine(c[$0], c[($0 + 1) % 4], id: ids[$0]) }
        constrain(.horizontal(l[0])); constrain(.vertical(l[1]))
        constrain(.horizontal(l[2])); constrain(.vertical(l[3]))
        return (l, c)
    }

    /// Circle/arc radius as currently stored in the geometry.
    public func radius(of curve: SketchCurve) -> Double? {
        switch curve.geometry {
        case .line: return nil
        case .circle(_, let r): return r
        case .arc(let c, let s, _):
            guard let pc = point(c), let ps = point(s) else { return nil }
            return vlen(ps.position - pc.position)
        }
    }
}

@inline(__always) func vlen(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
@inline(__always) func vcross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
@inline(__always) func vdot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }

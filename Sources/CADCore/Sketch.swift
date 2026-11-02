// 2D sketch model: points, curves, geometric constraints and driving dimensions.
// Copyright © 2026 Atle Mo
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
        /// Cubic Bézier from `start` to `end`, pulled toward the two control points (its handles).
        case bezier(start: EntityID, control1: EntityID, control2: EntityID, end: EntityID)
        /// Ellipse: its center, and the ends of its two axes (points on the curve). Point t is center + major·cos t + minor·sin t.
        case ellipse(center: EntityID, major: EntityID, minor: EntityID)
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
        case symmetric(EntityID, EntityID, line: EntityID)  // point, point: mirror images across the line
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
        case supplementAngle(EntityID, EntityID)      // line, line: 180° less that counter-clockwise angle (the other wedge at the same corner)
        case arcAngle(EntityID)                       // arc: how far it sweeps, counter-clockwise from its start to its end
        case lineAngle(EntityID)                      // line: its angle to the sketch's x-axis, 0° to 180°; the line stays on the side (above or below) it is on
        case radialOffset(from: EntityID, to: EntityID)  // circle/arc radii difference (concentric offsets)
        /// Clear space from a circle's or arc's rim (first) to a point, a line, or another circle or arc's rim.
        case gap(EntityID, EntityID)
    }
    public var id: EntityID
    public var kind: Kind
    /// Whether this measures how far an arc sweeps.
    public var isArcAngle: Bool { if case .arcAngle = kind { return true }; return false }
    /// Whether this measures an angle between two lines (either reading of the pair).
    public var isAngle: Bool { if case .angle = kind { return true }; if case .supplementAngle = kind { return true }; return false }
    /// Driving value as an expression, e.g. "width / 2".
    public var expression: String
    /// Where the dimension line is drawn (see Sketch.dimensionLine): how far it stands from what it
    /// measures, in mm, or for a circle's radius or diameter the angle of its line in radians.
    /// Nil until it is moved: it then sits on the measured points (a circle's goes up and to the right).
    public var offset: Double?
    /// For an angle: the direction, in radians from its corner, of the middle of the arc it was placed on. Nil until
    /// placed: the arc then takes the wedge the lines make by default. Kept so the arc stays on its wedge when the lines move.
    public var wedge: Double?

    public init(id: EntityID = IDs.make(), _ kind: Kind, _ expression: String, offset: Double? = nil) {
        self.id = id; self.kind = kind; self.expression = expression; self.offset = offset
    }
    public var unitKind: UnitKind {
        switch kind {
        case .angle, .supplementAngle, .lineAngle, .arcAngle: return .angle
        default: return .length
        }
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
    /// How far the baseline is turned counter-clockwise about the anchor, in radians.
    public var angle: Double
    public init(id: EntityID = IDs.make(), text: String, position: EntityID, height: String = "10 mm",
                font: String = SketchText.defaultFont, angle: Double = 0) {
        self.id = id; self.text = text; self.position = position; self.height = height; self.font = font; self.angle = angle
    }

    private enum CodingKeys: String, CodingKey { case id, text, position, height, font, angle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        position = try c.decode(EntityID.self, forKey: .position)
        height = try c.decode(String.self, forKey: .height)
        font = try c.decode(String.self, forKey: .font)
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0  // older files: level
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(position, forKey: .position)
        try c.encode(height, forKey: .height)
        try c.encode(font, forKey: .font)
        if angle != 0 { try c.encode(angle, forKey: .angle) }
    }
    public static let defaultFont = "Helvetica-Bold"
}

/// An edge of the model brought into the sketch: two fixed points and a construction line
/// between them (for a circular edge: its fixed center and ends, and a construction arc or circle), put back where
/// the edge is on every rebuild. Other geometry constrained to them
/// (a corner on the line, a point coincident with an end) follows the model when it changes.
public struct SketchProjection: Codable, Hashable, Sendable, Identifiable {
    public var id: EntityID
    public var edge: EdgeRef
    /// The edge's two ends, as fixed sketch points.
    public var start: EntityID
    public var end: EntityID
    /// The construction line between them, or the construction arc or circle of a circular edge. (A full circle has
    /// one point on it, which is both `start` and `end`.)
    public var line: EntityID
    /// The fixed center point of a circular edge; nil for a straight one.
    public var center: EntityID?
    public init(id: EntityID = IDs.make(), edge: EdgeRef, start: EntityID, end: EntityID, line: EntityID, center: EntityID? = nil) {
        self.id = id; self.edge = edge; self.start = start; self.end = end; self.line = line; self.center = center
    }
}

public struct Sketch: Codable, Hashable, Sendable {
    public var points: [SketchPoint] = []
    public var curves: [SketchCurve] = []
    public var constraints: [SketchConstraint] = []
    public var dimensions: [SketchDimension] = []
    public var texts: [SketchText] = []
    /// Model edges this sketch follows (see SketchProjection).
    public var projections: [SketchProjection] = []
    /// Patterns of the sketch's own geometry; their copies are generated (see SketchPattern.swift).
    public var patterns: [SketchPatternDef] = []
    /// Gears of the sketch; their outlines are generated (see GearProfile.swift).
    public var gears: [SketchGearDef] = []
    /// Mirror images of the sketch's own geometry across a line; the images are generated (see SketchMirror.swift).
    public var mirrors: [SketchMirrorDef] = []

    private enum CodingKeys: String, CodingKey { case points, curves, constraints, dimensions, texts, projections, patterns, gears, mirrors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([SketchPoint].self, forKey: .points)
        curves = try c.decode([SketchCurve].self, forKey: .curves)
        constraints = try c.decode([SketchConstraint].self, forKey: .constraints)
        dimensions = try c.decode([SketchDimension].self, forKey: .dimensions)
        texts = try c.decodeIfPresent([SketchText].self, forKey: .texts) ?? []  // older files have none
        projections = try c.decodeIfPresent([SketchProjection].self, forKey: .projections) ?? []
        patterns = try c.decodeIfPresent([SketchPatternDef].self, forKey: .patterns) ?? []
        gears = try c.decodeIfPresent([SketchGearDef].self, forKey: .gears) ?? []
        mirrors = try c.decodeIfPresent([SketchMirrorDef].self, forKey: .mirrors) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(curves, forKey: .curves)
        try c.encode(constraints, forKey: .constraints)
        try c.encode(dimensions, forKey: .dimensions)
        if !texts.isEmpty { try c.encode(texts, forKey: .texts) }
        if !projections.isEmpty { try c.encode(projections, forKey: .projections) }
        if !patterns.isEmpty { try c.encode(patterns, forKey: .patterns) }
        if !gears.isEmpty { try c.encode(gears, forKey: .gears) }
        if !mirrors.isEmpty { try c.encode(mirrors, forKey: .mirrors) }
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

    @discardableResult
    public mutating func addBezier(start: EntityID, control1: EntityID, control2: EntityID, end: EntityID,
                                   id: EntityID = IDs.make(), construction: Bool = false) -> EntityID {
        curves.append(SketchCurve(id: id, .bezier(start: start, control1: control1, control2: control2, end: end),
                                  construction: construction))
        return id
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
        case .line, .bezier, .ellipse: return nil
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

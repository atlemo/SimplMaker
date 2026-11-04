// Sections: sketches drawn on parallel planes along an axis, one per station. create_sections makes them from a slice of a body (the
// way to start rebuilding an imported mesh), and create_loft can take stations inline (planes, sketches and the loft in one step).
// Both draw each outline as closed polylines, so the result is ordinary planes and sketches that can be edited by hand.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// One station of a section loft: where it is along the axis, and its outlines: the outer outline first, then any holes.
struct SectionStation: Sendable {
    /// A number (mm) or an expression, along the axis.
    var offset: String
    var loops: [[SketchPoint2]]
}

enum SectionSketches {
    /// The most corners one outline may have: a longer one is a mesh that wants a bigger tolerance.
    static let maxCorners = 400
    static let maxStations = 60

    static func axisIndex(_ text: String) throws -> Int {
        guard let axis = ["x", "y", "z"].firstIndex(of: text.lowercased()) else {
            throw AIError(.invalidArguments, "axis \"\(text)\" is not one of x, y, z.",
                          reason: "The sections lie in planes square to this axis: \"x\" for sections across a part's length along X.")
        }
        return axis
    }

    /// The plane the sections lie on, and the factor that turns a position along the axis into its offset: the "xz" plane's normal
    /// points to -Y, so a section at y = 5 is 5 mm along it the other way.
    static func plane(for axis: Int) -> (ref: PlaneRef, sign: Double) {
        switch axis {
        case 0: return (.yz, 1)
        case 1: return (.xz, -1)
        default: return (.xy, 1)
        }
    }

    /// The text for a plane's offset: the position along the axis, signed for the plane's normal.
    static func offsetText(_ position: String, sign: Double) -> String {
        if sign > 0 { return Double(position).map { AIValues.number($0) + " mm" } ?? position }
        if let n = Double(position) { return AIValues.number(-n) + " mm" }
        return "-(\(position))"
    }

    /// Adds a plane at `station.offset` along the axis and a sketch on it with the station's outlines as closed polylines ("loop1",
    /// "loop2"…). Returns the point inside the outer outline (clear of any hole) that picks its profile.
    @MainActor
    @discardableResult
    static func add(station: SectionStation, axis: Int, planeID: String, sketchID: String, index: Int, doc: inout CADDocument,
                    context: OperationContext) throws -> SIMD2<Double> {
        guard !station.loops.isEmpty else {
            throw AIError(.invalidArguments, "Station \(index) has no outline.", reason: "Each station needs at least one closed outline of 3 or more points.")
        }
        for (n, loop) in station.loops.enumerated() where loop.count < 3 {
            throw AIError(.invalidArguments, "Station \(index), outline \(n + 1) has \(loop.count) points.", reason: "A closed outline needs at least 3 points.")
        }
        for (n, loop) in station.loops.enumerated() where loop.count > maxCorners {
            throw AIError(.invalidArguments, "Station \(index), outline \(n + 1) has \(loop.count) points (at most \(maxCorners)).",
                          reason: "Raise the tolerance: a rough outline needs far fewer corners.")
        }
        let (base, sign) = plane(for: axis)
        let offset = offsetText(station.offset, sign: sign)
        _ = try AIValues.evaluate(offset, kind: .length, field: "stations[\(index - 1)].offset", positive: false, values: context.values)
        guard !doc.features.contains(where: { $0.id == planeID || $0.id == sketchID }) else {
            throw AIError(.invalidArguments, "The ids \(planeID) and \(sketchID) are already used by features.", reason: "Pick another id prefix.")
        }
        doc.addFeature(Feature(id: planeID, name: "Section \(index) plane", .plane(PlaneFeature(base: base, offset: offset))))
        doc.addFeature(Feature(id: sketchID, name: "Section \(index)", .sketch(SketchFeature(plane: .plane(planeID), sketch: Sketch()))))
        let shapes = station.loops.enumerated().map { n, loop in SketchShape.polyline(id: "loop\(n + 1)", points: loop, closed: true) }
        _ = try EditSketchOperation(sketchID: sketchID, add: shapes, sketchName: "Section \(index)").apply(to: &doc, context: context)
        let numbers = try station.loops.map { loop in
            try loop.map { SIMD2(try SketchBuilder.value($0.x, "point.x", context.values), try SketchBuilder.value($0.y, "point.y", context.values)) }
        }
        return interiorPoint(of: numbers)
    }

    /// A point inside the first (outer) outline and outside the others (its holes), found along a horizontal line through the middle.
    static func interiorPoint(of loops: [[SIMD2<Double>]]) -> SIMD2<Double> {
        guard let outer = loops.first, !outer.isEmpty else { return .zero }
        let lo = outer.reduce(SIMD2<Double>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = outer.reduce(SIMD2<Double>(repeating: -.infinity)) { simd_max($0, $1) }
        // A few heights through the outline: the first where the line crosses cleanly gives the point.
        for fraction in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8] {
            let y = lo.y + (hi.y - lo.y) * fraction
            var xs: [Double] = []
            for loop in loops {
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    if (a.y - y) * (b.y - y) < 0 { xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
                }
            }
            xs.sort()
            if xs.count >= 2 { return SIMD2((xs[0] + xs[1]) / 2, y) }
        }
        return SIMD2((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
    }
}

// MARK: create_sections

struct CreateSectionsOperation: AIOperation {
    let body: String
    let axis: String
    let offsets: [Double]
    let tolerance: Double
    /// Ids are "<id>_p1", "<id>_s1", "<id>_p2"…
    let id: String
    var toolName: String { "create_sections" }
    var label: String { "Create sections of \(body)" }
    var activity: String { "Drawing sections of \(body)" }

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        let axisIndex = try SectionSketches.axisIndex(axis)
        guard !offsets.isEmpty, offsets.count <= SectionSketches.maxStations, offsets.allSatisfy(\.isFinite) else {
            throw AIError(.invalidArguments, "Send between 1 and \(SectionSketches.maxStations) offsets (finite numbers, mm).",
                          reason: "Either offsets: [..], or from, to and count for evenly spaced stations.")
        }
        guard tolerance.isFinite, tolerance >= 0 else { throw AIError(.invalidArguments, "tolerance must be 0 or more (mm).") }
        guard let kernelBody = context.built.body(body) else {
            let known = context.built.bodies.map(\.id).joined(separator: ", ")
            throw AIError(.featureNotFound, "There is no body with the id \(body).", reason: known.isEmpty ? "The part has no bodies yet." : "The bodies are: \(known).")
        }
        guard id.range(of: #"^[A-Za-z0-9_-]{1,30}$"#, options: .regularExpression) != nil else {
            throw AIError(.invalidArguments, "id \"\(id)\" is not allowed.", reason: "Use 1 to 30 letters, digits, underscores or hyphens; it starts the ids of the planes and sketches.")
        }
        let mesh: Mesh
        do { mesh = try kernelBody.tessellate(linearDeflection: 0.01, angularDeflection: 0.2) } catch {
            throw AIError(.invalidValue, "\(body) could not be sliced: \(error).", reason: "Try another body.")
        }
        var made: [JSONValue] = []
        var skipped: [Double] = []
        var number = 0
        for offset in offsets {
            let loops = BodySlicer.slice(mesh, axis: axisIndex, offset: offset, tolerance: tolerance).filter(\.closed)
            guard !loops.isEmpty else { skipped.append(offset); continue }
            number += 1
            let station = SectionStation(offset: AIValues.number(offset),
                                         loops: loops.map { $0.points.map { SketchPoint2(x: AIValues.number($0.x), y: AIValues.number($0.y)) } })
            try SectionSketches.add(station: station, axis: axisIndex, planeID: "\(id)_p\(number)", sketchID: "\(id)_s\(number)", index: number,
                                    doc: &doc, context: context)
            let shape = BodySlicer.shape(of: loops)
            var info: [String: JSONValue] = ["sketch_id": .string("\(id)_s\(number)"), "plane_id": .string("\(id)_p\(number)"),
                                             "offset": .double(offset), "outlines": .int(loops.count), "corners": .int(loops.map(\.points.count).reduce(0, +))]
            if let shape { info["area"] = .double(CADService.round(shape.area, places: 1e3)) }
            made.append(.object(info))
        }
        guard number > 0 else {
            throw AIError(.invalidValue, "The plane misses \(body) at every offset given.", reason: "slice_body's body_range says how far the body reaches along the axis.")
        }
        let (u, v) = BodySlicer.planeAxes(axisIndex)
        let names = ["x", "y", "z"]
        var message = "Made \(number) section\(number == 1 ? "" : "s") of \(body) across \(axis.lowercased()): planes \(id)_p1… and sketches \(id)_s1…, drawn in (\(names[u]), \(names[v])) as closed polylines. Loft them with create_loft (sections [{\"sketch_id\": \"\(id)_s1\", \"profile\": \"solid\"}, …]) or read them with get_feature."
        if !skipped.isEmpty { message += " No section at \(skipped.map { AIValues.number($0) }.joined(separator: ", ")): the plane misses the body there." }
        return OperationOutcome(featureID: "\(id)_s\(number)", message: message, created: ["sections": .array(made)])
    }
}

extension CreateLoftOperation {
    /// The loft's sections made from stations given inline: planes and sketches are added, and the profile of each is the area inside the outer outline.
    func sectionsFromStations(_ stations: [SectionStation], axis: String, doc: inout CADDocument, context: OperationContext) throws -> [LoftSection] {
        let axisIndex = try SectionSketches.axisIndex(axis)
        guard stations.count >= 2, stations.count <= SectionSketches.maxStations else {
            throw AIError(.invalidArguments, "A loft needs between 2 and \(SectionSketches.maxStations) stations (it has \(stations.count)).")
        }
        let prefix = id?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "loft"
        var sections: [LoftSection] = []
        for (n, station) in stations.enumerated() {
            let sketchID = "\(prefix)_s\(n + 1)"
            let inside = try SectionSketches.add(station: station, axis: axisIndex, planeID: "\(prefix)_p\(n + 1)", sketchID: sketchID, index: n + 1,
                                                 doc: &doc, context: context)
            sections.append(LoftSection(sketch: sketchID, profile: ProfileRef(curves: [], hintU: inside.x, hintV: inside.y)))
        }
        return sections
    }
}

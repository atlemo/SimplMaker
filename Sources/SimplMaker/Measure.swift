// The Measure tool (Inspect group): click a face, an edge or a body for its size, or two of them for the
// distance and angle between. This file holds the readout (what is measured and how it reads), the
// tool's hooks into the document model, and the panel that shows it.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd
import SwiftUI

// MARK: - the readout

/// How lengths, areas and angles read: millimetres, or inches in a US unit system.
struct MeasureUnits: Equatable {
    var us = false

    private func trimmed(_ v: Double, _ decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", abs(v) < 0.5 * pow(10, -Double(decimals)) ? 0 : v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// A number of mm (or, in a US system, of inches) with its unit.
    func length(_ mm: Double) -> String { us ? trimmed(mm / 25.4, 4) + " in" : trimmed(mm, 3) + " mm" }
    func area(_ mm2: Double) -> String { us ? trimmed(mm2 / 645.16, 4) + " in²" : trimmed(mm2, 2) + " mm²" }
    func volume(_ mm3: Double) -> String {
        if us { return trimmed(mm3 / 16387.064, 4) + " in³" }
        return mm3 >= 1000 ? trimmed(mm3, 1) + " mm³ (" + trimmed(mm3 / 1000, 2) + " cm³)" : trimmed(mm3, 2) + " mm³"
    }
    func angle(_ radians: Double) -> String { trimmed(radians * 180 / .pi, 2) + "°" }
    /// A point or a vector: "(x, y, z)" in the unit, no unit written.
    func point(_ p: SIMD3<Double>) -> String {
        let f = { (v: Double) in trimmed(us ? v / 25.4 : v, us ? 4 : 3) }
        return "(\(f(p.x)), \(f(p.y)), \(f(p.z)))"
    }
    /// A direction: "(x, y, z)" as a unit vector.
    func direction(_ d: SIMD3<Double>) -> String { "(" + [d.x, d.y, d.z].map { trimmed($0, 3) }.joined(separator: ", ") + ")" }
}

struct MeasureRow: Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

struct MeasureSection: Equatable, Identifiable {
    var title: String
    var rows: [MeasureRow]
    var id: String { title }
}

/// What the Measure tool shows for what is picked: sections of rows for the panel, and a line and labels
/// drawn in the viewport.
struct MeasureReadout: Equatable {
    var sections: [MeasureSection] = []
    /// The shortest line between two picked pieces (nil for one piece, or pieces that touch).
    var line: (from: SIMD3<Double>, to: SIMD3<Double>)?
    /// Short readouts on the model: where, and what it says.
    var labels: [(at: SIMD3<Double>, text: String)] = []

    static func == (a: MeasureReadout, b: MeasureReadout) -> Bool {
        a.sections == b.sections && a.line?.from == b.line?.from && a.line?.to == b.line?.to
            && a.labels.map(\.text) == b.labels.map(\.text) && a.labels.map(\.at) == b.labels.map(\.at)
    }

    /// The panel's text as plain lines, for copying.
    var text: String {
        sections.map { s in ([s.title] + s.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n") }.joined(separator: "\n\n")
    }
}

/// A picked piece, measured.
struct MeasuredPiece {
    var title: String
    var measure: KMeasure
}

enum MeasureReport {
    /// The readout for one or two measured pieces (and the shortest distance between two).
    static func report(_ pieces: [MeasuredPiece], distance: KDistance?, units: MeasureUnits) -> MeasureReadout {
        var out = MeasureReadout()
        if pieces.count == 2 {
            out.sections.append(MeasureSection(title: "Between", rows: between(pieces[0].measure, pieces[1].measure, distance, units)))
            if let d = distance, d.distance > 1e-9 {
                out.line = (d.a, d.b)
                out.labels = [((d.a + d.b) / 2, units.length(d.distance))]
            }
        }
        for (i, p) in pieces.enumerated() {
            let title = pieces.count == 2 ? "\(i == 0 ? "First" : "Second"): \(p.title)" : p.title
            out.sections.append(MeasureSection(title: title, rows: rows(for: p.measure, units)))
            if pieces.count == 1, let label = label(for: p.measure, units) { out.labels = [label] }
        }
        return out
    }

    /// What kind of piece it is, for a section's title.
    static func kind(_ m: KMeasure) -> String {
        switch m.geometry {
        case .body: return "Body"
        case .plane: return "Flat face"
        case .cylinder: return "Cylindrical face"
        case .cone: return "Conical face"
        case .sphere: return "Spherical face"
        case .torus: return "Toroidal face"
        case .line: return "Straight edge"
        case .circle: return "Circular edge"
        case .arc: return "Arc edge"
        case .other: return m.ends == nil ? "Curved face" : "Curved edge"
        }
    }

    // MARK: one piece

    static func rows(for m: KMeasure, _ u: MeasureUnits) -> [MeasureRow] {
        var r: [MeasureRow] = []
        func add(_ label: String, _ value: String) { r.append(MeasureRow(label: label, value: value)) }
        func round(diameter: Bool = true) {
            if diameter { add("Diameter", u.length(2 * m.radius)) }
            add("Radius", u.length(m.radius))
        }
        switch m.geometry {
        case .body:
            add("Volume", u.volume(m.volume))
            add("Surface area", u.area(m.size))
            add("Size", extent(m, u))
        case .plane:
            add("Area", u.area(m.size))
            add("Perimeter", u.length(m.perimeter))
            add("Size", extent(m, u))
            if let n = m.direction { add("Normal", u.direction(n)) }
        case .cylinder:
            round()
            add("Length", u.length(m.length))
            add("Area", u.area(m.size))
            if let a = m.direction { add("Axis", u.direction(a)) }
        case .cone:
            add("Radius at start", u.length(m.radius))
            add("Radius at end", u.length(m.radius2))
            add("Half angle", u.angle(m.angle))
            add("Length", u.length(m.length))
            add("Area", u.area(m.size))
        case .sphere:
            round()
            add("Area", u.area(m.size))
            if let c = m.center { add("Centre", u.point(c)) }
        case .torus:
            add("Major radius", u.length(m.radius))
            add("Tube radius", u.length(m.radius2))
            add("Area", u.area(m.size))
        case .line:
            add("Length", u.length(m.size))
            if let e = m.ends {
                let d = e.end - e.start
                add("Along", "ΔX \(u.length(abs(d.x))) · ΔY \(u.length(abs(d.y))) · ΔZ \(u.length(abs(d.z)))")
                add("Start", u.point(e.start))
                add("End", u.point(e.end))
            }
        case .circle:
            round()
            add("Length", u.length(m.size))
            if let c = m.center { add("Centre", u.point(c)) }
        case .arc:
            round()
            add("Angle", u.angle(m.angle))
            add("Length", u.length(m.size))
            if let c = m.center { add("Centre", u.point(c)) }
        case .other:
            if m.ends != nil {
                add("Length", u.length(m.size))
            } else {
                add("Area", u.area(m.size))
                add("Perimeter", u.length(m.perimeter))
                add("Size", extent(m, u))
            }
        }
        return r
    }

    /// The size along each world axis: "X 20 mm · Y 10 mm", leaving out an axis a flat piece has no size along.
    static func extent(_ m: KMeasure, _ u: MeasureUnits) -> String {
        let e = m.extent
        let parts = zip(["X", "Y", "Z"], [e.x, e.y, e.z]).filter { $0.1 > 1e-6 }.map { "\($0.0) \(u.length($0.1))" }
        return parts.isEmpty ? u.length(0) : parts.joined(separator: " · ")
    }

    /// The short readout drawn on the model for a single piece.
    static func label(for m: KMeasure, _ u: MeasureUnits) -> (at: SIMD3<Double>, text: String)? {
        switch m.geometry {
        case .line: return m.ends.map { (($0.start + $0.end) / 2, u.length(m.size)) }
        case .circle: return m.center.map { ($0, "Ø " + u.length(2 * m.radius)) }
        case .arc: return m.center.map { ($0, "R " + u.length(m.radius)) }
        case .cylinder, .sphere: return (m.centroid, "Ø " + u.length(2 * m.radius))
        case .plane, .cone, .torus: return (m.centroid, u.area(m.size))
        case .other: return m.ends == nil ? (m.centroid, u.area(m.size)) : (m.centroid, u.length(m.size))
        case .body: return nil
        }
    }

    // MARK: two pieces

    static func between(_ a: KMeasure, _ b: KMeasure, _ distance: KDistance?, _ u: MeasureUnits) -> [MeasureRow] {
        var r: [MeasureRow] = []
        func add(_ label: String, _ value: String) { r.append(MeasureRow(label: label, value: value)) }
        if let d = distance {
            add("Shortest distance", u.length(d.distance))
            if d.distance > 1e-9 {
                let v = d.b - d.a
                add("ΔX", u.length(abs(v.x)))
                add("ΔY", u.length(abs(v.y)))
                add("ΔZ", u.length(abs(v.z)))
            }
        }
        if let da = a.direction, let db = b.direction, let text = angleText(da, db) { add("Angle", text) }
        if a.geometry == .plane, b.geometry == .plane, let na = a.direction, let nb = b.direction,
           abs(simd_dot(simd_normalize(na), simd_normalize(nb))) > 1 - 1e-9 {
            add("Between the planes", u.length(abs(simd_dot(b.centroid - a.centroid, simd_normalize(na)))))
        }
        if let d = axisDistance(a, b) { add(d.label, u.length(d.value)) }
        if let ca = trueCenter(a), let cb = trueCenter(b) { add("Centre to centre", u.length(simd_length(cb - ca))) }
        return r
    }

    /// The angle between two directions as "45° / 135°" (a line has no sense, so both ways round), or
    /// "parallel" and "perpendicular".
    static func angleText(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> String? {
        guard simd_length(a) > 1e-12, simd_length(b) > 1e-12 else { return nil }
        let c = min(abs(simd_dot(simd_normalize(a), simd_normalize(b))), 1)
        let acute = acos(c) * 180 / .pi
        func f(_ v: Double) -> String { MeasureUnits().angle(v * .pi / 180) }
        if acute < 1e-6 { return "0° (parallel)" }
        if abs(acute - 90) < 1e-6 { return "90° (perpendicular)" }
        return "\(f(acute)) / \(f(180 - acute))"
    }

    private static func trueCenter(_ m: KMeasure) -> SIMD3<Double>? {
        switch m.geometry {
        case .sphere, .circle, .arc, .torus: return m.center
        default: return nil
        }
    }

    private static func axis(_ m: KMeasure) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        switch m.geometry {
        case .circle, .arc, .cylinder, .cone, .torus:
            guard let c = m.center, let d = m.direction, simd_length(d) > 1e-12 else { return nil }
            return (c, simd_normalize(d))
        default: return nil
        }
    }

    private static func distance(_ p: SIMD3<Double>, toAxis a: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> Double {
        let v = p - a.origin
        return simd_length(v - simd_dot(v, a.direction) * a.direction)
    }

    /// Hole spacing and the like: the distance between two axes that run side by side, or from a centre to an axis.
    static func axisDistance(_ a: KMeasure, _ b: KMeasure) -> (label: String, value: Double)? {
        if let x = axis(a), let y = axis(b) {
            guard abs(simd_dot(x.direction, y.direction)) > 1 - 1e-9 else { return nil }  // only parallel axes keep one distance
            return ("Axis to axis", distance(y.origin, toAxis: x))
        }
        if let x = axis(a), b.geometry == .sphere, let c = b.center { return ("Centre to axis", distance(c, toAxis: x)) }
        if let y = axis(b), a.geometry == .sphere, let c = a.center { return ("Centre to axis", distance(c, toAxis: y)) }
        return nil
    }
}

// MARK: - the tool

/// A picked piece of a body: which body (its feature id) and what part of it.
struct MeasureTarget: Hashable {
    var body: FeatureID
    var piece: KPiece
}

extension DocumentModel {
    /// The pieces picked for the Measure tool, at most two, as the kernel knows them.
    var measureTargets: [MeasureTarget] {
        selection.prefix(2).compactMap { pick in
            guard pick.isFace || pick.isEdge, pick.body >= 0, pick.body < meshes.count else { return nil }
            let m = meshes[pick.body]
            if pick.isWholeBody { return MeasureTarget(body: m.id, piece: .body) }
            guard let name = name(of: pick) else { return nil }
            return MeasureTarget(body: m.id, piece: pick.isEdge ? .edge(name) : .face(name))
        }
    }

    /// What the Measure tool reads out for the picks (nil when nothing is picked or measuring fails).
    var measurement: MeasureReadout? {
        guard pendingTool == .measure else { return nil }
        let targets = measureTargets
        guard !targets.isEmpty else { return nil }
        let units = MeasureUnits(us: Preferences.unitSystemSetting.isUS)
        let key = MeasureCacheKey(targets: targets, revision: sceneRevision, us: units.us)
        if let cache = measureCache, cache.key == key { return cache.value }
        let value = computeMeasurement(targets, units)
        measureCache = (key, value)
        return value
    }

    private func computeMeasurement(_ targets: [MeasureTarget], _ units: MeasureUnits) -> MeasureReadout? {
        let bodies = targets.map { t in result?.body(t.body) }
        guard !bodies.contains(where: { $0 == nil }) else { return nil }
        var pieces: [MeasuredPiece] = []
        for (t, body) in zip(targets, bodies) {
            guard let m = try? body?.measure(t.piece) else { return nil }
            // The body's name too when it can't be told from the picture which one it is.
            let name = meshes.first { $0.id == t.body }?.name
            let kind = MeasureReport.kind(m)
            let named = t.piece == .body || meshes.count > 1
            pieces.append(MeasuredPiece(title: named ? [kind, name].compactMap { $0 }.joined(separator: " · ") : kind,
                                        measure: m))
        }
        var distance: KDistance?
        if targets.count == 2, let a = bodies[0], let b = bodies[1] {
            distance = try? a.distance(targets[0].piece, to: b, targets[1].piece)
        }
        return MeasureReport.report(pieces, distance: distance, units: units)
    }

    /// A viewport click while the Measure tool waits: a second piece joins the first; a third starts over.
    /// Clicking a picked piece again lets go of it, and empty space lets go of everything.
    func measureClick(_ pick: PickID?) {
        defer { overlayRevision += 1 }
        guard let pick, pick.isFace || pick.isEdge else {
            selection = []
            return
        }
        if let i = selection.firstIndex(of: pick) {
            selection.remove(at: i)
        } else if selection.count >= 2 {
            selection = [pick]
        } else {
            selection.append(pick)
        }
    }

    func measurePrompt() -> String {
        switch selection.count {
        case 0: return "Click a face, an edge or a body to measure it, or two to measure between them"
        case 1: return "Click a second face, edge or body to measure between them"
        default: return "Click anything to measure it again · Esc to finish"
        }
    }

    // MARK: in the viewport

    /// The line between the two picked pieces, and its ends.
    func addMeasureOverlay(to o: inout SketchOverlay) {
        guard let line = measurement?.line else { return }
        func f(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        let a = f(line.from), b = f(line.to)
        o.measure = [SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: 0)]
        o.measurePoints = [a, b].map { SegmentInstance(ax: $0.x, ay: $0.y, az: $0.z, bx: $0.x, by: $0.y, bz: $0.z, id: 0) }
    }

    /// The readouts drawn on the model.
    func measureLabels() -> [DimensionLabel] {
        guard let m = measurement else { return [] }
        return m.labels.enumerated().map { i, l in
            DimensionLabel(id: "measure:\(i)", world: SIMD3(Float(l.at.x), Float(l.at.y), Float(l.at.z)), text: l.text, editing: false)
        }
    }
}

struct MeasureCacheKey: Equatable {
    var targets: [MeasureTarget]
    var revision: Int
    var us: Bool
}

// MARK: - the panel

/// The Measure tool's readout, floating at the top of the viewport.
struct MeasurePanel: View {
    let model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Measure").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Finish measuring (Esc)") { model.cancelTool() }
            }
            if let m = model.measurement {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.space5) {
                        ForEach(m.sections) { section in
                            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(section.rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space4) {
                                        Text(row.label).foregroundStyle(.secondary)
                                        Spacer(minLength: DS.Spacing.space4)
                                        Text(row.value)
                                            .monospacedDigit()
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                    .font(.callout)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.text, forType: .string)
                }
                .controlSize(.small)
                .help("Copy these values")
            } else {
                Text(model.measurePrompt())
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }
}

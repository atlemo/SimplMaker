// Turns sketches (2D, in a plane frame) into GPU segments/triangles for the viewport.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// A dimension's value label, anchored in world space.
struct DimensionLabel: Identifiable, Equatable {
    var id: EntityID
    var world: SIMD3<Float>
    var text: String
    var editing: Bool
    /// A sketch dimension: a value you can click and change (drawn as an outlined pill).
    var isDimension = false
    /// A measured size that isn't a dimension yet (drawn lighter; a click makes it a dimension).
    var reference = false
    /// For a radius or diameter: which way is away from the curve, so the label can stand clear of it.
    var outward: SIMD3<Float>?
    /// A readout only: clicks go through it to what lies beneath (the section analysis's offset, beside its arrow).
    var passesClicks = false

    /// Id of the light label showing a curve's measured size.
    static func referenceID(_ curve: EntityID) -> EntityID { "ref:" + curve }
    static func curve(ofReference id: EntityID) -> EntityID? { id.hasPrefix("ref:") ? String(id.dropFirst(4)) : nil }
    static let pendingID = "pending-length"
    static let pendingAngleID = "pending-angle"
}

/// A constraint symbol drawn next to the geometry it constrains.
struct ConstraintGlyph: Identifiable, Equatable {
    var id: String            // constraint id + "#" + which entity it's drawn on
    var constraint: EntityID
    var world: SIMD3<Float>
    var stack: Int            // position among glyphs on the same entity
    var symbol: String
    var help: String
    var selected: Bool
    /// The constraint fights others in the sketch (drawn red).
    var problem = false
    /// A pattern's button (not a constraint): a click opens the pattern to change it.
    var pattern: EntityID?
    /// A mirror's button: a click opens the mirror to change it.
    var mirror: EntityID?
}

@MainActor
enum SketchOverlayBuilder {
    static func symbol(_ k: SketchConstraint.Kind) -> (symbol: String, help: String)? {
        switch k {
        case .coincident: return nil  // shown by the shared point itself
        case .horizontal: return ("H", "Horizontal")
        case .vertical: return ("V", "Vertical")
        case .parallel: return ("∥", "Parallel")
        case .perpendicular: return ("⊥", "Perpendicular")
        case .equal: return ("=", "Equal")
        case .tangent: return ("T", "Tangent")
        case .pointOnCurve: return ("⊙", "Point on curve")
        case .midpoint: return ("M", "Midpoint")
        case .fix: return ("⌖", "Fixed")
        case .symmetric: return ("⇆", "Symmetric")
        }
    }

    // MARK: what is worth showing at this zoom

    /// The width a label of this text takes, in pixels (about; the real one is measured by the view).
    static func labelWidth(_ text: String) -> Double { Double(text.count) * 7 + 16 }

    /// Whether what a label or glyph annotates is long enough on screen to earn it: a size, a symbol, a value
    /// squeezed onto a few pixels of line only buries the sketch. Without a span, or before the zoom is known, yes.
    static func legible(span: Double?, mmPerPixel: Double, needing pixels: Double) -> Bool {
        guard let span, mmPerPixel > 0 else { return true }
        return span / mmPerPixel >= pixels
    }

    /// The length a dimension spans, in mm: its line, or for an angle the shorter of its two lines.
    static func span(of d: SketchDimension, in s: Sketch, value: Double?) -> Double? {
        if let line = s.dimensionLine(of: d) { return simdLength(line.p2 - line.p1) }
        func length(_ id: EntityID) -> Double? { s.lineEnds(id).map { simdLength($0.1 - $0.0) } }
        switch d.kind {
        case .angle(let a, let b), .supplementAngle(let a, let b):
            guard let la = length(a), let lb = length(b) else { return nil }
            return min(la, lb)
        case .lineAngle(let l): return length(l)
        default: return d.unitKind == .length ? value.map(abs) : nil
        }
    }

    /// The text of a dimension's label.
    static func dimensionText(_ d: SketchDimension, _ session: SketchSession) -> String {
        let value = session.values[d.id].map { d.unitKind.format(isLineAngle(d.kind) ? Sketch.foldedAngle($0) : $0) } ?? "?"
        let isParametric = ((try? Expressions.parse(d.expression))?.references.isEmpty == false)
        return prefix(d.kind) + (isParametric ? "\(d.expression) = \(value)" : value)
    }

    /// Whether a dimension (its label, and its line) is shown at this zoom. One being changed, picked or
    /// selected always is.
    static func shows(_ d: SketchDimension, _ session: SketchSession) -> Bool {
        if session.editingDimension == d.id || session.dimensionPicks.contains(d.id) || session.selection.contains(d.id) { return true }
        let span = span(of: d, in: session.sketch, value: session.values[d.id])
        let width = labelWidth(dimensionText(d, session))
        return legible(span: span, mmPerPixel: session.mmPerPixel, needing: max(60, 0.8 * width))
    }

    /// Offsets whose dimension is too short on screen for its label (an 8 mm wall seen from afar): they would vanish, and
    /// with them any sign that the outline is an offset. They stay as the bare dimension line between the two edges, and
    /// one value label per offset (the run of offset dimensions made together, on its longest edge) says what it is.
    static func offsetMarks(_ session: SketchSession) -> (lines: Set<EntityID>, labelled: Set<EntityID>) {
        let s = session.sketch
        var lines = Set<EntityID>(), labelled = Set<EntityID>()
        var run: [(id: EntityID, edge: Double)] = []
        var runExpression: String?
        func close() {
            if let best = run.max(by: { $0.edge < $1.edge }) { labelled.insert(best.id) }
            run = []
        }
        for d in s.dimensions {
            var isOffset = false
            switch d.kind { case .pointLineDistance, .radialOffset: isOffset = true; default: break }
            let span = isOffset && !shows(d, session) ? span(of: d, in: s, value: session.values[d.id]) : nil
            guard isOffset, let span, legible(span: span, mmPerPixel: session.mmPerPixel, needing: 6) else {
                if !isOffset || shows(d, session) { close(); runExpression = nil }
                continue
            }
            if runExpression != d.expression { close(); runExpression = d.expression }
            lines.insert(d.id)
            run.append((d.id, s.dimensionLine(of: d).map { abs($0.offset) } ?? 0))
        }
        close()
        return (lines, labelled)
    }

    /// Whether a measured size (the light label of a line or circle without a dimension) is shown: it needs more
    /// room than a dimension, as there is one for every curve.
    static func shows(measured m: (curve: EntityID, kind: SketchDimension.Kind, value: Double), _ session: SketchSession) -> Bool {
        // A few picked curves show their size; a big pick (a dragged box over a whole drawing) would bury it in labels, and
        // asking each curve whether it is picked would be slow.
        if session.selection.count > 3 { return false }
        if session.selection.contains(m.curve) { return true }
        return legible(span: abs(m.value), mmPerPixel: session.mmPerPixel,
                       needing: max(90, 1.6 * labelWidth(prefix(m.kind) + measured(m.value))))
    }

    /// Glyphs for the sketch being edited, one per constrained curve (or point).
    static func glyphs(_ session: SketchSession) -> [ConstraintGlyph] {
        let s = session.sketch
        var perEntity: [EntityID: Int] = [:]
        var out: [ConstraintGlyph] = []
        let lookup = Lookup(s)  // one lookup by id per constraint, not a scan of the sketch
        let selected = Set(session.selection)
        func anchor(_ id: EntityID) -> SIMD2<Double>? {
            if let p = lookup.positions[id] { return p }
            guard let curve = lookup.curves[id], let g = s.geometry(of: curve, lookup.positions) else { return nil }
            switch g {
            case .line: return g.point(0.25)  // a quarter along: the middle is where the line's size shows
            case .circle(let c, let r): return c + SIMD2(0, r)
            case .arc, .bezier: return g.point(0.5)
            case .ellipse: return g.point(0)
            }
        }
        for c in s.constraints {
            guard let info = symbol(c.kind) else { continue }
            var on = Sketch.references(c.kind)
            switch c.kind {
            case .pointOnCurve(let p, _), .midpoint(let p, _): on = [p]  // draw at the point
            default: break
            }
            for e in on {
                guard let a = anchor(e) else { continue }
                // A symbol on a short line (as drawn on screen) is only in the way; a selected one stays.
                if !selected.contains(c.id), lookup.curves[e] != nil,
                   !legible(span: s.lineEnds(e).map { simdLength($0.1 - $0.0) }, mmPerPixel: session.mmPerPixel, needing: 36) { continue }
                let n = perEntity[e, default: 0]
                perEntity[e] = n + 1
                out.append(ConstraintGlyph(id: "\(c.id)#\(e)", constraint: c.id, world: world(session.frame, a), stack: n,
                                           symbol: info.symbol, help: info.help, selected: selected.contains(c.id),
                                           problem: session.diagnosis.conflicting.contains(c.id)))
            }
        }
        return out
    }

    /// One button per pattern, at the top right of what it copies: the way into its editor, so that clicking
    /// a copy only picks it.
    static func patternGlyphs(_ session: SketchSession) -> [ConstraintGlyph] {
        let s = session.sketch
        guard !s.patterns.isEmpty, !session.isPatterning else { return [] }
        return s.patterns.compactMap { def in
            guard let box = s.patternBox(def.sources) else { return nil }
            let circular = def.kind == .circular
            return ConstraintGlyph(id: "pattern:\(def.id)", constraint: def.id, world: world(session.frame, box.max), stack: 0,
                                   symbol: "", help: circular ? "Circular pattern" : "Rectangular pattern",
                                   selected: false, pattern: def.id)
        }
    }

    /// One button per mirror, at the top right of its image: the way into its editor (the Mirror button with an
    /// image selected does the same). A mirror whose line is a projected edge or axis has no other handle.
    static func mirrorGlyphs(_ session: SketchSession) -> [ConstraintGlyph] {
        let s = session.sketch
        guard !s.mirrors.isEmpty, !session.isMirroring else { return [] }
        var hi: [EntityID: SIMD2<Double>] = [:]
        func grow(_ owner: EntityID, _ p: SIMD2<Double>) { hi[owner] = hi[owner].map { simd_max($0, p) } ?? p }
        for point in s.points {
            guard let owner = Sketch.pattern(ofGenerated: point.id) else { continue }
            grow(owner, SIMD2(point.x, point.y))
        }
        for c in s.curves {
            guard let owner = Sketch.pattern(ofGenerated: c.id), case .circle(let m, let r) = c.geometry, let p = s.position(m) else { continue }
            grow(owner, p + SIMD2(r, r))
        }
        return s.mirrors.compactMap { def in
            guard let top = hi[def.id] else { return nil }
            return ConstraintGlyph(id: "mirror:\(def.id)", constraint: def.id, world: world(session.frame, top), stack: 0,
                                   symbol: "", help: "Mirror across \(s.mirrorLineName(def.line))",
                                   selected: false, mirror: def.id)
        }
    }

    static func world(_ frame: Frame, _ p: SIMD2<Double>) -> SIMD3<Float> {
        let w = frame.point(p.x, p.y)
        return SIMD3(Float(w.x), Float(w.y), Float(w.z))
    }

    /// Points along a sketch curve (in sketch coordinates).
    static func polyline(_ c: SketchCurve, in s: Sketch, positions: [EntityID: SIMD2<Double>]? = nil) -> [SIMD2<Double>] {
        func position(_ id: EntityID) -> SIMD2<Double>? { positions.map { $0[id] } ?? s.position(id) }
        func arc(_ center: SIMD2<Double>, _ r: Double, _ a0: Double, _ a1: Double) -> [SIMD2<Double>] {
            let n = max(6, Int(abs(a1 - a0) / (2 * .pi) * 96))
            return (0...n).map { i in
                let t = a0 + (a1 - a0) * Double(i) / Double(n)
                return center + r * SIMD2(cos(t), sin(t))
            }
        }
        switch c.geometry {
        case .line(let a, let b):
            guard let pa = position(a), let pb = position(b) else { return [] }
            return [pa, pb]
        case .circle(let center, let r):
            guard let pc = position(center) else { return [] }
            return arc(pc, r, 0, 2 * .pi)
        case .arc(let center, let start, let end):
            guard let pc = position(center), let ps = position(start), let pe = position(end) else { return [] }
            let a0 = atan2(ps.y - pc.y, ps.x - pc.x)
            var a1 = atan2(pe.y - pc.y, pe.x - pc.x)
            while a1 <= a0 { a1 += 2 * .pi }
            return arc(pc, simdLength(ps - pc), a0, a1)
        case .bezier:
            let poles = s.pointIDs(of: c).compactMap { position($0) }
            return poles.count == 4 ? Bezier.flatten(poles) : []
        case .ellipse(let center, let major, let minor):
            guard let pc = position(center), let pu = position(major), let pv = position(minor) else { return [] }
            return (0...192).map { i in
                let t = Double(i) * 2 * .pi / 192
                return pc + (pu - pc) * cos(t) + (pv - pc) * sin(t)
            }
        }
    }

    static func segments(_ line: [SIMD2<Double>], frame: Frame, id: UInt32) -> [SegmentInstance] {
        guard line.count > 1 else { return [] }
        return (0..<(line.count - 1)).map { i in
            let a = world(frame, line[i]), b = world(frame, line[i + 1])
            return SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: id)
        }
    }

    /// The sketch being edited: pickable curves and points, plus the tool preview.
    static func editing(_ session: SketchSession, into o: inout SketchOverlay, showCentres: Bool = false) {
        let s = session.sketch, f = session.frame
        let positions = s.positionTable()
        let redrawn = session.redrawnCurves
        // A gear's outline is generated: drawn, but without its points, handles and centre marks, which would bury it.
        let gears = Set(s.gears.map(\.id))
        func ofGear(_ id: EntityID) -> Bool { !gears.isEmpty && Sketch.pattern(ofGenerated: id).map(gears.contains) == true }
        for (i, c) in s.curves.enumerated() where !redrawn.contains(c.id) {
            let segs = segments(polyline(c, in: s, positions: positions), frame: f, id: PickID(sketchCurve: i).raw)
            if c.construction { o.construction += segs } else { o.curves += segs }
            // A Bézier's handles: thin lines from each end to its control point.
            if case .bezier(let a, let c1, let c2, let b) = c.geometry, !ofGear(c.id) {
                for (end, handle) in [(a, c1), (b, c2)] {
                    guard let pe = s.position(end), let ph = s.position(handle) else { continue }
                    o.preview += segments([pe, ph], frame: f, id: 0)
                }
            }
        }
        // A picked axis: the line through the origin, reaching well past the screen.
        let reach = session.mmPerPixel > 0 ? session.mmPerPixel * 6000 : 1000
        for axis in session.axisSelection {
            let along = axis == SketchMirrorDef.xAxis ? SIMD2(reach, 0) : SIMD2(0, reach)
            o.axisSelected += segments([-along, along], frame: f, id: 0)
        }
        for (i, p) in s.points.enumerated() where !ofGear(p.id) {
            let w = world(f, p.position)
            o.points.append(SegmentInstance(ax: w.x, ay: w.y, az: w.z, bx: w.x, by: w.y, bz: w.z,
                                            id: PickID(sketchPoint: i).raw))
        }
        // Text: the letters are drawn like curves, and picking one picks (and drags) the text's anchor.
        for text in session.textOutlines() {
            for line in text.polylines { o.curves += segments(line, frame: f, id: PickID(sketchPoint: text.anchor).raw) }
        }
        // A new text, as far as it is typed: not there to pick yet.
        for line in session.textPreview() { o.curves += segments(line, frame: f, id: 0) }
        // An X marks the middle of each closed shape: where the cursor snaps while a point tool draws, and on every shape with Show Shape Centres on.
        if session.tool.placesPoints || showCentres {
            let r = session.snapTolerance
            for c in session.shapeCenters() where !c.points.contains(where: Sketch.isGenerated) {
                let p = c.position
                o.construction += segments([p - SIMD2(r, r), p + SIMD2(r, r)], frame: f, id: 0)
                o.construction += segments([p - SIMD2(r, -r), p + SIMD2(r, -r)], frame: f, id: 0)
            }
        }
        let marks = offsetMarks(session)
        for d in s.dimensions where shows(d, session) || marks.lines.contains(d.id) {
            if let arc = s.angleArc(of: d, size: session.snapTolerance) {
                o.preview += angleSegments(arc, size: session.snapTolerance, frame: f)
            } else if let line = s.dimensionLine(of: d) {
                o.preview += dimensionSegments(line, size: session.snapTolerance, frame: f)
            }
        }
        // The angle waiting to be placed: its wedge under the cursor, drawn as it will be stored.
        if let p = session.anglePreview, let arc = s.angleArc(of: SketchDimension(p.kind, "", offset: p.radius), size: session.snapTolerance) {
            o.preview += angleSegments(arc, size: session.snapTolerance, frame: f)
        }
        for line in session.previewPolylines() { o.preview += segments(line, frame: f, id: 0) }
        if let snap = session.lastSnap {
            let w = world(f, snap.position)
            o.snap = [SegmentInstance(ax: w.x, ay: w.y, az: w.z, bx: w.x, by: w.y, bz: w.z, id: 0)]
        }
        o.fullyConstrained = session.solve?.status == .solved && session.solve?.degreesOfFreedom == 0
    }

    /// Where a dimension's value stands: the middle of its line; for a circle's size, the middle of the half
    /// the line points along, clear of the center marker.
    static func labelAnchor(_ line: DimensionLine) -> SIMD2<Double> {
        guard let c = line.center else { return (line.q1 + line.q2) / 2 }
        return (c + line.q2) / 2
    }

    /// A distance dimension drawn out: extension lines from what it measures, the dimension line between
    /// them, and an arrowhead at each end. `size` (about a few pixels, in mm) scales the arrows and overshoot.
    static func dimensionSegments(_ line: DimensionLine, size: Double, frame: Frame) -> [SegmentInstance] {
        let q1 = line.q1, q2 = line.q2
        var out = segments([q1, q2], frame: frame, id: 0)
        for (p, q) in [(line.p1, q1), (line.p2, q2)] where simdLength(q - p) > 1e-9 {
            let u = (q - p) / simdLength(q - p)
            out += segments([p, q + u * size * 0.8], frame: frame, id: 0)  // a little past the dimension line
        }
        let span = simdLength(q2 - q1)
        guard span > 1e-9 else { return out }
        let u = (q2 - q1) / span
        let arrow = min(size * 2.2, span / 2)
        for (tip, dir) in [(q1, u), (q2, -u)] where line.arrowAtStart || tip == q2 {
            let back = tip + dir * arrow, side = SIMD2(-dir.y, dir.x) * arrow * 0.3
            out += segments([tip, back + side, back - side, tip], frame: frame, id: 0)
        }
        return out
    }

    /// A line's angle drawn out: the x-axis direction it is measured from, an arc round to the line, and an
    /// arrowhead where the arc meets the line.
    static func angleSegments(_ arc: Sketch.AngleArc, size: Double, frame: Frame) -> [SegmentInstance] {
        let c = arc.center, r = arc.radius, start = arc.start, sweep = arc.sweep
        func at(_ t: Double, _ radius: Double = r) -> SIMD2<Double> { c + radius * SIMD2(cos(t), sin(t)) }
        var out: [SegmentInstance] = []
        if arc.axis { out += segments([c, at(start, r + size * 0.8)], frame: frame, id: 0) }  // the axis it starts from, a little past the arc
        guard abs(sweep) > 1e-6 else { return out }
        let steps = max(Int(abs(sweep) / (.pi / 48)), 4)
        out += segments((0...steps).map { at(start + sweep * Double($0) / Double(steps)) }, frame: frame, id: 0)
        // The arrowhead points along the arc's end, back toward where it began.
        let end = start + sweep, turn: Double = sweep < 0 ? -1 : 1
        let tip = at(end), tangent = turn * SIMD2(sin(end), -cos(end))
        let head = min(size * 2.2, r * abs(sweep) / 2)
        let back = tip + tangent * head, side = SIMD2(cos(end), sin(end)) * head * 0.3
        out += segments([tip, back + side, back - side, tip], frame: frame, id: 0)
        return out
    }

    /// A finished sketch's curves, pickable (as paths, axes and rib lines) under its slot.
    static func finished(_ r: SketchResult, slot: Int, parameters: ParameterValues, into o: inout SketchOverlay) {
        let s = r.solved
        for t in s.texts {
            for contour in t.contours(in: s, parameters: parameters) {
                o.inactive += segments(contour.flatMap { TextOutline.flatten($0) }, frame: r.frame, id: 0)
            }
        }
        for (i, c) in s.curves.enumerated() {
            let segs = segments(polyline(c, in: s), frame: r.frame, id: PickID(sketchCurve: i, slot: slot).raw)
            if c.construction { o.construction += segs } else { o.inactive += segs }
        }
    }

    /// Profile regions of a sketch, pickable under its slot (slot 0: the sketch being edited, not pickable as profiles).
    static func regions(_ r: SketchResult, slot: Int, into o: inout SketchOverlay) {
        let n = r.frame.normal
        for (i, mesh) in r.regionMeshes.enumerated() {
            let base = UInt32(o.regionVertices.count)
            let id = PickID(region: i, slot: slot).raw
            for v in stride(from: 0, to: mesh.positions.count, by: 3) {
                o.regionVertices.append(FaceVertex(px: mesh.positions[v], py: mesh.positions[v + 1], pz: mesh.positions[v + 2],
                                                   nx: Float(n.x), ny: Float(n.y), nz: Float(n.z), id: id))
            }
            o.regionIndices += mesh.indices.map { $0 + base }
        }
    }

    /// Value labels for the dimensions of the sketch being edited.
    static func labels(_ session: SketchSession) -> [DimensionLabel] {
        let s = session.sketch
        let marks = offsetMarks(session)
        var out: [DimensionLabel] = s.dimensions.compactMap { d in
            guard shows(d, session) || marks.labelled.contains(d.id),
                  let anchor = s.dimensionLine(of: d).map(labelAnchor) ?? angleLabel(d, s, size: session.snapTolerance)
                      ?? anchor(d.kind, s, size: session.snapTolerance) else { return nil }
            return DimensionLabel(id: d.id, world: world(session.frame, anchor),
                                  text: dimensionText(d, session),
                                  editing: session.editingDimension == d.id, isDimension: true,
                                  outward: s.dimensionLine(of: d) == nil ? outward(d.kind, session.frame) : nil)
        }
        // Every other line, circle and arc shows its measured size, lighter.
        let pending = session.pendingLineLength != nil ? session.dimensionPicks.first : nil
        let lookup = Lookup(s)
        for m in session.referenceMeasurements where m.curve != pending && shows(measured: m, session) {
            guard let anchor = anchor(m.kind, s, lookup: lookup) else { continue }
            out.append(DimensionLabel(id: DimensionLabel.referenceID(m.curve), world: world(session.frame, anchor),
                                      text: prefix(m.kind) + measured(m.value), editing: false, reference: true,
                                      outward: outward(m.kind, session.frame)))
        }
        if let length = session.pendingLineLength, let line = pending, let anchor = anchor(.length(line), s) {
            out.append(DimensionLabel(id: DimensionLabel.pendingID, world: world(session.frame, anchor),
                                      text: "\(measured(length)) · click again to place", editing: true,
                                      passesClicks: true))
        }
        if let p = session.anglePreview, let anchor = angleLabel(SketchDimension(p.kind, "", offset: p.radius), s, size: session.snapTolerance) {
            out.append(DimensionLabel(id: DimensionLabel.pendingAngleID, world: world(session.frame, anchor),
                                      text: "\(UnitKind.angle.format(p.value)) · click to place", editing: true,
                                      passesClicks: true))  // the click that places it may land on its own label
        }
        return out
    }

    private static func isLineAngle(_ k: SketchDimension.Kind) -> Bool {
        if case .lineAngle = k { return true }
        return false
    }

    /// The direction a label stands in from its anchor, away from the curve it measures (radius and diameter only:
    /// their labels sit on the curve itself, and a small round corner would hide under its own value).
    static func outward(_ k: SketchDimension.Kind, _ frame: Frame) -> SIMD3<Float>? {
        let d: SIMD2<Double>
        switch k {
        case .radius, .diameter: d = SIMD2(0.7071, 0.7071)
        case .radialOffset: d = SIMD2(-0.7071, 0.7071)
        default: return nil
        }
        let w = frame.xAxis * d.x + frame.yAxis * d.y
        return SIMD3(Float(w.x), Float(w.y), Float(w.z))
    }

    /// A measured length for display: at most two decimals ("35.36 mm"), since it's only a guide.
    static func measured(_ mm: Double) -> String {
        var s = String(format: "%.2f", mm)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " mm"
    }

    /// "⌀ " for diameters, "R " for radii.
    static func prefix(_ k: SketchDimension.Kind) -> String {
        switch k {
        case .diameter: return "⌀ "
        case .radius: return "R "
        default: return ""
        }
    }

    /// Every point's position and every curve by id, made once for a loop over many labels (a sketch can have hundreds,
    /// and each lookup by scanning adds up).
    struct Lookup {
        let positions: [EntityID: SIMD2<Double>]
        let curves: [EntityID: SketchCurve]
        init(_ s: Sketch) {
            positions = s.positionTable()
            curves = Dictionary(s.curves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// An angle's value stands just outside its arc, at the middle of the wedge, so it moves with the arc's radius.
    static func angleLabel(_ d: SketchDimension, _ s: Sketch, size: Double) -> SIMD2<Double>? {
        guard d.isAngle, let arc = s.angleArc(of: d, size: size) else { return nil }
        return arc.center + arc.radius * 1.15 * SIMD2(cos(arc.middle), sin(arc.middle))
    }

    static func anchor(_ k: SketchDimension.Kind, _ s: Sketch, size: Double = 1, lookup: Lookup? = nil) -> SIMD2<Double>? {
        func mid(_ a: SIMD2<Double>?, _ b: SIMD2<Double>?) -> SIMD2<Double>? {
            guard let a, let b else { return nil }
            return (a + b) / 2
        }
        func position(_ id: EntityID) -> SIMD2<Double>? { lookup.map { $0.positions[id] } ?? s.position(id) }
        func curve(_ id: EntityID) -> SketchCurve? { lookup.map { $0.curves[id] } ?? s.curve(id) }
        func lineMid(_ l: EntityID) -> SIMD2<Double>? {
            guard case .line(let a, let b)? = curve(l)?.geometry, let pa = position(a), let pb = position(b) else {
                return s.chordEnds(l).map { ($0.0 + $0.1) / 2 }  // a straight projected Bézier stands in for a line
            }
            return (pa + pb) / 2
        }
        switch k {
        case .distance(let a, let b), .horizontalDistance(let a, let b), .verticalDistance(let a, let b):
            return mid(position(a), position(b))
        case .pointLineDistance(let p, let l): return mid(position(p), lineMid(l))
        case .gap(let c, let o): return s.gapEnds(c, o).map { ($0.0 + $0.1) / 2 }
        case .length(let l): return lineMid(l)
        case .radius(let c), .diameter(let c):
            guard let curve = curve(c) else { return nil }
            let center: SIMD2<Double>?
            switch curve.geometry {
            case .circle(let id, _), .arc(let id, _, _): center = position(id)
            case .line, .bezier, .ellipse: center = nil
            }
            guard let center, let r = s.radius(of: curve) else { return nil }
            return center + r * SIMD2(0.7071, 0.7071)
        case .angle(let a, let b), .supplementAngle(let a, let b):
            guard let arc = s.angleArc(of: SketchDimension(k, ""), size: size) else { return mid(lineMid(a), lineMid(b)) }
            return arc.center + arc.radius * 1.15 * SIMD2(cos(arc.middle), sin(arc.middle))
        case .lineAngle, .arcAngle:
            guard let arc = s.angleArc(of: SketchDimension(k, ""), size: size) else { return nil }
            return arc.center + arc.radius * 1.15 * SIMD2(cos(arc.middle), sin(arc.middle))
        case .radialOffset(_, let b):
            guard let curve = s.curve(b), let center = s.center(of: b).flatMap({ s.position($0) }),
                  let r = s.radius(of: curve) else { return nil }
            return center + r * SIMD2(-0.7071, 0.7071)
        }
    }
}

extension SketchOverlayBuilder {
    /// A dial: an arc round `center` and the dot on it at `angle` (the part that is grabbed). A taper's arc reaches
    /// either way from `axis` towards the dial's side; a revolve's is the whole circle, and its dot is the feature's arrow.
    static func dial(center: SIMD3<Double>, axis: SIMD3<Double>, dial: DocumentModel.DragHandle.Dial, angle: Double,
                     into o: inout SketchOverlay) {
        func f(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        func at(_ a: Double) -> SIMD3<Double> { center + dial.radius * (cos(a) * axis + sin(a) * dial.side) }
        let steps = 72
        let from = dial.wraps ? 0 : -dial.reach
        // Opaque around the middle (zero angle), fading to nothing at either end of the arc; a whole circle stays opaque.
        func fade(_ t: Double) -> UInt32 {
            if dial.wraps { return 65535 }
            let e = min(max((1 - abs(2 * t - 1)) / 0.6, 0), 1)
            return UInt32((e * e * (3 - 2 * e) * 65535).rounded())
        }
        for i in 0..<steps {
            let t0 = Double(i) / Double(steps), t1 = Double(i + 1) / Double(steps)
            let a = f(at(from + 2 * dial.reach * t0)), b = f(at(from + 2 * dial.reach * t1))
            o.dialArc.append(SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: fade(t0) | fade(t1) << 16))
        }
        let dot = f(at(angle))
        let pick = dial.wraps ? PickID.handle : PickID.dialHandle  // a revolve's dot is its one arrow (slot 0)
        o.dialDot.append(SegmentInstance(ax: dot.x, ay: dot.y, az: dot.z, bx: dot.x, by: dot.y, bz: dot.z, id: pick.raw))
    }
}

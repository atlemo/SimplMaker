// Interactive sketch editing: tools, snapping, selection, dragging and dimensions.
// Geometry operations live in CADCore (SketchEditing.swift); this is the UI state machine.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Observation

enum SketchTool: String, CaseIterable, Identifiable {
    case select = "Select", line = "Line", rectangle = "Rectangle", circle = "Circle", circle2Point = "2-Point Circle", arc = "Arc", bezier = "Bézier Curve"
    case point = "Point", text = "Text", fillet = "Round Corner", trim = "Trim", extend = "Extend", dimension = "Dimension"

    var id: String { rawValue }

    /// Toolbar groups: drawing, changing curves, and dimensions (Select stands alone).
    static let draw: [SketchTool] = [.line, .rectangle, .circle, .circle2Point, .arc, .bezier, .point, .text]
    static let modify: [SketchTool] = [.fillet, .trim, .extend]

    /// The name under the icon in the toolbar (menus use the full `rawValue`).
    var shortTitle: String {
        switch self {
        case .fillet: return "Corner"
        case .circle2Point: return "Circle"
        case .bezier: return "Curve"
        default: return rawValue
        }
    }

    /// Tools whose clicks place points (and so snap to shape centers).
    var placesPoints: Bool {
        switch self {
        case .line, .rectangle, .circle, .circle2Point, .arc, .bezier, .point, .text: return true
        case .select, .fillet, .trim, .extend, .dimension: return false
        }
    }

    /// The circle tools share a toolbar button (and the C key), each a way to draw a circle.
    var isCircle: Bool { self == .circle || self == .circle2Point }

    /// The tool for a key press: pressing C again while drawing circles switches between the two ways.
    static func forKey(_ key: Character, current: SketchTool) -> SketchTool? {
        guard let tool = allCases.first(where: { $0.key == key }) else { return nil }
        if tool.isCircle, current.isCircle { return current == .circle ? .circle2Point : .circle }
        return tool
    }

    /// Tooltip: the name, its key, and what it does.
    var help: String {
        switch self {
        case .fillet: return "Round Corner (F): round a sketch corner where two lines meet, with an arc and a radius. For rounding edges of a solid, use Fillet in Design mode."
        default: return "\(rawValue) (\(String(key).uppercased())): \(hint)"
        }
    }

    /// A glyph name from the macOS Design System's icon set (see IconGlyphs.swift), not an SF Symbol.
    var symbol: String {
        switch self {
        case .select: return "mouse-pointer-2"
        case .line: return "minus"
        case .rectangle: return "square"
        case .circle: return "circle"
        case .circle2Point: return "diameter"
        case .arc: return "spline"
        case .bezier: return "bezier"
        case .point: return "dot"
        case .text: return "type"
        case .fillet: return "corner-round"
        case .trim: return "scissors"
        case .extend: return "arrow-up-right"
        case .dimension: return "ruler"
        }
    }
    /// Single-key shortcut while the viewport has focus.
    var key: Character {
        switch self {
        case .select: return "s"
        case .line: return "l"
        case .rectangle: return "r"
        case .circle, .circle2Point: return "c"
        case .arc: return "a"
        case .bezier: return "b"
        case .point: return "p"
        case .text: return "x"
        case .fillet: return "f"
        case .trim: return "t"
        case .extend: return "e"
        case .dimension: return "d"
        }
    }
    var hint: String {
        switch self {
        case .select: return "Click to select, double-click for all joined curves, drag to move, ⌫ deletes"
        case .line: return "Click points to draw connected lines · Esc ends the chain"
        case .rectangle: return "Click two opposite corners"
        case .circle: return "Click the center, then a point on the circle · C again for 2-point"
        case .circle2Point: return "Click two points on opposite sides of the circle · C again for center"
        case .arc: return "Click the center, the start, then the end (counter-clockwise)"
        case .bezier: return "Click the start and the end, then where the curve bends · drag its handles to shape it"
        case .point: return "Click to place a point"
        case .text: return "Click where the text starts, type it, and press Return · click a text (or double-click it) to change its words"
        case .fillet: return "Click the corner point where two lines meet to round it with an arc"
        case .trim: return "Click the part of a curve to remove (up to where other curves cross it)"
        case .extend: return "Click near the end of a line or arc to extend it to the next curve"
        case .dimension: return "Click a line (then click again to place its length), a circle or arc, or two items for a distance or angle · or click any grey size"
        }
    }
}

/// A value the user can type while drawing, instead of placing the next point with the mouse.
enum SketchInput: String, CaseIterable, Identifiable {
    case length = "Length", angle = "Angle", width = "Width", height = "Height"
    case diameter = "Diameter", radius = "Radius", sweep = "Sweep"

    var id: String { rawValue }
    var unit: UnitKind { self == .angle || self == .sweep ? .angle : .length }
    /// Short label shown in front of the field.
    var symbol: String {
        switch self {
        case .length: return "L"
        case .angle, .sweep: return "∠"
        case .width: return "W"
        case .height: return "H"
        case .diameter: return "⌀"
        case .radius: return "R"
        }
    }
}

struct SketchMouse {
    enum Phase { case moved, down, dragged, up }
    var phase: Phase
    var uv: SIMD2<Double>?   // cursor on the sketch plane
    var pick: PickID?        // what's under the cursor
    var additive = false
    /// How close (in mm on the sketch plane) the cursor must come to snap to something: a few pixels.
    var tolerance: Double?
    /// Grid spacing at the current zoom, in mm; nil = don't snap to the grid.
    var gridStep: Double?
    /// False while ⌥ is held: place exactly where the cursor is.
    var snapping = true
}

/// Model geometry the cursor can snap to while sketching: body edges and corners that lie in the
/// sketch plane (e.g. the outline of the face being sketched on), in sketch (u, v).
struct SketchReferences {
    var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
    var points: [SIMD2<Double>] = []
}

/// What the cursor snapped to, shown as a marker and in the status bar.
enum SnapKind: String {
    case point = "Point", midpoint = "Midpoint", center = "Center", curve = "On curve"
    case vertex = "Corner", edge = "Edge", grid = "Grid"
}

@MainActor
@Observable
final class SketchSession {
    let featureID: FeatureID
    var frame: Frame
    private(set) var sketch: Sketch
    private(set) var solve: SolveResult?
    private(set) var tool: SketchTool = .line

    func setTool(_ t: SketchTool) {
        tool = t
        if t.isCircle { circleMode = t }
        resetToolState()
    }
    /// The way of drawing circles the toolbar's Circle button picks: the one used last.
    private(set) var circleMode: SketchTool = .circle
    var selection: [EntityID] = []
    private(set) var hover: EntityID?
    /// Set by the Offset command to ask the toolbar to show the offset distance popover.
    var offsetRequested = false
    private(set) var cursor: SIMD2<Double>?
    private(set) var clicks: [SketchSnap] = []
    /// Where the Text tool was clicked: waiting for the text to be typed.
    private(set) var pendingText: SketchSnap?
    /// The text whose words are being changed in place (the typing box starts with them).
    private(set) var editingText: EntityID?
    /// What the typing box starts with: the words of the text being edited, or nothing for a new one.
    var textEntryInitial: String { editingText.flatMap { id in sketch.texts.first { $0.id == id }?.text } ?? "" }
    private var chainPoint: EntityID?
    /// Values typed for the current drawing step, as entered. Cleared when the step completes.
    private(set) var typed: [SketchInput: String] = [:]
    /// Typed values from earlier steps of the shape in progress (an arc's radius), as dimensions to add.
    private var pendingDimensions: [(input: SketchInput, expression: String, value: Double)] = []
    private(set) var dimensionPicks: [EntityID] = []
    var editingDimension: EntityID?
    var message: String?

    // dragging
    private var dragEntity: EntityID?
    private var dragOffset = SIMD2<Double>.zero
    private var dragMoved = false

    /// Model edges and corners in the sketch plane, for snapping (kept up to date by the model).
    @ObservationIgnored var references = SketchReferences()
    @ObservationIgnored private var tolerance = 0.5
    /// How far the cursor snaps, in mm at the current zoom (a few pixels).
    var snapTolerance: Double { tolerance }
    @ObservationIgnored private var gridStep: Double?
    @ObservationIgnored private var snapping = true
    /// The latest snap, for the marker and the status bar.
    private(set) var lastSnap: (kind: SnapKind, position: SIMD2<Double>)?

    @ObservationIgnored var values: [EntityID: Double] = [:]
    @ObservationIgnored var parameters = ParameterValues()

    init(featureID: FeatureID, frame: Frame, sketch: Sketch, parameters: ParameterValues) {
        self.featureID = featureID
        self.frame = frame
        self.sketch = sketch
        self.parameters = parameters
        resolve()
    }

    /// Replaces the sketch (after undo/redo or a parameter change) and re-solves.
    func reload(_ s: Sketch, parameters: ParameterValues) {
        sketch = s
        self.parameters = parameters
        selection = selection.filter { s.kind(of: $0) != nil }
        if let d = editingDimension, !s.dimensions.contains(where: { $0.id == d }) { editingDimension = nil }
        resolve()
    }

    private func resolve() {
        values = sketch.dimensionValues(parameters)
        solve = SketchSolver.solveLocally(&sketch, dimensionValues: values)
    }

    private func resetToolState() {
        clicks = []
        pendingText = nil
        editingText = nil
        chainPoint = nil
        typed = [:]
        pendingDimensions = []
        dimensionPicks = []
        message = nil
    }

    var hoverEntity: EntityID? { hover }
    var hoverIsDraggable: Bool {
        guard let hover else { return false }
        if let p = sketch.point(hover) { return !p.fixed }
        return sketch.curve(hover) != nil
    }

    // MARK: picking

    /// Entity id for a pick, using the same ordering the overlay was built with.
    func entity(for pick: PickID?) -> EntityID? {
        guard let pick else { return nil }
        switch pick.kind {
        case .sketchPoint: return pick.element < sketch.points.count ? sketch.points[pick.element].id : nil
        case .sketchCurve: return pick.element < sketch.curves.count ? sketch.curves[pick.element].id : nil
        default: return nil
        }
    }

    /// Double-click with Select: the curve under the cursor and every curve joined to it.
    func selectConnected(additive: Bool) {
        guard tool == .select, let h = hover, sketch.curve(h) != nil else { return }
        let chain = sketch.connectedCurves(h)
        selection = additive ? selection + chain.filter { !selection.contains($0) } : chain
        dragEntity = nil
    }

    func pickID(for id: EntityID) -> PickID? {
        if let i = sketch.points.firstIndex(where: { $0.id == id }) { return PickID(sketchPoint: i) }
        if let i = sketch.curves.firstIndex(where: { $0.id == id }) { return PickID(sketchCurve: i) }
        return nil
    }

    /// Snap for the cursor, in order of preference: a sketch point, a line's midpoint, a model corner,
    /// a sketch curve, a model edge, the grid. Points and curves snap within a few pixels (not only
    /// when exactly under the cursor) and become coincident / point-on-curve constraints.
    func snap(_ uv: SIMD2<Double>, excluding: EntityID? = nil) -> SketchSnap {
        let result = findSnap(uv, excluding: excluding)
        lastSnap = result.kind.map { ($0, result.snap.position) }
        return result.snap
    }

    private func findSnap(_ uv: SIMD2<Double>, excluding: EntityID?) -> (snap: SketchSnap, kind: SnapKind?) {
        if let h = hover, h != excluding, let p = sketch.point(h) { return (SketchSnap(p.position, point: h), .point) }
        guard snapping else {
            if let h = hover, h != excluding, sketch.curve(h) != nil { return (SketchSnap(uv, curve: h), .curve) }
            return (SketchSnap(uv), nil)
        }
        let tol = tolerance
        func nearest<T>(_ items: [T], _ pos: (T) -> SIMD2<Double>?) -> T? {
            var best: (T, Double)?
            for item in items {
                guard let p = pos(item) else { continue }
                let d = simdLength(p - uv)
                if d <= tol, d < (best?.1 ?? .infinity) { best = (item, d) }
            }
            return best?.0
        }
        let own = excluding.map { Set([$0] + (sketch.curve($0).map { sketch.pointIDs(of: $0) } ?? [])) } ?? []
        if let p = nearest(sketch.points.filter { !own.contains($0.id) }, { $0.position }) {
            return (SketchSnap(p.position, point: p.id), sketch.curves.contains { c in
                if case .circle(let center, _) = c.geometry { return center == p.id }
                if case .arc(let center, _, _) = c.geometry { return center == p.id }
                return false
            } ? .center : .point)
        }
        // The middle of a closed shape (not one being dragged): a point placed there stays centred.
        let centers = sketch.shapeCenters().filter { own.isDisjoint(with: $0.points) }
        if let c = nearest(centers, { $0.position }) { return (SketchSnap(c.position, centerOf: c.corners), .center) }
        let lines = sketch.curves.compactMap { c -> SIMD2<Double>? in
            guard !own.contains(c.id), case .line(let a, let b) = c.geometry, let pa = sketch.position(a),
                  let pb = sketch.position(b) else { return nil }
            return (pa + pb) / 2
        }
        if let m = nearest(lines, { $0 }) { return (SketchSnap(m), .midpoint) }
        if let v = nearest(references.points, { $0 }) { return (SketchSnap(v), .vertex) }
        let curves = sketch.curves.filter { !own.contains($0.id) }.map(\.id)
        let onCurves = curves.compactMap { id in sketch.geometry(of: id).map { (id, Self.closest(uv, on: $0)) } }
        if let hovered = hover, hovered != excluding, let g = sketch.geometry(of: hovered) {
            return (SketchSnap(Self.closest(uv, on: g), curve: hovered), .curve)
        }
        if let c = nearest(onCurves, { $0.1 }) { return (SketchSnap(c.1, curve: c.0), .curve) }
        let onEdges = references.segments.map { Self.closest(uv, on: .line($0.0, $0.1)) }
        if let e = nearest(onEdges, { $0 }) { return (SketchSnap(e), .edge) }
        if let step = gridStep, step > 0 {
            return (SketchSnap(SIMD2((uv.x / step).rounded() * step, (uv.y / step).rounded() * step)), .grid)
        }
        return (SketchSnap(uv), nil)
    }

    /// The point of a curve (not its extension) closest to p.
    static func closest(_ p: SIMD2<Double>, on g: CurveGeometry) -> SIMD2<Double> {
        switch g {
        case .line:
            return g.point(min(max(g.parameter(of: p), 0), 1))
        case .circle(let c, let r):
            let d = p - c, len = simdLength(d)
            return len > 1e-12 ? c + d * (r / len) : c + SIMD2(r, 0)
        case .arc(_, _, _, let sweep):
            let t = g.parameter(of: p)
            if t <= 1 { return g.point(t) }
            // Beyond the ends: the nearer end.
            let a = g.point(0), b = g.point(1)
            _ = sweep
            return simdLength(p - a) < simdLength(p - b) ? a : b
        case .bezier(let ctrl):
            return Bezier.point(ctrl, Bezier.closest(p, ctrl))
        }
    }

    // MARK: input

    /// Returns (handled, commit action name). Unhandled drags orbit the camera.
    func handle(_ m: SketchMouse) -> (handled: Bool, commit: String?) {
        if let t = m.tolerance { tolerance = t }
        if m.phase == .moved || m.phase == .down {
            // What's exactly under the cursor, or else the nearest point or curve within a few
            // pixels: sketch lines are thin, and picking shouldn't need pixel precision.
            hover = entity(for: m.pick) ?? m.uv.flatMap { m.snapping ? nearestEntity($0) : nil }
        }
        gridStep = m.gridStep
        snapping = m.snapping
        if let uv = m.uv, tool != .select || dragEntity != nil { _ = snap(uv, excluding: dragEntity) } else { lastSnap = nil }
        if let uv = m.uv { cursor = uv }
        switch m.phase {
        case .moved: return (false, nil)
        case .down: return mouseDown(m)
        case .dragged: return (dragEntity != nil, drag(m))
        case .up:
            defer { dragEntity = nil; dragMoved = false }
            return (dragEntity != nil, dragEntity != nil && dragMoved ? "Move" : nil)
        }
    }

    private func mouseDown(_ m: SketchMouse) -> (handled: Bool, commit: String?) {
        message = nil
        switch tool {
        case .select:
            guard let h = hover else {
                if !m.additive { selection = [] }
                return (false, nil)  // empty space: let the view orbit
            }
            if m.additive {
                if let i = selection.firstIndex(of: h) { selection.remove(at: i) } else { selection.append(h) }
            } else if !selection.contains(h) {
                selection = [h]
            }
            if sketch.point(h)?.fixed != true {
                dragEntity = h
                if let uv = m.uv, case let (a, _)? = sketch.lineEnds(h) { dragOffset = uv - a }
                else if let uv = m.uv, sketch.kind(of: h) == .bezier, let c = sketch.curve(h),
                        let start = sketch.pointIDs(of: c).first.flatMap({ sketch.position($0) }) { dragOffset = uv - start }
                else { dragOffset = .zero }
            }
            return (true, nil)
        case .dimension:
            return (true, dimensionClick())
        case .trim, .extend:
            guard let h = hover, sketch.curve(h) != nil, let uv = m.uv else {
                message = "Click on a curve"
                return (true, nil)
            }
            let changed = tool == .trim ? sketch.trim(h, at: uv) : sketch.extend(h, near: uv)
            guard changed else {
                message = tool == .extend ? "There's nothing for that end to reach" : "Nothing to trim there"
                return (true, nil)
            }
            selection = selection.filter { sketch.kind(of: $0) != nil }
            return (true, finish(tool.rawValue))
        case .fillet:
            return (true, filletClick())
        default:
            guard let uv = m.uv else { return (true, nil) }
            return (true, toolClick(target() ?? snap(uv)))
        }
    }

    private func drag(_ m: SketchMouse) -> String? {
        guard let id = dragEntity, var uv = m.uv else { return nil }
        if sketch.point(id) != nil { uv = snap(uv, excluding: id).position }  // dragged points snap too (without constraints)
        if sketch.drag(id, to: uv, grabOffset: dragOffset, values: values) {
            dragMoved = true
            solve = SketchSolver.solve(&sketch, dimensionValues: values)
        }
        return nil
    }

    private func toolClick(_ s: SketchSnap) -> String? {
        for f in inputFields {
            if let v = typedValue(f), let text = typed[f] { pendingDimensions.append((f, Self.expression(text, f), v)) }
        }
        typed = [:]
        clicks.append(s)
        switch tool {
        case .line:
            guard clicks.count == 2 else { return nil }
            let start = clicks[0]
            guard distance(start, s) > 1e-6 else { clicks.removeLast(); pendingDimensions = []; return nil }
            let r = sketch.addLine(from: start, to: s, startPoint: chainPoint)
            addPendingDimensions([.length: .length(r.line)])
            // Keep chaining from the new end, unless we just connected to existing geometry.
            if s.point != nil || s.curve != nil {
                clicks = []
                chainPoint = nil
            } else {
                chainPoint = r.end
                clicks = [SketchSnap(sketch.position(r.end) ?? s.position, point: r.end)]
            }
            return finish("Line")
        case .rectangle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            let a = clicks[0].position, b = s.position
            guard abs(a.x - b.x) > 1e-6, abs(a.y - b.y) > 1e-6 else { pendingDimensions = []; return nil }
            let lines = sketch.addRectangle(from: clicks[0], to: s)  // bottom, right, top, left
            addPendingDimensions([.width: .length(lines[0]), .height: .length(lines[1])])
            return finish("Rectangle")
        case .circle, .circle2Point:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], s) > 1e-6 else { pendingDimensions = []; return nil }
            let circle = tool == .circle ? sketch.addCircle(center: clicks[0], through: s)
                                         : sketch.addCircle(diameterFrom: clicks[0], to: s)
            addPendingDimensions([.diameter: .diameter(circle)])
            return finish("Circle")
        case .arc:
            guard clicks.count == 3 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], clicks[1]) > 1e-6 else { pendingDimensions = []; return nil }
            let arc = sketch.addArc(center: clicks[0], start: clicks[1], end: s)
            addPendingDimensions([.radius: .radius(arc)])
            return finish("Arc")
        case .bezier:
            if clicks.count == 2, distance(clicks[0], s) <= 1e-6 { clicks.removeLast(); return nil }
            guard clicks.count == 3 else { return nil }
            defer { clicks = [] }
            sketch.addBezier(from: clicks[0], to: clicks[1], through: s.position)
            return finish("Curve")
        case .point:
            clicks = []
            guard s.point == nil else { return nil }
            _ = sketch.resolve(s)
            return finish("Point")
        case .text:
            clicks = []
            // On an existing text (its dot or its letters): change it rather than start another.
            if let anchor = s.point ?? hover, beginEditingText(anchoredAt: anchor) { return nil }
            pendingText = s
            return nil
        case .select, .dimension, .fillet, .trim, .extend:
            clicks = []
            return nil
        }
    }

    // MARK: typed values

    /// The fields for the current drawing step.
    var inputFields: [SketchInput] {
        switch (tool, clicks.count) {
        case (.line, 1): return [.length, .angle]
        case (.rectangle, 1): return [.width, .height]
        case (.circle, 1), (.circle2Point, 1): return [.diameter]
        case (.arc, 1): return [.radius]
        case (.arc, 2): return [.sweep]
        default: return []
        }
    }

    /// Sets (or, with empty text, clears) a typed value for the current step.
    func setTyped(_ field: SketchInput, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        typed[field] = t.isEmpty ? nil : t
    }

    func clearTyped() { typed = [:] }

    /// A typed value in base units (mm or radians); nil when nothing usable is typed.
    func typedValue(_ field: SketchInput) -> Double? {
        guard let text = typed[field], let v = try? parameters.value(of: text, kind: field.unit) else { return nil }
        if field.unit == .length, v <= 1e-9 { return nil }
        if field == .sweep, abs(v) <= 1e-9 { return nil }
        return v
    }

    /// Something is typed in the field but it can't be used (a typo, or a zero or negative size).
    func typedIsInvalid(_ field: SketchInput) -> Bool { typed[field] != nil && typedValue(field) == nil }

    /// Where the next click lands: the cursor's snap, moved to honour the typed values.
    func target() -> SketchSnap? {
        guard let cursor else { return nil }
        let s = snap(cursor)
        guard let first = clicks.first, inputFields.contains(where: { typedValue($0) != nil }) else { return s }
        let a = first.position, c = s.position, d = c - a
        let len = simdLength(d)
        let dir = len > 1e-9 ? d / len : SIMD2<Double>(1, 0)
        switch tool {
        case .line:
            let angle = typedValue(.angle) ?? (len > 1e-9 ? atan2(d.y, d.x) : 0)
            let length = typedValue(.length) ?? len
            return SketchSnap(a + length * SIMD2(cos(angle), sin(angle)))
        case .rectangle:
            let w = typedValue(.width) ?? abs(d.x), h = typedValue(.height) ?? abs(d.y)
            return SketchSnap(a + SIMD2(d.x < 0 ? -w : w, d.y < 0 ? -h : h))
        case .circle:
            return SketchSnap(a + dir * ((typedValue(.diameter) ?? 2 * len) / 2))
        case .circle2Point:
            return SketchSnap(a + dir * (typedValue(.diameter) ?? len))
        case .arc where clicks.count == 1:
            return SketchSnap(a + dir * (typedValue(.radius) ?? len))
        case .arc:
            let start = clicks[1].position - a
            let a0 = atan2(start.y, start.x)
            let sweep = typedValue(.sweep) ?? 0
            return SketchSnap(a + simdLength(start) * SIMD2(cos(a0 + sweep), sin(a0 + sweep)))
        default:
            return s
        }
    }

    /// The value a field shows: what the next click would give, in base units.
    func liveValue(_ field: SketchInput) -> Double? {
        if let v = typedValue(field) { return v }
        guard let t = target()?.position, let a = clicks.first?.position else { return nil }
        let d = t - a
        switch field {
        case .length, .radius: return simdLength(d)
        case .diameter: return tool == .circle2Point ? simdLength(d) : 2 * simdLength(d)
        case .width: return abs(d.x)
        case .height: return abs(d.y)
        case .angle:
            let angle = atan2(d.y, d.x)
            return angle < 0 ? angle + 2 * .pi : angle
        case .sweep:
            guard clicks.count > 1 else { return nil }
            let s = clicks[1].position - a
            var sweep = atan2(d.y, d.x) - atan2(s.y, s.x)
            while sweep <= 0 { sweep += 2 * .pi }
            return sweep
        }
    }

    /// Return in a field: place the next point from the typed values, as a click would.
    func commitTyped() -> String? {
        guard !inputFields.isEmpty, let t = target() else { return nil }
        message = nil
        return toolClick(t)
    }

    /// A bare number becomes "25 mm" / "30 deg"; anything else (units, parameters) is kept as typed.
    private static func expression(_ text: String, _ field: SketchInput) -> String {
        guard let v = Double(text) else { return text }
        return formatDimension(field.unit == .angle ? v * .pi / 180 : v, kind: field.unit)
    }

    /// Adds dimensions for the values typed while drawing the shape just created.
    private func addPendingDimensions(_ kinds: [SketchInput: SketchDimension.Kind]) {
        defer { pendingDimensions = [] }
        var v = values
        for p in pendingDimensions {
            guard let kind = kinds[p.input] else { continue }  // e.g. a line's angle: placed, not dimensioned
            let id = IDs.make()
            if sketch.applyDimension(kind, expression: p.expression, value: p.value, values: v, id: id) { v[id] = p.value }
        }
    }

    private func filletClick() -> String? {
        guard let h = hover, sketch.point(h) != nil else {
            message = "Click the corner point where two lines meet"
            return nil
        }
        // Try 2 mm, and fall back to a radius that fits short lines.
        for radius in [2.0, 1.0, 0.5, 0.2] {
            var trial = sketch
            if let dim = trial.filletCorner(h, radius: radius, expression: formatDimension(radius, kind: .length)) {
                var solved = trial
                var v = values
                v[dim] = radius
                guard SketchSolver.solve(&solved, dimensionValues: v).status == .solved else { continue }
                sketch = trial
                editingDimension = dim
                return finish("Round Corner")
            }
        }
        message = "That corner can't be rounded (it needs exactly two lines meeting at a point)"
        return nil
    }

    // MARK: offset

    var canOffset: Bool { selection.contains { sketch.curve($0) != nil } }

    func beginOffset() { if canOffset { offsetRequested = true } }

    /// Offsets the selected curves; positive distances go outward (or to the left of open chains).
    func offsetSelection(expression: String) -> String? {
        offsetRequested = false
        let distance: Double
        do { distance = try parameters.value(of: expression, kind: .length) } catch {
            message = "\(error)"
            return nil
        }
        guard abs(distance) > 1e-9 else { message = "The offset distance can't be zero"; return nil }
        var trial = sketch
        // Dimensions take the magnitude; the side comes from the sign.
        let magnitude = expression.trimmingCharacters(in: .whitespaces).hasPrefix("-")
            ? String(expression.trimmingCharacters(in: .whitespaces).dropFirst()) : expression
        let created = trial.offset(selection, distance: distance, expression: magnitude)
        guard !created.isEmpty else { message = "Nothing to offset in the selection"; return nil }
        var v = trial.dimensionValues(parameters)
        v.merge(values) { a, _ in a }
        guard SketchSolver.solve(&trial, dimensionValues: v).status == .solved else {
            message = "The offset couldn't be solved"
            return nil
        }
        sketch = trial
        selection = created
        return finish("Offset")
    }

    /// Dimension tool clicks. A line waits for a second click: the same line or empty space
    /// places its length, another line an angle, a point a distance. Circles and arcs take one click.
    private func dimensionClick() -> String? {
        let singleLine = dimensionPicks.count == 1 && sketch.kind(of: dimensionPicks[0]) == .line
        guard let h = hover else {
            if singleLine { return createDimension() }  // empty space: place the length
            dimensionPicks = []
            return nil
        }
        if singleLine, dimensionPicks[0] == h { return createDimension() }  // the same line again
        if !dimensionPicks.contains(h) { dimensionPicks.append(h) }
        return sketch.dimensionPickIsComplete(dimensionPicks) ? createDimension() : nil
    }

    /// The nearest sketch point within the pick tolerance, else the nearest curve.
    func nearestEntity(_ uv: SIMD2<Double>) -> EntityID? {
        var best: (EntityID, Double)?
        for p in sketch.points {
            let d = simdLength(p.position - uv)
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (p.id, d) }
        }
        if let best { return best.0 }
        for c in sketch.curves {
            guard let g = sketch.geometry(of: c.id) else { continue }
            let d = simdLength(Self.closest(uv, on: g) - uv)
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (c.id, d) }
        }
        return best?.0
    }

    // MARK: text

    /// Opens the typing box on the text anchored at a point (its dot; its letters pick the dot too),
    /// starting with its words. False if no text starts there.
    @discardableResult
    func beginEditingText(anchoredAt point: EntityID) -> Bool {
        guard let t = sketch.texts.first(where: { $0.position == point }), let at = sketch.position(point) else { return false }
        editingText = t.id
        pendingText = SketchSnap(at, point: point)
        selection = [point]
        dragEntity = nil
        return true
    }

    /// Return in the text field: the text starts at the clicked point (or the point it snapped to);
    /// when editing, the text's words change instead.
    func placeText(_ string: String) -> String? {
        defer { pendingText = nil; editingText = nil }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingText {
            guard !text.isEmpty else { message = "A text needs some letters"; return nil }
            return updateText(id) { $0.text = text }
        }
        guard let at = pendingText, !text.isEmpty else { return nil }
        let p = sketch.resolve(at)
        let t = SketchText(text: text, position: p)
        sketch.texts.append(t)
        selection = [p]
        return finish("Text")
    }

    func cancelText() { pendingText = nil; editingText = nil }

    /// Changes a text's words, height or font from the inspector.
    func updateText(_ id: EntityID, _ change: (inout SketchText) -> Void) -> String? {
        guard let i = sketch.texts.firstIndex(where: { $0.id == id }) else { return nil }
        var t = sketch.texts[i]
        change(&t)
        guard t != sketch.texts[i], !t.text.trimmingCharacters(in: .whitespaces).isEmpty,
              (try? parameters.value(of: t.height, kind: .length)).map({ $0 > 0 }) == true else {
            message = "A text needs some letters and a positive height"
            return nil
        }
        sketch.texts[i] = t
        return finish("Edit Text")
    }

    /// Letter outlines of the sketch's texts, with the index of each text's anchor point (for picking).
    func textOutlines() -> [(anchor: Int, polylines: [[SIMD2<Double>]])] {
        sketch.texts.compactMap { t in
            guard let i = sketch.points.firstIndex(where: { $0.id == t.position }) else { return nil }
            let polylines = t.contours(in: sketch, parameters: parameters).map { contour in
                contour.flatMap { TextOutline.flatten($0) }
            }
            return (i, polylines)
        }
    }

    // MARK: measurements shown for undimensioned geometry

    /// Lines, circles and arcs without a size dimension, with their current size: shown as light
    /// labels so every size is visible, and a click turns one into a dimension.
    var referenceMeasurements: [(curve: EntityID, kind: SketchDimension.Kind, value: Double)] {
        var sized = Set<EntityID>()
        var spans: [Set<EntityID>: EntityID] = [:]  // a rounded side's corner-to-corner span -> the line
        for c in sketch.curves { if let s = sketch.lineSpan(c.id) { spans[[s.0, s.1]] = c.id } }
        for d in sketch.dimensions {
            switch d.kind {
            case .length(let c), .radius(let c), .diameter(let c): sized.insert(c)
            case .distance(let a, let b): if let line = spans[[a, b]] { sized.insert(line) }
            default: break
            }
        }
        return sketch.curves.compactMap { c in
            guard !c.construction, !sized.contains(c.id), let s = sketch.suggestDimension(for: [c.id]) else { return nil }
            return (c.id, s.kind, s.value)
        }
    }

    /// Clicking a light measurement: add it as a dimension and open it for typing.
    func dimensionReference(_ curve: EntityID) -> String? {
        dimensionPicks = [curve]
        return createDimension()
    }

    /// While the Dimension tool waits after one line: its length, to show at the cursor.
    var pendingLineLength: Double? {
        guard tool == .dimension, dimensionPicks.count == 1, case let (a, b)? = sketch.lineEnds(dimensionPicks[0]) else { return nil }
        return simdLength(b - a)
    }

    private func createDimension() -> String? {
        defer { dimensionPicks = [] }
        guard let suggestion = sketch.suggestDimension(for: dimensionPicks) else {
            message = "Can't dimension that combination"
            return nil
        }
        let kind = suggestion.kind, value = suggestion.value
        let unit: UnitKind
        if case .angle = kind { unit = .angle } else { unit = .length }
        let id = IDs.make()
        guard sketch.applyDimension(kind, expression: formatDimension(value, kind: unit), value: value,
                                    values: values, id: id) else {
            message = "That dimension would over-constrain the sketch"
            return nil
        }
        editingDimension = id
        return finish("Dimension")
    }

    private func finish(_ action: String) -> String {
        resolve()
        return action
    }

    private func distance(_ a: SketchSnap, _ b: SketchSnap) -> Double {
        let d = b.position - a.position
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    // MARK: commands

    func select(_ id: EntityID, additive: Bool) {
        if tool != .select { setTool(.select) }
        if additive {
            if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    /// Esc: cancel the current tool step, then the tool, then the selection.
    func escape() {
        if editingDimension != nil { editingDimension = nil }
        else if !clicks.isEmpty || !dimensionPicks.isEmpty { resetToolState() }
        else if tool != .select { setTool(.select) }
        else { selection = [] }
    }

    func deleteSelection() -> String? {
        guard !selection.isEmpty else { return nil }
        sketch.delete(Set(selection))
        selection = []
        return finish("Delete")
    }

    func canApply(_ c: ConstraintTool) -> Bool { sketch.constraints(c, for: selection) != nil }

    func apply(_ c: ConstraintTool) -> String? {
        guard let kinds = sketch.constraints(c, for: selection) else { return nil }
        guard sketch.applyConstraints(kinds, values: values) else {
            message = "\(c.rawValue) would over-constrain the sketch"
            return nil
        }
        selection = []
        return finish(c.rawValue)
    }

    var canToggleConstruction: Bool { selection.contains { sketch.curve($0) != nil } }

    func toggleConstruction() -> String? {
        guard canToggleConstruction else { return nil }
        sketch.toggleConstruction(selection)
        return finish("Construction")
    }

    func deleteConstraint(_ id: EntityID) -> String? {
        sketch.delete([id])
        return finish("Delete Constraint")
    }

    /// Sets a dimension's expression; rejects values that can't be evaluated or solved.
    func setDimension(_ id: EntityID, expression: String) -> String? {
        guard let i = sketch.dimensions.firstIndex(where: { $0.id == id }) else { return nil }
        var trial = sketch
        trial.dimensions[i].expression = expression
        do {
            var v = values
            v[id] = try parameters.value(of: expression, kind: trial.dimensions[i].unitKind)
            // Moves what the dimension is about, not the whole sketch a little.
            guard SketchSolver.solveLocally(&trial, dimensionValues: v).status == .solved else {
                message = "The sketch can't take that value"
                return nil
            }
        } catch {
            message = "\(error)"
            return nil
        }
        sketch = trial
        editingDimension = nil
        return finish("Edit Dimension")
    }

    // MARK: display

    /// Rubber-band geometry for the tool in progress, in sketch coordinates.
    func previewPolylines() -> [[SIMD2<Double>]] {
        guard !clicks.isEmpty, let c = target()?.position else { return [] }
        let a = clicks[0].position
        switch tool {
        case .line: return [[a, c]]
        case .rectangle: return [[a, SIMD2(c.x, a.y), c, SIMD2(a.x, c.y), a]]
        case .circle:
            let r = simdLength(c - a)
            return [circle(a, r, 0, 2 * .pi)]
        case .circle2Point:
            return [circle((a + c) / 2, simdLength(c - a) / 2, 0, 2 * .pi), [a, c]]
        case .bezier:
            // Straight until the end is placed; then the curve bends through the cursor.
            guard clicks.count > 1 else { return [[a, c]] }
            let e = clicks[1].position, push = (c - (a + e) / 2) / 0.75
            let ctrl = [a, a + (e - a) / 3 + push, a + (e - a) * 2 / 3 + push, e]
            return [Bezier.flatten(ctrl), [a, ctrl[1]], [e, ctrl[2]]]
        case .arc:
            let r = simdLength(clicks.count > 1 ? clicks[1].position - a : c - a)
            if clicks.count == 1 { return [[a, c]] }
            let a0 = atan2(clicks[1].position.y - a.y, clicks[1].position.x - a.x)
            var a1 = atan2(c.y - a.y, c.x - a.x)
            while a1 <= a0 { a1 += 2 * .pi }
            return [[a, clicks[1].position], circle(a, r, a0, a1)]
        default: return []
        }
    }

    func circle(_ c: SIMD2<Double>, _ r: Double, _ a0: Double, _ a1: Double) -> [SIMD2<Double>] {
        let n = max(8, Int(abs(a1 - a0) / (2 * .pi) * 96))
        return (0...n).map { i in
            let t = a0 + (a1 - a0) * Double(i) / Double(n)
            return c + r * SIMD2(cos(t), sin(t))
        }
    }

    var statusText: String {
        if let message { return message }
        var s = tool.hint
        if let snap = lastSnap { s = "Snap: \(snap.kind.rawValue)\(snap.kind == .grid ? " \(gridStep.map { formatDimension($0, kind: .length) } ?? "")" : "") · " + s }
        if !inputFields.isEmpty {
            s = "Type a value, Tab for the next one, Return to place it · " + s
        }
        if let solve {
            switch solve.status {
            case .failed: s = "Over-constrained · " + s
            case .solved: s = (solve.degreesOfFreedom == 0 ? "Fully constrained" : "\(solve.degreesOfFreedom) DOF") + " · " + s
            }
        }
        return s
    }
}

func simdLength(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }

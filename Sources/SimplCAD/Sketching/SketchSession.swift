// Interactive sketch editing: tools, snapping, selection, dragging and dimensions.
// Geometry operations live in CADCore (SketchEditing.swift); this is the UI state machine.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Observation

enum SketchTool: String, CaseIterable, Identifiable {
    case select = "Select", line = "Line", rectangle = "Rectangle", circle = "Circle", arc = "Arc"
    case point = "Point", fillet = "Fillet", trim = "Trim", extend = "Extend", dimension = "Dimension"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arc: return "circle.bottomhalf.filled"
        case .point: return "smallcircle.filled.circle"
        case .fillet: return "arrow.turn.up.right"
        case .trim: return "scissors"
        case .extend: return "arrow.right.to.line"
        case .dimension: return "ruler"
        }
    }
    /// Single-key shortcut while the viewport has focus.
    var key: Character {
        switch self {
        case .select: return "s"
        case .line: return "l"
        case .rectangle: return "r"
        case .circle: return "c"
        case .arc: return "a"
        case .point: return "p"
        case .fillet: return "f"
        case .trim: return "t"
        case .extend: return "e"
        case .dimension: return "d"
        }
    }
    var hint: String {
        switch self {
        case .select: return "Click to select, drag points or curves to move them, ⌫ deletes"
        case .line: return "Click points to draw connected lines · Esc ends the chain"
        case .rectangle: return "Click two opposite corners"
        case .circle: return "Click the center, then a point on the circle"
        case .arc: return "Click the center, the start, then the end (counter-clockwise)"
        case .point: return "Click to place a point"
        case .fillet: return "Click a corner where two lines meet to round it"
        case .trim: return "Click the part of a curve to remove (up to where other curves cross it)"
        case .extend: return "Click near the end of a line or arc to extend it to the next curve"
        case .dimension: return "Click a line, circle, or two entities · click empty space to place a line length"
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
        resetToolState()
    }
    var selection: [EntityID] = []
    private(set) var hover: EntityID?
    /// Set by the Offset command to ask the toolbar to show the offset distance popover.
    var offsetRequested = false
    private(set) var cursor: SIMD2<Double>?
    private(set) var clicks: [SketchSnap] = []
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
        solve = SketchSolver.solve(&sketch, dimensionValues: values)
    }

    private func resetToolState() {
        clicks = []
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

    func pickID(for id: EntityID) -> PickID? {
        if let i = sketch.points.firstIndex(where: { $0.id == id }) { return PickID(sketchPoint: i) }
        if let i = sketch.curves.firstIndex(where: { $0.id == id }) { return PickID(sketchCurve: i) }
        return nil
    }

    /// Snap for the cursor: onto the hovered point, or onto the hovered curve.
    func snap(_ uv: SIMD2<Double>) -> SketchSnap {
        guard let h = hover else { return SketchSnap(uv) }
        if let p = sketch.point(h) { return SketchSnap(p.position, point: h) }
        if sketch.curve(h) != nil { return SketchSnap(uv, curve: h) }
        return SketchSnap(uv)
    }

    // MARK: input

    /// Returns (handled, commit action name). Unhandled drags orbit the camera.
    func handle(_ m: SketchMouse) -> (handled: Bool, commit: String?) {
        if m.phase == .moved || m.phase == .down { hover = entity(for: m.pick) }
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
                if let uv = m.uv, case let (a, _)? = sketch.lineEnds(h) { dragOffset = uv - a } else { dragOffset = .zero }
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
        guard let id = dragEntity, let uv = m.uv else { return nil }
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
        case .circle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], s) > 1e-6 else { pendingDimensions = []; return nil }
            let circle = sketch.addCircle(center: clicks[0], through: s)
            addPendingDimensions([.diameter: .diameter(circle)])
            return finish("Circle")
        case .arc:
            guard clicks.count == 3 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], clicks[1]) > 1e-6 else { pendingDimensions = []; return nil }
            let arc = sketch.addArc(center: clicks[0], start: clicks[1], end: s)
            addPendingDimensions([.radius: .radius(arc)])
            return finish("Arc")
        case .point:
            clicks = []
            guard s.point == nil else { return nil }
            _ = sketch.resolve(s)
            return finish("Point")
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
        case (.circle, 1): return [.diameter]
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
        case .diameter: return 2 * simdLength(d)
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
                return finish("Fillet")
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

    private func dimensionClick() -> String? {
        guard let h = hover else {
            // Empty space: a single picked line gets its length.
            if dimensionPicks.count == 1, sketch.kind(of: dimensionPicks[0]) == .line { return createDimension() }
            dimensionPicks = []
            return nil
        }
        if !dimensionPicks.contains(h) { dimensionPicks.append(h) }
        return sketch.dimensionPickIsComplete(dimensionPicks) ? createDimension() : nil
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
            guard SketchSolver.solve(&trial, dimensionValues: v).status == .solved else {
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

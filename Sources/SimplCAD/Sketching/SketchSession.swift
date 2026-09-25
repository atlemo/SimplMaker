// Interactive sketch editing: tools, snapping, selection, dragging and dimensions.
// Geometry operations live in CADCore (SketchEditing.swift); this is the UI state machine.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Observation

enum SketchTool: String, CaseIterable, Identifiable {
    case select = "Select", line = "Line", rectangle = "Rectangle", circle = "Circle", arc = "Arc"
    case point = "Point", dimension = "Dimension"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arc: return "circle.bottomhalf.filled"
        case .point: return "smallcircle.filled.circle"
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
        case .dimension: return "Click a line, circle, or two entities · click empty space to place a line length"
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
    private(set) var cursor: SIMD2<Double>?
    private(set) var clicks: [SketchSnap] = []
    private var chainPoint: EntityID?
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
        dimensionPicks = []
        message = nil
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
        default:
            guard let uv = m.uv else { return (true, nil) }
            return (true, toolClick(snap(uv)))
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
        clicks.append(s)
        switch tool {
        case .line:
            guard clicks.count == 2 else { return nil }
            let start = clicks[0]
            guard distance(start, s) > 1e-6 else { clicks.removeLast(); return nil }
            let r = sketch.addLine(from: start, to: s, startPoint: chainPoint)
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
            guard abs(a.x - b.x) > 1e-6, abs(a.y - b.y) > 1e-6 else { return nil }
            sketch.addRectangle(from: clicks[0], to: s)
            return finish("Rectangle")
        case .circle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], s) > 1e-6 else { return nil }
            sketch.addCircle(center: clicks[0], through: s)
            return finish("Circle")
        case .arc:
            guard clicks.count == 3 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], clicks[1]) > 1e-6 else { return nil }
            sketch.addArc(center: clicks[0], start: clicks[1], end: s)
            return finish("Arc")
        case .point:
            clicks = []
            guard s.point == nil else { return nil }
            _ = sketch.resolve(s)
            return finish("Point")
        case .select, .dimension:
            clicks = []
            return nil
        }
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
        guard let cursor, !clicks.isEmpty else { return [] }
        let c = snap(cursor).position
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

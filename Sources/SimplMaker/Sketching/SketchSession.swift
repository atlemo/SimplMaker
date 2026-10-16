// Interactive sketch editing: tools, snapping, selection, dragging and dimensions.
// Geometry operations live in CADCore (SketchEditing.swift); this is the UI state machine.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd
import Observation

/// The sketch tools that change existing geometry as a whole, each with a popover for its values.
enum SketchTransformTool: String, CaseIterable, Identifiable {
    case move = "Move", scale = "Scale", pattern = "Pattern", mirror = "Mirror"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .move: return "move"
        case .scale: return "scaling"
        case .pattern: return "pattern"
        case .mirror: return "flip-horizontal-2"
        }
    }

    var help: String {
        switch self {
        case .move: return "Move or rotate the selected curves (or the whole sketch): drag the arrows, the square or the ring, or type a distance or an angle"
        case .scale: return "Make the selected curves (or the whole sketch) bigger or smaller"
        case .pattern: return "Copy the selected curves (or the whole sketch) in a grid or around a point: drag the arrows or the ring, or type the counts and spacing"
        case .mirror: return "Mirror the selected curves (or the whole sketch) across a line, a construction line, a projected edge or an axis; the mirror image stays linked to what it copies"
        }
    }
}

extension SketchPatternDef.Kind {
    var title: String { self == .rectangular ? "Rectangular" : "Circular" }
}

/// What Rotate and Scale turn or grow about.
enum TransformPivot: String, CaseIterable, Identifiable {
    case selection = "Middle of selection", origin = "Sketch origin"
    var id: String { rawValue }
}

enum SketchTool: String, CaseIterable, Identifiable {
    case select = "Select", line = "Line", rectangle = "Rectangle", centerRectangle = "Center Rectangle", slot = "Slot"
    case roundedRectangle = "Rounded Rectangle", overallSlot = "Overall Slot"
    case circle = "Circle", circle2Point = "2-Point Circle", arc = "Arc", arc3Point = "3-Point Arc", bezier = "Spline"
    case tangentArc = "Tangent Arc", ellipse = "Ellipse"
    case polygon = "Polygon", triangle = "Triangle", gear = "Gear"
    case point = "Point", text = "Text", fillet = "Round Corner", chamfer = "Chamfer", trim = "Trim", extend = "Extend", dimension = "Dimension"
    case distance = "Distance"

    var id: String { rawValue }

    /// The two slot tools: centers at the ends (Slot), or the outside ends (Overall Slot).
    var drawsSlot: Bool { self == .slot || self == .overallSlot }

    /// Toolbar groups: drawing, changing curves, and dimensions (Select stands alone).
    static let draw: [SketchTool] = [.line, .rectangle, .centerRectangle, .roundedRectangle, .slot, .overallSlot, .circle, .circle2Point, .polygon, .triangle, .arc, .arc3Point, .tangentArc, .ellipse, .bezier, .gear, .point, .text]
    static let modify: [SketchTool] = [.fillet, .chamfer, .trim, .extend]

    /// The name under the icon in the toolbar (menus use the full `rawValue`).
    var shortTitle: String {
        switch self {
        case .fillet: return "Corner"
        case .circle2Point: return "Circle"
        case .centerRectangle: return "Rectangle"
        case .arc3Point: return "Arc"
        default: return rawValue
        }
    }

    /// Tools whose clicks place points (and so snap to shape centers).
    var placesPoints: Bool {
        switch self {
        case .line, .rectangle, .centerRectangle, .roundedRectangle, .slot, .overallSlot, .circle, .circle2Point, .polygon, .triangle, .arc, .arc3Point, .tangentArc, .ellipse, .bezier, .gear, .point, .text: return true
        case .select, .fillet, .chamfer, .trim, .extend, .dimension, .distance: return false
        }
    }

    /// Tools that share a toolbar button and a key: the ways to draw one kind of shape.
    var family: [SketchTool] {
        switch self {
        case .rectangle, .centerRectangle, .roundedRectangle: return [.rectangle, .centerRectangle, .roundedRectangle]
        case .slot, .overallSlot: return [.slot, .overallSlot]
        case .circle, .circle2Point: return [.circle, .circle2Point]
        case .polygon, .triangle: return [.polygon, .triangle]
        case .arc, .arc3Point: return [.arc, .arc3Point]
        default: return [self]
        }
    }

    /// Its name among the others in its family, in the toolbar's chooser.
    var modeTitle: String {
        switch self {
        case .rectangle: return "2-Point"
        case .centerRectangle: return "Center"
        case .roundedRectangle: return "Rounded"
        case .slot: return "Center"
        case .overallSlot: return "Overall"
        case .circle: return "Center"
        case .circle2Point: return "2-Point"
        case .polygon: return "Polygon"
        case .triangle: return "Triangle"
        case .arc: return "Center"
        case .arc3Point: return "3-Point"
        default: return shortTitle
        }
    }

    var isCircle: Bool { family.contains(.circle) }

    /// The tool for a key press: pressing the key again switches to the next way of drawing that shape.
    static func forKey(_ key: Character, current: SketchTool) -> SketchTool? {
        guard let tool = allCases.first(where: { $0.key == key }) else { return nil }  // a family's first tool holds the key
        let family = tool.family
        if family.count > 1, let i = family.firstIndex(of: current) { return family[(i + 1) % family.count] }
        return tool
    }

    /// Tools still being tried out: the Draw list marks them, and their tooltip says so.
    var isExperimental: Bool { self == .gear }

    /// Tooltip: the name, its key, and what it does.
    var help: String {
        let name = (keyLabel.map { "\(rawValue) (\($0))" } ?? rawValue) + (isExperimental ? " · Experimental" : "")
        switch self {
        case .fillet: return "\(name): round a sketch corner where two lines meet, with an arc and a radius. For rounding edges of a solid, use Fillet in Design mode."
        default: return "\(name): \(hint)"
        }
    }

    /// A glyph name from the macOS Design System's icon set (see IconGlyphs.swift), not an SF Symbol.
    var symbol: String {
        switch self {
        case .select: return "mouse-pointer-2"
        case .line: return "minus"
        case .rectangle: return "square"
        case .centerRectangle: return "square-center"
        case .slot: return "slot"
        case .overallSlot: return "slot-overall"
        case .roundedRectangle: return "square-rounded"
        case .tangentArc: return "tangent-arc"
        case .ellipse: return "ellipse"
        case .arc3Point: return "arc-3-point"
        case .circle: return "circle"
        case .circle2Point: return "diameter"
        case .polygon: return "hexagon"
        case .triangle: return "triangle"
        case .arc: return "spline"
        case .bezier: return "bezier"
        case .gear: return "settings"
        case .point: return "dot"
        case .text: return "type"
        case .fillet: return "corner-round"
        case .chamfer: return "corner-chamfer"
        case .trim: return "scissors"
        case .extend: return "arrow-up-right"
        case .dimension: return "ruler"
        case .distance: return "dimension-line"
        }
    }
    /// The key now, while the viewport has focus. The user can change it (see Shortcuts.swift), and
    /// a family shares one key, held by its first tool.
    var key: Character? { Shortcuts.chord(.sketch(family[0]))?.key }
    var keyLabel: String? { key.map { String($0).uppercased() } }
    /// What the key is until the user changes it.
    var defaultKey: Character {
        switch self {
        case .select: return "s"
        case .line: return "l"
        case .rectangle, .centerRectangle: return "r"
        case .slot, .overallSlot: return "o"
        case .roundedRectangle: return "r"
        case .tangentArc: return "n"
        case .ellipse: return "j"
        case .circle, .circle2Point: return "c"
        case .polygon, .triangle: return "g"
        case .arc, .arc3Point: return "a"
        case .bezier: return "b"
        case .gear: return "k"
        case .point: return "p"
        case .text: return "x"
        case .fillet: return "f"
        case .chamfer: return "h"
        case .trim: return "t"
        case .extend: return "e"
        case .dimension: return "d"
        case .distance: return "i"
        }
    }
    /// "R again": pressing the key a second time picks the next way of drawing the shape.
    private var again: String { keyLabel.map { "\($0) again" } ?? "The key again" }

    var hint: String {
        switch self {
        case .select: return "Click to select, double-click for all joined curves, drag to move, ⌫ deletes"
        case .line: return "Click points to draw connected lines · Esc ends the chain"
        case .rectangle: return "Click two opposite corners · \(again) for a center rectangle"
        case .centerRectangle: return "Click the center, then a corner · \(again) for rounded corners"
        case .roundedRectangle: return "Click two opposite corners, rounded by the radius (type it first or after) · \(again) for two corners"
        case .ellipse: return "Click the center, then the end of one axis, then how far the other axis reaches · the axes stay square"
        case .tangentArc: return "Click the free end of a line or arc, then where the arc ends · it carries on smoothly from that end · click again to keep going"
        case .slot: return "Click the center of one end, then the center of the other · type the width first or after · \(again) for overall length"
        case .overallSlot: return "Click the two outside ends of the slot · type the width or the overall length · \(again) for center to center"
        case .circle: return "Click the center, then a point on the circle · \(again) for 2-point"
        case .circle2Point: return "Click two points on opposite sides of the circle · \(again) for center"
        case .polygon: return "Click the center, then a corner · type the number of sides, or press ↑ ↓ · \(again) for a triangle"
        case .triangle: return "Click the center, then a corner · \(again) for a polygon with any number of sides"
        case .arc: return "Click the center, the start, then the end (counter-clockwise) · \(again) for 3-point"
        case .arc3Point: return "Click the start, the end, then a point the arc passes through · \(again) for center"
        case .bezier: return "Click points to draw a smooth spline through them, or press and drag to pull a handle · click the first point to close it · Esc ends the spline"
        case .gear: return "Click where the center goes · set the teeth, module, pressure angle, backlash and bore before or after · gears that mesh share a module · click a gear to change it"
        case .point: return "Click to place a point"
        case .text: return "Click where the text starts, type it, and press Return · click a text (or double-click it) to change its words"
        case .fillet: return "Click the corner point where two lines meet to round it with an arc"
        case .chamfer: return "Click the corner point where two lines meet to cut it straight across · its leg length is then editable"
        case .trim: return "Click the part of a curve to remove (up to where other curves cross it)"
        case .extend: return "Click near the end of a line or arc to extend it to the next curve"
        case .dimension: return "Click a line (then click again to place its length), a circle or arc, or two items for a distance or angle · or click any grey size"
        case .distance: return "Click two items (points, lines, circles or arcs), then type the distance between them · a circle is measured from its edge, its center point from the middle"
        }
    }
}

/// A value the user can type while drawing, instead of placing the next point with the mouse.
enum SketchInput: String, CaseIterable, Identifiable {
    case length = "Length", angle = "Angle", width = "Width", height = "Height"
    case diameter = "Diameter", radius = "Radius", sweep = "Sweep"
    /// How many sides a polygon has.
    case sides = "Sides"
    /// What Gear takes: tooth count, tooth size (mm), flank angle, thinning of each tooth (mm) and the hole through the middle.
    case teeth = "Teeth", module = "Module", pressureAngle = "Pressure angle", backlash = "Backlash", bore = "Bore"
    /// What Move takes, for the manipulator: how far along x and y, and how far to turn.
    case moveX = "Move X", moveY = "Move Y", turn = "Rotate"
    /// What Pattern takes: how many copies (the original counts) and how far apart.
    case countX = "Count X", spacingX = "Spacing X", countY = "Count Y", spacingY = "Spacing Y"
    case copies = "Count", spread = "Spread over"
    /// What Offset takes: how far from the curves, to the side its arrow points (negative: the other side).
    case offsetDistance = "Distance"

    var id: String { rawValue }
    var unit: UnitKind {
        switch self {
        case .angle, .sweep, .turn, .spread, .pressureAngle: return .angle
        case .countX, .countY, .copies, .sides, .teeth: return .none
        default: return .length
        }
    }
    /// Whether zero and negative values mean something (a move back, a turn clockwise).
    var isOffset: Bool { [.moveX, .moveY, .turn, .spacingX, .spacingY, .spread, .offsetDistance, .backlash, .bore].contains(self) }
    /// A whole number of copies.
    var isCount: Bool { self == .countX || self == .countY || self == .copies }
    /// Short label shown in front of the field.
    var symbol: String {
        switch self {
        case .length: return "L"
        case .angle, .sweep, .turn: return "∠"
        case .moveX: return "X"
        case .moveY: return "Y"
        case .countX: return "#X"
        case .countY: return "#Y"
        case .copies: return "#"
        case .spacingX: return "↔"
        case .spacingY: return "↕"
        case .spread: return "∠"
        case .offsetDistance: return "d"
        case .width: return "W"
        case .height: return "H"
        case .diameter: return "⌀"
        case .radius: return "R"
        case .sides: return "#"
        case .teeth: return "#"
        case .module: return "m"
        case .pressureAngle: return "∠"
        case .backlash: return "±"
        case .bore: return "⌀"
        }
    }
    var isGear: Bool { [.teeth, .module, .pressureAngle, .backlash, .bore].contains(self) }
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
    /// For each segment and point: the straight model edge it belongs to, which a sketch can follow
    /// (nil for the parts of a curved edge).
    var segmentModels: [ModelSnap?] = []
    var points: [SIMD2<Double>] = []
    var pointModels: [ModelSnap?] = []

    func segmentModel(_ i: Int) -> ModelSnap? { i < segmentModels.count ? segmentModels[i] : nil }
    func pointModel(_ i: Int) -> ModelSnap? { i < pointModels.count ? pointModels[i] : nil }
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
    private(set) var tool: SketchTool = .select

    func setTool(_ t: SketchTool) {
        if t != .select { stopManipulating(); cancelPattern(); cancelMirror(); cancelOffset() }
        if t != .gear || tool != .gear { gearBackup = nil; gearActive = nil }  // what the fields did stays, with the next change
        tool = t
        if t.family.count > 1 { lastInFamily[t.family[0]] = t }
        resetToolState()
    }
    /// The way of drawing each kind of shape that its toolbar button picks: the one used last.
    private var lastInFamily: [SketchTool: SketchTool] = [:]
    func mode(of tool: SketchTool) -> SketchTool { lastInFamily[tool.family[0]] ?? tool.family[0] }
    var circleMode: SketchTool { mode(of: .circle) }
    /// How many sides the Polygon tool draws (kept from one polygon to the next).
    private(set) var polygonSides = 6
    /// How many sides the polygon being drawn has: three for the Triangle tool.
    var sidesCount: Int { tool == .triangle ? 3 : polygonSides }
    var drawsPolygon: Bool { tool == .polygon || tool == .triangle }
    /// The width the Slot tool draws, as typed (kept from one slot to the next).
    private(set) var slotWidth = "10 mm"
    var slotWidthValue: Double { (try? parameters.value(of: slotWidth, kind: .length)) ?? 10 }
    /// The corner radius the Rounded Rectangle tool draws (kept from one rectangle to the next).
    private(set) var roundedRadius = "5 mm"
    var roundedRadiusValue: Double { (try? parameters.value(of: roundedRadius, kind: .length)) ?? 5 }
    /// What the next gear will be (kept from one gear to the next); its id and centre are not used.
    private(set) var gearDefaults = SketchGearDef()
    /// The gear the Gear tool's fields are changing: the one just placed, or one clicked in Select.
    private(set) var gearActive: EntityID?
    /// The sketch as it was before the fields changed the active gear, to go back to (Esc).
    @ObservationIgnored private var gearBackup: Sketch?
    var activeGear: SketchGearDef? { gearActive.flatMap { id in sketch.gears.first { $0.id == id } } }
    /// The gear whose values the fields show: the active one, else what the next one will be.
    private var gearShown: SketchGearDef { activeGear ?? gearDefaults }

    /// Where the Gear tool's fields stand: beside the active gear's right side, so they don't cover it.
    var gearAnchor: SIMD2<Double>? {
        guard tool == .gear, let g = activeGear, let c = sketch.position(g.center) else { return nil }
        return c + SIMD2((try? g.spec(parameters).tipRadius) ?? 0, 0)
    }

    /// Changes a value of the next gear and, if one is active, of that gear too (drawn again at once).
    private func setGear(_ field: SketchInput, _ expression: String) {
        func apply(_ g: inout SketchGearDef) {
            switch field {
            case .teeth: g.teeth = expression
            case .module: g.module = expression
            case .pressureAngle: g.pressureAngle = expression
            case .backlash: g.backlash = expression
            case .bore: g.bore = expression
            default: break
            }
        }
        apply(&gearDefaults)
        guard let i = sketch.gears.firstIndex(where: { $0.id == gearActive }) else { return }
        if gearBackup == nil { gearBackup = sketch }
        apply(&sketch.gears[i])
        let problems = sketch.refreshGenerated(parameters)
        message = problems[sketch.gears[i].id]
    }

    /// The fields have changed the active gear and it is not yet kept (the last rebuild still has the old gear).
    var hasPendingGearEdit: Bool { gearBackup != nil }

    /// What the fields did to the active gear is to be kept: the action name to commit it under, or nil if nothing changed.
    func keepGearEdit() -> String? {
        guard gearBackup != nil else { return nil }
        gearBackup = nil
        return "Edit Gear"
    }

    /// Takes back what the fields did to the active gear.
    func cancelGearEdit() {
        guard let backup = gearBackup else { return }
        sketch = backup
        gearBackup = nil
        message = nil
    }

    /// Deletes the active gear (its centre too, if the Gear tool made it and nothing else uses it).
    private func deleteActiveGear() -> String? {
        guard let id = gearActive else { return nil }
        cancelGearEdit()
        sketch.removeGear(id)
        gearActive = nil
        typed = [:]
        return finish("Delete Gear")
    }

    /// Gives the Polygon tool more or fewer sides (↑ ↓).
    func adjustSides(by delta: Int) {
        guard tool == .polygon else { return }
        polygonSides = min(max(polygonSides + delta, Sketch.polygonSides.lowerBound), Sketch.polygonSides.upperBound)
        typed[.sides] = nil
    }
    var selection: [EntityID] = []
    private(set) var hover: EntityID?
    /// Set by Scale to ask the toolbar to show that tool's popover.
    var transformRequested: SketchTransformTool?
    /// Move is on (it slides and turns): the manipulator sits on the selection (or the whole sketch) for dragging it.
    private(set) var manipulating: SketchTransformTool?
    /// How far the manipulator has moved (x, y, mm) and turned (z, radians) the selection, while dragging or typing.
    private(set) var manipulatorValues = TransformValues()
    /// The sketch as it was when the drag or the typing began, and the middle the turn is about.
    @ObservationIgnored private var manipulatorBase: Sketch?
    @ObservationIgnored private var manipulatorPivot = SIMD2<Double>.zero
    private(set) var cursor: SIMD2<Double>?
    private(set) var clicks: [SketchSnap] = []
    /// Where the Text tool was clicked: waiting for the text to be typed.
    private(set) var pendingText: SketchSnap?
    /// The text whose words are being changed in place (the typing box starts with them).
    private(set) var editingText: EntityID?
    /// What the typing box starts with: the words of the text being edited, or nothing for a new one.
    var textEntryInitial: String { editingText.flatMap { id in sketch.texts.first { $0.id == id }?.text } ?? "" }
    private var chainPoint: EntityID?
    /// The Curve tool's run of curves so far (nil until its second point is placed).
    private(set) var curveChain: CurveChain?
    /// The Curve tool's mouse is down on this point (a curve point is placed when it comes up).
    private var curveDown: SketchSnap?
    /// The handle pulled out of that point so far, and of the run's first point once that is placed.
    private var curvePull: SIMD2<Double>?
    private var curveFirstPull: SIMD2<Double>?
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
    /// A dimension line being dragged to a new place, and the one the cursor is over.
    private var dragDimension: EntityID?
    private(set) var hoverDimension: EntityID?
    /// What a dragged point last snapped to; a model edge or corner it is dropped on is followed from then on.
    private var dragSnap: SketchSnap?

    /// Model edges and corners in the sketch plane, for snapping (kept up to date by the model).
    @ObservationIgnored var references = SketchReferences()
    @ObservationIgnored private var tolerance = 0.5
    /// How far the cursor snaps, in mm at the current zoom (a few pixels).
    var snapTolerance: Double { tolerance }
    /// How many mm one screen pixel is on the sketch plane at the current zoom; 0 until the viewport has said.
    private(set) var mmPerPixel = 0.0

    /// The viewport tells the zoom: sizes drawn at a fixed number of pixels, and what is too small to be worth
    /// showing, follow it. True if it changed enough that the overlay should be made again.
    @discardableResult
    func setViewScale(mmPerPixel mm: Double) -> Bool {
        guard mm.isFinite, mm > 0, abs(mm - mmPerPixel) > 0.02 * mm else { return false }
        mmPerPixel = mm
        tolerance = 8 * mm
        return true
    }
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
        offsetSetup = nil
        offsetBase = nil
        offsetProblem = nil
        patternSetup = nil
        patternBase = nil
        patternBackup = nil
        mirrorSetup = nil
        mirrorBase = nil
        mirrorBackup = nil
        gearBackup = nil
        sketch = s
        self.parameters = parameters
        if gearActive != nil, activeGear == nil { gearActive = nil }
        if let chain = curveChain, !s.contains(chain) { resetToolState() }  // undone: start the curve again
        selection = selection.filter { s.kind(of: $0) != nil }
        if let d = editingDimension, !s.dimensions.contains(where: { $0.id == d }) { editingDimension = nil }
        resolve()
    }

    /// Moves the sketch's projected model edges to where the model has them now, and re-solves, so
    /// what is tied to them follows. Not written to the document until the next edit.
    func followModel(_ r: RegenResult) {
        guard !sketch.projections.isEmpty, patternBase == nil, mirrorBase == nil else { return }
        var next = sketch
        guard (try? Regenerator.followProjections(&next, frame: frame, r)) != nil, next != sketch else { return }
        sketch = next
        resolve()
    }

    private func resolve() {
        values = sketch.dimensionValues(parameters)
        solve = SketchSolver.solveLocally(&sketch, dimensionValues: values)
        refreshCopies()
    }

    /// Makes the pattern copies again after the originals changed.
    private func refreshCopies() {
        if !sketch.patterns.isEmpty || !sketch.gears.isEmpty || !sketch.mirrors.isEmpty { sketch.refreshGenerated(parameters) }
    }

    private func resetToolState() {
        clicks = []
        pendingText = nil
        editingText = nil
        chainPoint = nil
        curveChain = nil
        curveDown = nil
        curvePull = nil
        curveFirstPull = nil
        typed = [:]
        pendingDimensions = []
        dimensionPicks = []
        message = nil
    }

    var hoverEntity: EntityID? { hover }
    var hoverIsDraggable: Bool {
        if hover == nil, hoverDimension != nil { return true }
        guard let hover, !Sketch.isGenerated(hover) else { return false }
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
        setLastSnap(result.kind.map { ($0, result.snap.position) })
        return result.snap
    }

    /// Records the latest snap, only when it differs. The viewport's update asks for the rubber-band preview, which
    /// snaps; assigning the same value again still notifies whoever read `lastSnap` (the overlay does, in the same
    /// update), so every update would start another one and the viewport would redraw without end.
    private func setLastSnap(_ new: (kind: SnapKind, position: SIMD2<Double>)?) {
        guard lastSnap?.kind != new?.kind || lastSnap?.position != new?.position else { return }
        lastSnap = new
    }

    private func findSnap(_ uv: SIMD2<Double>, excluding: EntityID?) -> (snap: SketchSnap, kind: SnapKind?) {
        // A curve being drawn doesn't snap to its own handles or segments, which lie close to the next point.
        let drawn = curveChain?.owned ?? []
        if let h = hover, h != excluding, !drawn.contains(h), let p = sketch.point(h) { return (SketchSnap(p.position, point: h), .point) }
        guard snapping else {
            if let h = hover, h != excluding, !drawn.contains(h), sketch.curve(h) != nil { return (SketchSnap(uv, curve: h), .curve) }
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
        let own = (excluding.map { Set([$0] + (sketch.curve($0).map { sketch.pointIDs(of: $0) } ?? [])) } ?? []).union(drawn)
        if let p = nearest(sketch.points.filter { !own.contains($0.id) && !Sketch.isGenerated($0.id) }, { $0.position }) {
            return (SketchSnap(p.position, point: p.id), sketch.curves.contains { c in
                if case .circle(let center, _) = c.geometry { return center == p.id }
                if case .arc(let center, _, _) = c.geometry { return center == p.id }
                return false
            } ? .center : .point)
        }
        // The middle of a closed shape (not one being dragged): a point placed there stays centred.
        let centers = shapeCenters().filter { own.isDisjoint(with: $0.points) && !$0.points.contains(where: Sketch.isGenerated) }
        if let c = nearest(centers, { $0.position }) { return (SketchSnap(c.position, centerOf: c.corners), .center) }
        let positions = sketch.positionTable()  // looked up by id, not by scanning, for every line and curve below
        let lines = sketch.curves.compactMap { c -> SIMD2<Double>? in
            guard !own.contains(c.id), !Sketch.isGenerated(c.id), case .line(let a, let b) = c.geometry, let pa = positions[a],
                  let pb = positions[b] else { return nil }
            return (pa + pb) / 2
        }
        if let m = nearest(lines, { $0 }) { return (SketchSnap(m), .midpoint) }
        if let i = nearest(Array(references.points.indices), { references.points[$0] }) {
            return (SketchSnap(references.points[i], model: references.pointModel(i)), .vertex)
        }
        let onCurves = sketch.curves.filter { !own.contains($0.id) && !Sketch.isGenerated($0.id) }.compactMap { c in
            sketch.geometry(of: c, positions).map { (c.id, Self.closest(uv, on: $0)) }
        }
        if let hovered = hover, hovered != excluding, !drawn.contains(hovered), let g = sketch.geometry(of: hovered) {
            return (SketchSnap(Self.closest(uv, on: g), curve: hovered), .curve)
        }
        if let c = nearest(onCurves, { $0.1 }) { return (SketchSnap(c.1, curve: c.0), .curve) }
        let onEdges = references.segments.map { Self.closest(uv, on: .line($0.0, $0.1)) }
        if let e = nearest(Array(onEdges.indices), { onEdges[$0] }) {
            var model = references.segmentModel(e)
            model?.endIndex = nil
            return (SketchSnap(onEdges[e], model: model), .edge)
        }
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
        case .ellipse:
            // The nearest of 720 points round it: finer than any pick tolerance.
            return (0..<720).map { g.point(Double($0) * 2 * .pi / 720) }.min { simdLength($0 - p) < simdLength($1 - p) } ?? p
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
        if m.phase == .down, manipulating != nil { cancelManipulatorPreview() }
        if m.phase == .moved || m.phase == .down {
            // What's exactly under the cursor, or else the nearest point or curve within a few
            // pixels: sketch lines are thin, and picking shouldn't need pixel precision.
            hover = entity(for: m.pick) ?? m.uv.flatMap { m.snapping ? nearestEntity($0) : nil }
            if let h = hover, Sketch.isGenerated(h), tool != .select { hover = nil }  // copies are only for picking their pattern
            hoverDimension = tool == .select && hover == nil ? m.uv.flatMap { dimensionLine(near: $0) } : nil
        }
        gridStep = m.gridStep
        snapping = m.snapping
        if let uv = m.uv, curveDown == nil, tool != .select || dragEntity != nil { _ = snap(uv, excluding: dragEntity) } else { setLastSnap(nil) }
        if let uv = m.uv { cursor = uv }
        switch m.phase {
        case .moved: return (false, nil)
        case .down: return mouseDown(m)
        case .dragged:
            if let down = curveDown, let uv = m.uv {  // pulling a handle out of the point
                let pull = uv - down.position
                curvePull = simdLength(pull) > tolerance ? pull : nil
                return (true, nil)
            }
            if let d = dragDimension, let uv = m.uv {
                moveDimensionLine(d, to: uv)
                dragMoved = true
                return (true, nil)
            }
            return (dragEntity != nil, drag(m))
        case .up:
            defer { dragEntity = nil; dragDimension = nil; dragMoved = false; dragSnap = nil }
            if dragDimension != nil { return (true, dragMoved ? "Move Dimension" : nil) }
            if let down = curveDown {
                let pull = curvePull
                curveDown = nil
                curvePull = nil
                return (true, curveClick(down, pulled: pull))
            }
            if let id = dragEntity, dragMoved, let model = dragSnap, model.model != nil { attachDragged(id, to: model) }
            return (dragEntity != nil, dragEntity != nil && dragMoved ? "Move" : nil)
        }
    }

    private func mouseDown(_ m: SketchMouse) -> (handled: Bool, commit: String?) {
        message = nil
        if patternSetup != nil { return (patternClick(), nil) }
        if mirrorSetup != nil { return (mirrorClick(), nil) }
        if offsetSetup != nil { return (hover != nil, nil) }  // the arrow and the field set it; clicks on curves are ignored
        switch tool {
        case .select:
            if let h = hover, let gid = sketch.gear(ofGenerated: h) {  // a gear: change it with the Gear tool's fields
                setTool(.gear)
                gearActive = gid
                return (true, nil)
            }
            // A pattern's copy: change its pattern. A mirror's image is picked like any curve (a double-click takes
            // the whole outline); the Mirror button changes the mirror of the image that is selected.
            if let h = hover, let pid = Sketch.pattern(ofGenerated: h), !sketch.mirrors.contains(where: { $0.id == pid }) {
                beginPattern(editing: pid)
                return (true, nil)
            }
            if hover == nil, let d = hoverDimension {  // a dimension line: drag it to move it
                dragDimension = d
                dragMoved = false
                return (true, nil)
            }
            guard let h = hover else {
                if !m.additive { selection = [] }
                return (false, nil)  // empty space: let the view orbit
            }
            if m.additive {
                if let i = selection.firstIndex(of: h) { selection.remove(at: i) } else { selection.append(h) }
            } else if !selection.contains(h) {
                selection = [h]
            }
            if sketch.point(h)?.fixed != true, !Sketch.isGenerated(h) {  // generated copies and images are not dragged
                dragEntity = h
                if let uv = m.uv, case let (a, _)? = sketch.lineEnds(h) { dragOffset = uv - a }
                else if let uv = m.uv, sketch.kind(of: h) == .bezier, let c = sketch.curve(h),
                        let start = sketch.pointIDs(of: c).first.flatMap({ sketch.position($0) }) { dragOffset = uv - start }
                else { dragOffset = .zero }
            }
            return (true, nil)
        case .dimension:
            return (true, dimensionClick())
        case .distance:
            return (true, distanceClick())
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
        case .chamfer:
            return (true, chamferClick())
        case .bezier:
            guard let uv = m.uv else { return (true, nil) }
            curveDown = snap(uv)
            curvePull = nil
            return (true, nil)
        default:
            guard let uv = m.uv else { return (true, nil) }
            return (true, toolClick(target() ?? snap(uv)))
        }
    }

    private func drag(_ m: SketchMouse) -> String? {
        guard let id = dragEntity, var uv = m.uv else { return nil }
        if sketch.point(id) != nil {  // dragged points snap too (without constraints, except to a model edge or corner)
            let s = snap(uv, excluding: id)
            uv = s.position
            dragSnap = s
        }
        if sketch.drag(id, to: uv, grabOffset: dragOffset, values: values) {
            dragMoved = true
            solve = SketchSolver.solve(&sketch, dimensionValues: values)
            refreshCopies()
        }
        return nil
    }

    /// A point dropped on a model edge or corner stays on it (or at it) when the model changes. If the
    /// sketch can't have that, the point stays where it was dropped, without the tie.
    private func attachDragged(_ id: EntityID, to snap: SketchSnap) {
        let before = sketch
        sketch.attach(id, to: snap)
        resolve()
        if solve?.status == .failed {
            sketch = before
            resolve()
            message = "That would conflict with the constraints already there"
        }
    }

    private func toolClick(_ s: SketchSnap) -> String? {
        for f in inputFields where f != .sides && !f.isGear {
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
            addPendingDimensions([.length: .length(r.line), .angle: .lineAngle(r.line)])
            // Keep chaining from the new end, unless we just connected to existing geometry.
            if s.point != nil || s.curve != nil {
                clicks = []
                chainPoint = nil
            } else {
                chainPoint = r.end
                clicks = [SketchSnap(sketch.position(r.end) ?? s.position, point: r.end)]
            }
            return finish("Line")
        case .roundedRectangle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            let a = clicks[0].position, b = s.position
            guard abs(a.x - b.x) > 1e-6, abs(a.y - b.y) > 1e-6 else { pendingDimensions = []; return nil }
            guard let rounded = sketch.addRoundedRectangle(from: clicks[0], to: s, radius: roundedRadiusValue, expression: roundedRadius) else {
                pendingDimensions = []
                message = "The corner radius is more than half the shorter side: make it smaller, or the rectangle bigger"
                return nil
            }
            // Width and height run corner to corner, since the rounded corners have shortened the sides.
            addPendingDimensions([.width: .distance(rounded.corners[0], rounded.corners[1]), .height: .distance(rounded.corners[1], rounded.corners[2])])
            return finish("Rounded Rectangle")
        case .ellipse:
            guard clicks.count == 3 else { return nil }
            defer { clicks = [] }
            guard let made = sketch.addEllipse(center: clicks[0], major: clicks[1], minor: s) else {
                pendingDimensions = []
                message = "An ellipse needs its two axes apart: the other axis must reach out from the first one"
                return nil
            }
            editingDimension = made.majorDimension
            return finish("Ellipse")
        case .tangentArc:
            if clicks.count == 1 {  // the start must be the free end of a line or arc: the arc carries on from it
                guard let p = clicks[0].point, sketch.freeEnd(at: p) != nil else {
                    clicks = []
                    message = "Start on the free end of a line or arc: the arc carries on from it"
                    return nil
                }
                return nil
            }
            guard clicks.count == 2 else { return nil }
            guard let made = sketch.addTangentArc(from: clicks[0], to: s) else {
                clicks.removeLast()
                message = "The arc can't reach there: the point must be ahead of the end, and not on the line's own extension"
                return nil
            }
            // Keep going from its end, like a chain of lines.
            clicks = [SketchSnap(sketch.position(made.end) ?? s.position, point: made.end)]
            return finish("Tangent Arc")
        case .slot, .overallSlot:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], s) > 1e-6 else { pendingDimensions = []; return nil }
            let width = slotWidthValue
            var from = clicks[0], to = s
            if tool == .overallSlot {
                // The clicks are the outside ends: the centers sit a radius inside them.
                let a = clicks[0].position, b = s.position, len = simdLength(b - a)
                guard len > width + 1e-6 else { pendingDimensions = []; message = "The overall length must be longer than the width"; return nil }
                let inset = (b - a) / len * (width / 2)
                from = SketchSnap(a + inset)
                to = SketchSnap(b - inset)
                // A typed overall length is kept as the distance between the centers, less the width.
                if let overall = pendingDimensions.last(where: { $0.input == .length }) {
                    pendingDimensions.removeAll { $0.input == .length }
                    pendingDimensions.append((.length, "(\(overall.expression)) - (\(slotWidth))", overall.value - width))
                }
            }
            let slot = sketch.addSlot(from: from, to: to, width: width)
            // The width is always a dimension (it is what makes the ends round); the length only when typed.
            pendingDimensions.removeAll { $0.input == .width }
            pendingDimensions.append((.width, slotWidth, width))
            addPendingDimensions([.length: .distance(slot.centers[0], slot.centers[1]), .width: .diameter(slot.ends[0])])
            return finish(tool.rawValue)
        case .rectangle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            let a = clicks[0].position, b = s.position
            guard abs(a.x - b.x) > 1e-6, abs(a.y - b.y) > 1e-6 else { pendingDimensions = []; return nil }
            let lines = sketch.addRectangle(from: clicks[0], to: s)  // bottom, right, top, left
            addPendingDimensions([.width: .length(lines[0]), .height: .length(lines[1])])
            return finish("Rectangle")
        case .centerRectangle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            let c = clicks[0].position, p = s.position
            guard abs(p.x - c.x) > 1e-6, abs(p.y - c.y) > 1e-6 else { pendingDimensions = []; return nil }
            let lines = sketch.addCenterRectangle(center: clicks[0], corner: s)
            addPendingDimensions([.width: .length(lines[0]), .height: .length(lines[1])])
            return finish("Rectangle")
        case .gear:
            defer { clicks = [] }
            cancelGearEdit()
            var def = gearDefaults
            def.id = IDs.make()
            def.ownsCenter = s.point == nil
            let centre = s.point ?? sketch.addPoint(s.position.x, s.position.y)
            def.center = centre
            do { try sketch.addGear(def, parameters) } catch {
                if s.point == nil { sketch.delete([centre]) }
                message = "\(error)"
                return nil
            }
            gearActive = def.id
            return finish("Gear")
        case .polygon, .triangle:
            guard clicks.count == 2 else { return nil }
            defer { clicks = [] }
            guard distance(clicks[0], s) > 1e-6 else { pendingDimensions = []; return nil }
            let polygon = sketch.addPolygon(center: clicks[0], corner: s, sides: sidesCount)
            addPendingDimensions([.length: .length(polygon.lines[0]), .diameter: .diameter(polygon.circle)])
            return finish(tool.rawValue)
        case .arc3Point:
            if clicks.count == 2, distance(clicks[0], s) <= 1e-6 { clicks.removeLast(); return nil }
            guard clicks.count == 3 else { return nil }
            defer { clicks = [] }
            guard sketch.addArc(from: clicks[0], to: clicks[1], through: s) != nil else {
                message = "Those three points are in a line: an arc needs a bend"
                return nil
            }
            return finish("Arc")
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
        case .select, .dimension, .distance, .fillet, .chamfer, .trim, .extend, .bezier:
            clicks = []
            return nil
        }
    }

    /// The Curve tool's mouse came up on `s`: the first point starts the run, each later one adds a
    /// smooth curve to it. `pulled` is the handle dragged out of the point, if any.
    private func curveClick(_ s: SketchSnap, pulled: SIMD2<Double>?) -> String? {
        guard let first = clicks.first else {
            clicks = [s]
            curveFirstPull = pulled
            return nil
        }
        guard distance(first, s) > 1e-6 else { return nil }
        var chain = curveChain ?? CurveChain(anchors: [sketch.resolve(first)])
        if curveChain == nil, let p = curveFirstPull { chain.pulled[chain.anchors[0]] = p }
        let r = sketch.extendCurve(chain, to: s, pulled: pulled)
        if r.continues, let end = r.chain.anchors.last {
            curveChain = r.chain
            clicks = [SketchSnap(sketch.position(end) ?? s.position, point: end)]
        } else {
            curveChain = nil
            clicks = []
        }
        curveFirstPull = nil
        return finish("Curve")
    }

    // MARK: typed values

    /// The fields for the current drawing step.
    var inputFields: [SketchInput] {
        if let patternSetup { return patternSetup.kind == .rectangular ? [.countX, .spacingX, .countY, .spacingY] : [.copies, .spread] }
        if offsetSetup != nil { return [.offsetDistance] }
        if manipulating != nil { return [.moveX, .moveY, .turn] }
        switch (tool, clicks.count) {
        case (.line, 1): return [.length, .angle]
        case (.rectangle, 1), (.centerRectangle, 1): return [.width, .height]
        case (.slot, 0), (.overallSlot, 0): return [.width]
        case (.slot, 1), (.overallSlot, 1): return [.length, .width]
        case (.roundedRectangle, 0): return [.radius]
        case (.roundedRectangle, 1): return [.width, .height, .radius]
        case (.circle, 1), (.circle2Point, 1): return [.diameter]
        case (.polygon, 0): return [.sides]
        case (.gear, _): return [.teeth, .module, .pressureAngle, .backlash, .bore]
        case (.polygon, 1): return [.length, .diameter, .sides]
        case (.triangle, 1): return [.length, .diameter]
        case (.arc, 1): return [.radius]
        case (.arc, 2): return [.sweep]
        default: return []
        }
    }

    /// Sets (or, with empty text, clears) a typed value for the current step.
    func setTyped(_ field: SketchInput, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        typed[field] = t.isEmpty ? nil : t
        if field == .sides, let n = typedValue(.sides) { polygonSides = Int(n) }
        if tool.drawsSlot, field == .width, typedValue(.width) != nil, let text = typed[.width] { slotWidth = Self.expression(text, .width) }
        if tool == .roundedRectangle, field == .radius, typedValue(.radius) != nil, let text = typed[.radius] { roundedRadius = Self.expression(text, .radius) }
        if field.isGear, typedValue(field) != nil, let text = typed[field] { setGear(field, Self.expression(text, field)) }
        if manipulating != nil { previewTyped() }
        if patternSetup != nil { applyTypedPattern() }
        if offsetSetup != nil { applyTypedOffset() }
    }

    func clearTyped() {
        typed = [:]
        cancelGearEdit()
        if patternSetup != nil { cancelPattern() }
        if mirrorSetup != nil { cancelMirror() }
        if offsetSetup != nil { cancelOffset() }
        if manipulating != nil { cancelManipulatorPreview() }
    }

    /// A typed value in base units (mm or radians); nil when nothing usable is typed.
    func typedValue(_ field: SketchInput) -> Double? {
        guard let text = typed[field], let v = try? parameters.value(of: text, kind: field.unit) else { return nil }
        if field.unit == .length, !field.isOffset, v <= 1e-9 { return nil }
        if field == .sides {
            return abs(v - v.rounded()) > 1e-9 || !Sketch.polygonSides.contains(Int(v.rounded())) ? nil : v
        }
        if field.isCount, abs(v - v.rounded()) > 1e-9 || v < 1 || v > Double(SketchPattern.maxCopies) { return nil }
        if field == .sweep, abs(v) <= 1e-9 { return nil }
        switch field {
        case .teeth: if abs(v - v.rounded()) > 1e-9 || !(GearSpec.minTeeth...GearSpec.maxTeeth).contains(Int(v.rounded())) { return nil }
        case .module: if v <= 1e-9 { return nil }
        case .pressureAngle: if v < 6 * .pi / 180 || v > 34 * .pi / 180 { return nil }
        case .bore: if v < 0 { return nil }
        default: break
        }
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
        case .slot, .overallSlot:
            // The length is from the first click to the second (the ends, or the centers); the width is drawn across it, not placed.
            return SketchSnap(a + dir * (typedValue(.length) ?? len))
        case .rectangle, .roundedRectangle:
            let w = typedValue(.width) ?? abs(d.x), h = typedValue(.height) ?? abs(d.y)
            return SketchSnap(a + SIMD2(d.x < 0 ? -w : w, d.y < 0 ? -h : h))
        case .centerRectangle:
            // Typed sizes are the whole rectangle's; the corner is half of them from the center.
            let w = typedValue(.width).map { $0 / 2 } ?? abs(d.x), h = typedValue(.height).map { $0 / 2 } ?? abs(d.y)
            return SketchSnap(a + SIMD2(d.x < 0 ? -w : w, d.y < 0 ? -h : h))
        case .circle:
            return SketchSnap(a + dir * ((typedValue(.diameter) ?? 2 * len) / 2))
        case .circle2Point:
            return SketchSnap(a + dir * (typedValue(.diameter) ?? len))
        case .polygon, .triangle:
            // Typed sizes are the circle round the corners, or the length of a side.
            let radius = typedValue(.diameter).map { $0 / 2 }
                ?? typedValue(.length).map { $0 / (2 * sin(.pi / Double(sidesCount))) } ?? len
            return SketchSnap(a + dir * radius)
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
        switch field {
        case .moveX: return manipulatorValues.move.x
        case .moveY: return manipulatorValues.move.y
        case .turn: return manipulatorValues.turn.z
        case .countX, .countY, .copies, .spacingX, .spacingY, .spread: return patternValue(field)
        case .offsetDistance: return offsetDistance
        case .sides: return Double(sidesCount)
        case .width where tool.drawsSlot: return slotWidthValue
        case .radius where tool == .roundedRectangle: return roundedRadiusValue
        case .teeth: return evaluated(gearShown.teeth, .none)
        case .module: return evaluated(gearShown.module, .length)
        case .pressureAngle: return evaluated(gearShown.pressureAngle, .angle)
        case .backlash: return evaluated(gearShown.backlash, .length)
        case .bore: return evaluated(gearShown.bore, .length)
        default: break
        }
        guard let t = target()?.position, let a = clicks.first?.position else { return nil }
        let d = t - a
        switch field {
        case .length where drawsPolygon: return 2 * simdLength(d) * sin(.pi / Double(sidesCount))  // a side of the polygon
        case .length, .radius: return simdLength(d)
        case .diameter: return tool == .circle2Point ? simdLength(d) : 2 * simdLength(d)
        case .width: return tool == .centerRectangle ? 2 * abs(d.x) : abs(d.x)
        case .height: return tool == .centerRectangle ? 2 * abs(d.y) : abs(d.y)
        case .angle:
            let angle = atan2(d.y, d.x)
            return angle < 0 ? angle + 2 * .pi : angle
        case .sweep:
            guard clicks.count > 1 else { return nil }
            let s = clicks[1].position - a
            var sweep = atan2(d.y, d.x) - atan2(s.y, s.x)
            while sweep <= 0 { sweep += 2 * .pi }
            return sweep
        case .moveX, .moveY, .turn, .countX, .countY, .copies, .spacingX, .spacingY, .spread, .offsetDistance, .sides, .teeth, .module, .pressureAngle, .backlash, .bore: return nil
        }
    }

    /// Return in a field: place the next point from the typed values, as a click would.
    func commitTyped() -> String? {
        if patternSetup != nil { return commitPattern() }
        if mirrorSetup != nil { return commitMirror() }
        if offsetSetup != nil { return commitOffset() }
        if manipulating != nil { return commitTypedTransform() }
        if tool == .gear {  // Return keeps what the fields did to the active gear; with none, the size is set and there is nothing to place yet
            typed = [:]
            guard gearBackup != nil else { return nil }
            gearBackup = nil
            return finish("Edit Gear")
        }
        if tool == .polygon, clicks.isEmpty {  // the number of sides is set: nothing to place yet
            typed = [:]
            return nil
        }
        if tool.drawsSlot || tool == .roundedRectangle, clicks.isEmpty {  // the width or radius is set: nothing to place yet
            typed = [:]
            return nil
        }
        guard !inputFields.isEmpty, let t = target() else { return nil }
        message = nil
        return toolClick(t)
    }

    /// A bare number becomes "25 mm" / "30 deg"; anything else (units, parameters) is kept as typed.
    private static func expression(_ text: String, _ field: SketchInput) -> String {
        guard let v = Double(text) else { return text }
        if field == .angle { return formatDimension(Sketch.foldedAngle(v * .pi / 180), kind: .angle) }  // a line's angle: 325° is 35°
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
        cornerClick(name: "Round Corner", verb: "rounded") { $0.filletCorner($1, radius: $2, expression: $3) }
    }

    private func chamferClick() -> String? {
        cornerClick(name: "Chamfer", verb: "chamfered") { $0.chamferCorner($1, distance: $2, expression: $3) }
    }

    /// Rounds or chamfers the corner under the cursor: tries 2 mm, and falls back to a size that fits short lines.
    private func cornerClick(name: String, verb: String, _ make: (inout Sketch, EntityID, Double, String) -> EntityID?) -> String? {
        guard let h = hover, sketch.point(h) != nil else {
            message = "Click the corner point where two lines meet"
            return nil
        }
        for size in [2.0, 1.0, 0.5, 0.2] {
            var trial = sketch
            if let dim = make(&trial, h, size, formatDimension(size, kind: .length)) {
                var solved = trial
                var v = values
                v[dim] = size
                guard SketchSolver.solve(&solved, dimensionValues: v).status == .solved else { continue }
                sketch = trial
                editingDimension = dim
                return finish(name)
            }
        }
        message = "That corner can't be \(verb) (it needs exactly two lines meeting at a point)"
        return nil
    }

    // MARK: move, rotate, scale

    /// Whether there is anything to move: the selection, or with none, the whole sketch.
    var canTransform: Bool { sketch.points.contains { !$0.fixed } }

    /// The Move button turns the manipulator on (or off, pressed again); Scale asks for a factor.
    func beginTransform(_ tool: SketchTransformTool) {
        guard canTransform else { return }
        if tool == .scale { transformRequested = tool; return }
        if tool == .pattern { beginPattern(); return }
        if tool == .mirror { beginMirror(); return }
        if manipulating == tool { stopManipulating(); return }
        setTool(.select)
        cancelPattern()
        cancelMirror()
        manipulating = tool
        message = nil
        setLastSnap(nil)
    }

    func stopManipulating() {
        guard manipulating != nil || manipulatorBase != nil else { return }
        cancelManipulatorPreview()
        manipulating = nil
    }

    /// Where the manipulator sits, in sketch (u, v): the middle of what it works on, carried along by a drag.
    var manipulatorMiddle: SIMD2<Double>? {
        if patternSetup != nil { return patternMiddle }
        if let h = offsetHandle { return h.origin + h.direction * (offsetDistance ?? 0) }  // the arrow rides the offset curve
        guard manipulating != nil else { return nil }
        if manipulatorBase != nil { return manipulatorPivot + SIMD2(manipulatorValues.move.x, manipulatorValues.move.y) }
        return sketch.transformCenter(selection)
    }

    /// Takes the sketch as it is as the one a drag or typing starts from. False if there is nothing to work on.
    @discardableResult
    private func captureManipulatorBase() -> Bool {
        if manipulatorBase != nil { return true }
        guard manipulating != nil, let middle = sketch.transformCenter(selection) else { return false }
        manipulatorBase = sketch
        manipulatorPivot = middle
        manipulatorValues = TransformValues()
        return true
    }

    /// Puts the sketch back as it was before the preview, and forgets what was typed.
    private func cancelManipulatorPreview() {
        if let base = manipulatorBase { sketch = base; refreshCopies() }
        manipulatorBase = nil
        manipulatorValues = TransformValues()
        typed = [:]
    }

    /// The mouse went down on a part of the manipulator (for the Pattern tool: an arrow or the ring).
    func beginManipulatorDrag(_ part: ManipulatorPart) -> Bool {
        if patternSetup != nil {
            message = nil
            for field in patternFields(of: part) { typed[field] = nil }  // dragging replaces what was typed
            return true
        }
        if offsetSetup != nil {
            message = nil
            typed[.offsetDistance] = nil  // dragging replaces what was typed
            return true
        }
        cancelManipulatorPreview()
        message = nil
        return captureManipulatorBase()
    }

    /// Shows the selection moved and turned by the dragged values, without keeping it.
    func previewManipulator(_ v: TransformValues) {
        if offsetSetup != nil {
            setOffset(formatDimension(v.move.x, kind: .length))
            return
        }
        if patternSetup != nil {
            setPattern { d in
                if d.kind == .rectangular {
                    d.spacingX = formatDimension(v.move.x, kind: .length)
                    d.spacingY = formatDimension(v.move.y, kind: .length)
                } else {
                    d.angle = formatDimension(v.turn.z, kind: .angle)
                }
            }
            return
        }
        guard let base = manipulatorBase else { return }
        manipulatorValues = v
        if let shown = transformed(base, by: v) { sketch = shown; refreshCopies() }
    }

    /// The mouse came up: keep the move and turn if the constraints let them stand (one undo step).
    func endManipulatorDrag() -> String? {
        guard manipulatorBase != nil else { return nil }
        let v = manipulatorValues
        cancelManipulatorPreview()
        guard !isIdentity(v) else { return nil }
        return commitTransform(v)
    }

    /// Shows what is typed in the fields as the selection moved and turned.
    private func previewTyped() {
        guard captureManipulatorBase(), let base = manipulatorBase else { return }
        let v = typedTransform
        manipulatorValues = v
        sketch = transformed(base, by: v) ?? base
        refreshCopies()
    }

    private var typedTransform: TransformValues {
        var v = TransformValues()
        v.move = SIMD3(typedValue(.moveX) ?? 0, typedValue(.moveY) ?? 0, 0)
        v.turn = SIMD3(0, 0, typedValue(.turn) ?? 0)
        return v
    }

    /// Return in a Move field: keep the typed move and turn.
    private func commitTypedTransform() -> String? {
        guard !inputFields.contains(where: typedIsInvalid) else { return failTransform("That isn't a distance or an angle") }
        let v = typedTransform
        cancelManipulatorPreview()
        guard !isIdentity(v) else { return failTransform("The move and the angle are zero") }
        guard captureManipulatorBase() else { return nil }
        manipulatorBase = nil
        return commitTransform(v)
    }

    /// The sketch with the selection turned about the pivot, then moved.
    private func transformed(_ base: Sketch, by v: TransformValues) -> Sketch? {
        var t = base
        if abs(v.turn.z) > 1e-12, !t.apply(.rotate(angle: v.turn.z, about: manipulatorPivot), to: selection, parameters: parameters) { return nil }
        if hypot(v.move.x, v.move.y) > 1e-12, !t.apply(.move(dx: v.move.x, dy: v.move.y), to: selection, parameters: parameters) { return nil }
        return t
    }

    /// Whether a move and turn change nothing: no distance, and no angle or whole turns only.
    private func isIdentity(_ v: TransformValues) -> Bool {
        hypot(v.move.x, v.move.y) <= 1e-9 && abs(v.turn.z.truncatingRemainder(dividingBy: 2 * .pi)) <= 1e-9
    }

    private func commitTransform(_ v: TransformValues) -> String? {
        guard let trial = transformed(sketch, by: v) else { return failTransform("Nothing to move") }
        let turns = abs(v.turn.z.truncatingRemainder(dividingBy: 2 * .pi)) > 1e-9, moves = hypot(v.move.x, v.move.y) > 1e-9
        return adopt(trial, turns && moves ? "Move and Rotate" : turns ? "Rotate" : "Move")
    }

    /// What Move and Scale work on, for the popover: "3 selected" or "the whole sketch".
    var transformTargetDescription: String {
        let n = selection.filter { sketch.kind(of: $0) != nil }.count
        return n == 0 ? "the whole sketch" : "\(n) selected"
    }

    /// Grows or shrinks the selection about its middle or the sketch origin.
    func scaleSelection(factor: String, about pivot: TransformPivot) -> String? {
        do {
            let f = try parameters.value(of: factor, kind: .none)
            guard f > 1e-9 else { return failTransform("The scale factor must be more than zero") }
            guard abs(f - 1) > 1e-12 else { return failTransform("A factor of 1 changes nothing") }
            return transform(.scale(factor: f, about: transformPivot(pivot)), "Scale", "scale")
        } catch { return failTransform("\(error)") }
    }

    private func transformPivot(_ pivot: TransformPivot) -> SIMD2<Double> {
        pivot == .origin ? .zero : sketch.transformCenter(selection) ?? .zero
    }

    private func failTransform(_ text: String) -> String? {
        message = text
        return nil
    }

    /// Applies a transform if the constraints and dimensions let it stand: after solving, what
    /// was transformed must still be where it was put.
    private func transform(_ t: SketchTransform, _ action: String, _ verb: String) -> String? {
        transformRequested = nil
        var trial = sketch
        guard trial.apply(t, to: selection, parameters: parameters) else { return failTransform("Nothing to \(verb)") }
        return adopt(trial, action)
    }

    /// Keeps a transformed sketch if the constraints and dimensions let it stand.
    private func adopt(_ trial: Sketch, _ action: String) -> String? {
        let moved = trial.transformPoints(selection)
        var solved = trial
        let result = SketchSolver.solve(&solved, dimensionValues: trial.dimensionValues(parameters))
        let held = moved.contains { id in
            guard let a = trial.point(id), let b = solved.point(id) else { return false }
            return hypot(a.x - b.x, a.y - b.y) > 1e-6 * max(1, hypot(a.x, a.y))
        }
        guard result.status == .solved, !held else {
            return failTransform("Constraints or dimensions keep it from staying there. Delete the ones in the way (fixed, horizontal, vertical, or distances from the origin), or leave them out of the selection.")
        }
        sketch = trial
        return finish(action)
    }

    // MARK: pattern

    /// The pattern being made or changed while the Pattern tool is on.
    private(set) var patternSetup: SketchPatternDef?
    /// The sketch as it was before, to go back to; and without this pattern, to show it on.
    @ObservationIgnored private var patternBackup: Sketch?
    @ObservationIgnored private var patternBase: Sketch?
    /// Whether the pattern is new (else an existing one is being changed).
    private(set) var patternIsNew = true

    var isPatterning: Bool { patternSetup != nil }
    var canPattern: Bool { patternSetup != nil || sketch.canPattern(selection) }

    /// The numbers the pattern's expressions come to now (0 where they don't come to one).
    private func evaluated(_ text: String, _ kind: UnitKind) -> Double { (try? parameters.value(of: text, kind: kind)) ?? 0 }

    func patternValue(_ field: SketchInput) -> Double? {
        guard let d = patternSetup else { return nil }
        switch field {
        case .countX: return evaluated(d.countX, .none)
        case .countY: return evaluated(d.countY, .none)
        case .copies: return evaluated(d.count, .none)
        case .spacingX: return evaluated(d.spacingX, .length)
        case .spacingY: return evaluated(d.spacingY, .length)
        case .spread: return evaluated(d.angle, .angle)
        default: return nil
        }
    }

    /// The values the arrows and the ring show: the spacing along x and y, and the spread.
    var patternValues: TransformValues? {
        guard patternSetup != nil else { return nil }
        var v = TransformValues()
        v.move = SIMD3(patternValue(.spacingX) ?? 0, patternValue(.spacingY) ?? 0, 0)
        v.turn = SIMD3(0, 0, patternValue(.spread) ?? 0)
        return v
    }

    /// Where the arrows sit: the middle of what is copied (for a circle, the point it goes round).
    private var patternMiddle: SIMD2<Double>? {
        guard let d = patternSetup, let base = patternBase else { return nil }
        if d.kind == .circular { return base.position(d.center) ?? .zero }
        return base.patternBox(d.sources).map { ($0.min + $0.max) / 2 }
    }

    /// The Pattern button: starts a pattern of the selection (or the whole sketch), or ends it, pressed again.
    func beginPattern() {
        if patternSetup != nil { cancelPattern(); return }
        guard sketch.canPattern(selection) else { message = "Nothing to copy"; return }
        var def = SketchPatternDef(sources: sketch.patternSources(selection))
        if let box = sketch.patternBox(selection) {
            // A little more than the shape's own size, so the copies sit side by side.
            func gap(_ size: Double) -> String { formatDimension(max((size * 1.5 * 2).rounded() / 2, 2), kind: .length) }
            def.spacingX = gap(box.max.x - box.min.x)
            def.spacingY = gap(box.max.y - box.min.y)
        }
        startPattern(def, isNew: true)
    }

    /// Opens an existing pattern (clicked on one of its copies) to change it.
    func beginPattern(editing id: EntityID) {
        guard patternSetup == nil, let def = sketch.patterns.first(where: { $0.id == id }) else { return }
        startPattern(def, isNew: false)
    }

    private func startPattern(_ def: SketchPatternDef, isNew: Bool) {
        stopManipulating()
        cancelMirror()
        setTool(.select)
        message = nil
        patternBackup = sketch
        var base = sketch
        base.patterns.removeAll { $0.id == def.id }
        base.refreshGenerated(parameters)
        patternBase = base
        patternIsNew = isNew
        patternSetup = def
        previewPattern()
    }

    /// Takes the changes back and leaves the sketch as it was.
    func cancelPattern() {
        guard patternSetup != nil else { return }
        if let backup = patternBackup { sketch = backup }
        endPattern()
    }

    private func endPattern() {
        patternSetup = nil
        patternBackup = nil
        patternBase = nil
        typed = [:]
        message = nil
    }

    func setPatternKind(_ kind: SketchPatternDef.Kind) {
        setPattern { $0.kind = kind }
    }

    /// Changes the pattern and shows the copies it makes.
    private func setPattern(_ change: (inout SketchPatternDef) -> Void) {
        guard var def = patternSetup else { return }
        change(&def)
        patternSetup = def
        message = nil
        previewPattern()
    }

    /// What is typed becomes the pattern's expressions, field by field, where it can be used.
    private func applyTypedPattern() {
        setPattern { d in
            for field in inputFields {
                guard typedValue(field) != nil, let text = typed[field] else { continue }
                let e = Self.expression(text, field)
                switch field {
                case .countX: d.countX = e
                case .countY: d.countY = e
                case .copies: d.count = e
                case .spacingX: d.spacingX = e
                case .spacingY: d.spacingY = e
                case .spread: d.angle = e
                default: break
                }
            }
        }
    }

    /// The typed fields a part of the manipulator stands for.
    private func patternFields(of part: ManipulatorPart) -> [SketchInput] {
        switch part {
        case .axis(.x): return [.spacingX]
        case .axis(.y): return [.spacingY]
        case .ring: return [.spread]
        default: return []
        }
    }

    /// Why the pattern can't make copies, if it can't.
    var patternProblem: String? {
        guard let d = patternSetup, let base = patternBase else { return nil }
        if inputFields.contains(where: typedIsInvalid) { return "That isn't a whole number of copies, a distance or an angle." }
        let layout: SketchPattern
        do { layout = try d.layout(base, parameters) } catch {
            let text = "\(error)"
            return text.prefix(1).uppercased() + text.dropFirst() + "."
        }
        if layout.copyCount < 1 { return "A count of 1 makes no copies. The original counts too." }
        switch layout {
        case .rectangular(let nx, let sx, let ny, let sy) where (nx > 1 && abs(sx) < 1e-9) || (ny > 1 && abs(sy) < 1e-9):
            return "A spacing of zero puts the copies on top of each other."
        case .circular(_, let angle, _) where abs(angle) < 1e-9:
            return "A spread of zero puts the copies on top of each other."
        default: return nil
        }
    }

    /// Shows the copies the pattern makes, over the sketch without it.
    private func previewPattern() {
        guard let def = patternSetup, let base = patternBase else { return }
        var shown = base
        shown.patterns.append(def)
        shown.refreshGenerated(parameters)
        sketch = shown
    }

    /// A click while Pattern is on: on a point, it sets what a circle of copies goes round.
    private func patternClick() -> Bool {
        guard let d = patternSetup, d.kind == .circular, let h = hover, !Sketch.isGenerated(h), patternBase?.point(h) != nil else { return hover != nil }
        setPattern { $0.center = h }
        return true
    }

    var patternHint: String {
        guard let d = patternSetup else { return "" }
        let tail = " · type the counts and spacing, or drag the \(d.kind == .rectangular ? "arrows" : "ring") · Return keeps the pattern · Esc cancels"
        return d.kind == .rectangular ? "Rectangular pattern" + tail : "Click a point to copy around it (now \(patternCenterName))" + tail
    }

    private var patternCenterName: String {
        guard let d = patternSetup else { return "" }
        guard d.center != "origin", let c = patternBase?.position(d.center), simdLength(c) > 1e-9 else { return "the origin" }
        return "\(formatDimension(c.x, kind: .length)), \(formatDimension(c.y, kind: .length))"
    }

    /// Return: keeps the pattern (one undo step). The copies stay linked to what they copy.
    func commitPattern() -> String? {
        guard let d = patternSetup, var made = patternBase else { return nil }
        if let problem = patternProblem { message = problem; return nil }
        made.patterns.append(d)
        let isNew = patternIsNew
        endPattern()
        sketch = made
        return finish(isNew ? "Pattern" : "Edit Pattern")
    }

    /// Deletes the pattern being changed: its copies go, the originals stay.
    func deletePattern() -> String? {
        guard patternSetup != nil, !patternIsNew, let base = patternBase else { return nil }
        endPattern()
        sketch = base
        return finish("Delete Pattern")
    }

    // MARK: mirror

    /// The mirror being made or changed while the Mirror tool is on; its line is empty until one is chosen.
    private(set) var mirrorSetup: SketchMirrorDef?
    /// The sketch as it was before, to go back to; and without this mirror, to show it on.
    @ObservationIgnored private var mirrorBackup: Sketch?
    @ObservationIgnored private var mirrorBase: Sketch?
    @ObservationIgnored private var mirrorSelection: [EntityID] = []
    /// Whether the mirror is new (else an existing one is being changed).
    private(set) var mirrorIsNew = true

    var isMirroring: Bool { mirrorSetup != nil }
    var canMirror: Bool { mirrorSetup != nil || selectedMirrorImage != nil || sketch.canMirror(selection) }

    /// The Mirror button: starts a mirror of the selection (or the whole sketch), or ends it, pressed again.
    /// When the selection holds exactly one construction line besides other curves, that line is the one to
    /// mirror across and the rest is what is mirrored.
    func beginMirror() {
        if mirrorSetup != nil { cancelMirror(); return }
        if let id = selectedMirrorImage { beginMirror(editing: id); return }
        let guides = selection.filter { sketch.curve($0).map { c in c.construction && sketch.canMirror(across: c.id) } == true }
        if guides.count == 1, selection.count > 1, sketch.canMirror(selection.filter { $0 != guides[0] }) {
            var def = SketchMirrorDef(sources: sketch.mirrorSources(selection.filter { $0 != guides[0] }), line: guides[0])
            def.sources.removeAll { $0 == guides[0] }
            startMirror(def, isNew: true)
            return
        }
        guard sketch.canMirror(selection) else { message = "Nothing to mirror"; return }
        startMirror(SketchMirrorDef(sources: sketch.mirrorSources(selection)), isNew: true)
    }

    /// The mirror whose image is what is selected, if the selection is only that image.
    var selectedMirrorImage: EntityID? {
        let owners = Set(selection.map { Sketch.isGenerated($0) ? Sketch.pattern(ofGenerated: $0) : nil })
        guard owners.count == 1, let owner = owners.first ?? nil, sketch.mirrors.contains(where: { $0.id == owner }) else { return nil }
        return owner
    }

    /// Opens an existing mirror (its image is selected) to change it.
    func beginMirror(editing id: EntityID) {
        guard mirrorSetup == nil, let def = sketch.mirrors.first(where: { $0.id == id }) else { return }
        startMirror(def, isNew: false)
    }

    private func startMirror(_ def: SketchMirrorDef, isNew: Bool) {
        stopManipulating()
        cancelPattern()
        setTool(.select)
        message = nil
        mirrorBackup = sketch
        mirrorSelection = selection
        // The sketch as it is, every mirror in place: the one being changed keeps its turn, and mirrors that copy its
        // image still find it.
        mirrorBase = sketch
        mirrorIsNew = isNew
        mirrorSetup = def
        selection = []
        previewMirror()
    }

    /// Takes the changes back and leaves the sketch as it was.
    func cancelMirror() {
        guard mirrorSetup != nil else { return }
        if let backup = mirrorBackup { sketch = backup; selection = mirrorSelection }
        endMirror()
    }

    private func endMirror() {
        mirrorSetup = nil
        mirrorBackup = nil
        mirrorBase = nil
        message = nil
    }

    /// Chooses the line to mirror across: the id of a line of the sketch, or `SketchMirrorDef.xAxis` / `yAxis`.
    func setMirrorLine(_ line: EntityID) {
        guard var def = mirrorSetup, let base = mirrorBase else { return }
        guard base.canMirror(across: line) else {
            message = "Click a straight line, a construction line or a projected edge (or choose an axis)"
            return
        }
        def.line = line
        mirrorSetup = def
        message = nil
        previewMirror()
    }

    /// The line the mirror goes across, in words.
    var mirrorLineName: String? {
        guard let d = mirrorSetup, d.line != "" else { return nil }
        return mirrorBase?.mirrorLineName(d.line)
    }

    /// Shows the mirror image, over the sketch without it.
    private func previewMirror() {
        guard let def = mirrorSetup, let base = mirrorBase else { return }
        var shown = base
        if let i = shown.mirrors.firstIndex(where: { $0.id == def.id }) { shown.mirrors[i] = def }
        else if def.line != "" { shown.mirrors.append(def) }
        shown.holdPointsOnMirrorLine(def, snap: snapTolerance)  // so the preview joins where the kept mirror will
        shown.refreshGenerated(parameters)
        sketch = shown
        selection = def.line != "" && !SketchMirrorDef.isAxis(def.line) ? [def.line] : []
    }

    /// A click while Mirror is on: on a line, it is the line to mirror across.
    private func mirrorClick() -> Bool {
        guard let h = hover else { return false }
        if let base = mirrorBase, base.curve(h) != nil, !Sketch.isGenerated(h) { setMirrorLine(h) }
        return true
    }

    var mirrorHint: String {
        guard mirrorSetup != nil else { return "" }
        let tail = " · Return keeps the mirror · Esc cancels"
        guard let name = mirrorLineName else { return "Click the line to mirror across, or choose the X or Y axis" + tail }
        return "Mirrored across \(name) · click another line, or choose an axis, to change it" + tail
    }

    /// Return: keeps the mirror (one undo step). The image stays linked to what it copies.
    func commitMirror() -> String? {
        guard let d = mirrorSetup, var made = mirrorBase else { return nil }
        guard d.line != "" else { message = "Click the line to mirror across first, or choose the X or Y axis."; return nil }
        if let i = made.mirrors.firstIndex(where: { $0.id == d.id }) { made.mirrors[i] = d } else { made.mirrors.append(d) }
        made.holdPointsOnMirrorLine(d, snap: snapTolerance)
        made.refreshGenerated(parameters)
        let isNew = mirrorIsNew
        endMirror()
        sketch = made
        selection = []
        return finish(isNew ? "Mirror" : "Edit Mirror")
    }

    /// Deletes the mirror being changed: its image goes, the originals stay.
    func deleteMirror() -> String? {
        guard let d = mirrorSetup, !mirrorIsNew, var made = mirrorBase else { cancelMirror(); return nil }
        made.mirrors.removeAll { $0.id == d.id }  // (a mirror of its image goes with it)
        made.refreshGenerated(parameters)
        endMirror()
        sketch = made
        selection = []
        return finish("Delete Mirror")
    }

    // MARK: offset

    /// Offset while it is open: the distance, as an expression (negative goes to the other side of the arrow).
    struct OffsetSetup: Equatable {
        var expression: String
        var sources: [EntityID]
    }

    private(set) var offsetSetup: OffsetSetup?
    /// The sketch as it was before, which the offset curves are made on afresh at each change.
    @ObservationIgnored private var offsetBase: Sketch?
    /// Where the arrow stands on the curves, and the way a positive distance goes there.
    private(set) var offsetHandle: (origin: SIMD2<Double>, direction: SIMD2<Double>)?
    /// Why the offset can't be made as set, if it can't.
    private(set) var offsetProblem: String?

    var isOffsetting: Bool { offsetSetup != nil }
    var canOffset: Bool { offsetSetup != nil || selection.contains { sketch.curve($0) != nil } }

    /// The distance now, in mm (nil if the expression doesn't come to a length).
    var offsetDistance: Double? {
        guard let e = offsetSetup?.expression else { return nil }
        return try? parameters.value(of: e, kind: .length)
    }

    /// What the arrow shows: how far out the curves are offset.
    var offsetValues: TransformValues? {
        guard offsetSetup != nil else { return nil }
        var v = TransformValues()
        v.move = SIMD3(offsetDistance ?? 0, 0, 0)
        return v
    }

    /// The Offset button: shows the offset of the selection, with an arrow to drag and a field to type in
    /// (pressed again, it stops).
    func beginOffset() {
        if offsetSetup != nil { cancelOffset(); return }
        let sources = selection.filter { sketch.curve($0) != nil }
        guard !sources.isEmpty, let handle = sketch.offsetHandle(sources) else { message = "Select the curves to offset first"; return }
        stopManipulating()
        cancelPattern()
        cancelMirror()
        setTool(.select)
        message = nil
        offsetBase = sketch
        offsetHandle = handle
        offsetSetup = OffsetSetup(expression: "2 mm", sources: sources)
        previewOffset()
    }

    /// Takes the offset back and leaves the sketch as it was.
    func cancelOffset() {
        guard offsetSetup != nil else { return }
        if let base = offsetBase { sketch = base; resolve() }
        endOffset()
    }

    private func endOffset() {
        offsetSetup = nil
        offsetBase = nil
        offsetHandle = nil
        offsetProblem = nil
        typed = [:]
        message = nil
    }

    private func setOffset(_ expression: String) {
        guard offsetSetup != nil else { return }
        offsetSetup?.expression = expression
        message = nil
        previewOffset()
    }

    /// A typed distance becomes the offset's expression, where it can be used.
    private func applyTypedOffset() {
        guard let text = typed[.offsetDistance], typedValue(.offsetDistance) != nil else { return }
        setOffset(Self.expression(text, .offsetDistance))
    }

    /// The offset of `curves` on `base`, solved: the sketch and the curves made, or why not.
    private func offsetResult(on base: Sketch, _ curves: [EntityID], expression: String) -> (sketch: Sketch, created: [EntityID], problem: String?) {
        let distance: Double
        do { distance = try parameters.value(of: expression, kind: .length) } catch {
            return (base, [], "\(error)")
        }
        guard abs(distance) > 1e-9 else { return (base, [], "The offset distance can't be zero") }
        var trial = base
        // Dimensions take the magnitude; the side comes from the sign.
        let text = expression.trimmingCharacters(in: .whitespaces)
        let magnitude = text.hasPrefix("-") ? String(text.dropFirst()) : expression
        let created = trial.offset(curves, distance: distance, expression: magnitude)
        guard !created.isEmpty else {
            let bends = curves.contains { base.kind(of: $0) == .bezier || base.kind(of: $0) == .arc }
            return (base, [], bends ? "Nothing to offset: that far from the curve, the offset folds over itself" : "Nothing to offset in the selection")
        }
        var v = trial.dimensionValues(parameters)
        v.merge(values) { a, _ in a }
        guard SketchSolver.solve(&trial, dimensionValues: v).status == .solved else {
            return (base, [], "The offset couldn't be solved")
        }
        return (trial, created, nil)
    }

    /// Shows the offset curves over the sketch as it was.
    private func previewOffset() {
        guard let setup = offsetSetup, let base = offsetBase else { return }
        let r = offsetResult(on: base, setup.sources, expression: setup.expression)
        offsetProblem = r.problem
        // A distance of zero (passed through while dragging) shows nothing yet, and nothing to complain about.
        if offsetDistance.map({ abs($0) <= 1e-9 }) == true { offsetProblem = nil }
        sketch = r.sketch
        resolve()
    }

    /// Return: keeps the offset (one undo step) and selects the new curves.
    func commitOffset() -> String? {
        guard let setup = offsetSetup, let base = offsetBase else { return nil }
        if inputFields.contains(where: typedIsInvalid) { message = "That isn't a distance"; return nil }
        let r = offsetResult(on: base, setup.sources, expression: setup.expression)
        if let problem = r.problem { message = problem; return nil }
        endOffset()
        sketch = r.sketch
        selection = r.created
        resolve()
        return finish("Offset")
    }

    /// Offsets the selected curves at once, by an expression (positive goes outward, or to the left of an
    /// open chain), without the arrow.
    func offsetSelection(expression: String) -> String? {
        let r = offsetResult(on: sketch, selection, expression: expression)
        if let problem = r.problem { message = problem; return nil }
        sketch = r.sketch
        selection = r.created
        return finish("Offset")
    }

    var offsetHint: String {
        "Offset · drag the arrow, or type the distance (negative goes the other way) · Return keeps it · Esc cancels"
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

    /// Distance tool clicks: two items, then the distance between them opens for typing.
    private func distanceClick() -> String? {
        guard let h = hover, sketch.kind(of: h) != nil else {
            message = dimensionPicks.isEmpty ? "Click a point, line, circle or arc" : "Click what to measure to"
            return nil
        }
        guard !dimensionPicks.contains(h) else { return nil }
        dimensionPicks.append(h)
        guard dimensionPicks.count == 2 else {
            message = "Now click what to measure to"
            return nil
        }
        defer { dimensionPicks = [] }
        guard let suggestion = sketch.suggestDistance(for: dimensionPicks) else {
            let lines = dimensionPicks.allSatisfy { sketch.kind(of: $0) == .line }
            message = lines ? "Those lines aren't parallel. Use Dimension for the angle between them"
                            : "There's no single distance between those two"
            return nil
        }
        return addDimension(suggestion.kind, value: suggestion.value)
    }

    /// The nearest sketch point within the pick tolerance, else the nearest curve.
    func nearestEntity(_ uv: SIMD2<Double>) -> EntityID? {
        var best: (EntityID, Double)?
        for p in sketch.points where tool == .select || !Sketch.isGenerated(p.id) {
            let d = simdLength(p.position - uv)
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (p.id, d) }
        }
        if let best { return best.0 }
        let positions = sketch.positionTable()
        for c in sketch.curves where tool == .select || !Sketch.isGenerated(c.id) {
            guard mayBeNear(c, uv, positions), let g = sketch.geometry(of: c.id) else { continue }
            let d = simdLength(Self.closest(uv, on: g) - uv)
            if d <= tolerance, d < (best?.1 ?? .infinity) { best = (c.id, d) }
        }
        return best?.0
    }

    /// A cheap test that rules out most curves before the exact distance is worked out: false only when the
    /// curve is certainly farther than the pick tolerance (a circle or arc is never nearer than its whole
    /// circle; a Bézier lies inside the box of its four points).
    private func mayBeNear(_ c: SketchCurve, _ uv: SIMD2<Double>, _ position: [EntityID: SIMD2<Double>]) -> Bool {
        let tol = tolerance
        switch c.geometry {
        case .circle(let m, let r):
            guard let p = position[m] else { return true }
            return abs(simdLength(uv - p) - r) <= tol
        case .arc(let m, let a, _):
            guard let p = position[m], let pa = position[a] else { return true }
            return abs(simdLength(uv - p) - simdLength(pa - p)) <= tol
        case .line(let a, let b):
            guard let pa = position[a], let pb = position[b] else { return true }
            return Self.box([pa, pb], contains: uv, within: tol)
        case .bezier(let a, let c1, let c2, let b):
            guard let pa = position[a], let pc1 = position[c1], let pc2 = position[c2], let pb = position[b] else { return true }
            return Self.box([pa, pc1, pc2, pb], contains: uv, within: tol)
        case .ellipse(let m, let a, let b):
            // The ellipse lies between its smaller and its larger semi-axis from the center.
            guard let p = position[m], let pa = position[a], let pb = position[b] else { return true }
            let d = simdLength(uv - p), r1 = simdLength(pa - p), r2 = simdLength(pb - p)
            return d >= min(r1, r2) - tol && d <= max(r1, r2) + tol
        }
    }

    private static func box(_ pts: [SIMD2<Double>], contains p: SIMD2<Double>, within tol: Double) -> Bool {
        var lo = pts[0], hi = pts[0]
        for q in pts.dropFirst() { lo = pointwiseMin(lo, q); hi = pointwiseMax(hi, q) }
        return p.x >= lo.x - tol && p.x <= hi.x + tol && p.y >= lo.y - tol && p.y <= hi.y + tol
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

    /// Adds another sketch's shapes (e.g. from an SVG file), selects them and re-solves.
    func merge(_ other: Sketch) {
        let before = Set(sketch.curves.map(\.id))
        sketch.merge(other)
        setTool(.select)
        selection = sketch.curves.map(\.id).filter { !before.contains($0) }
        resolve()
    }

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
        // Asked for on every frame: only worked out again when the sketch has changed.
        if let cached = referenceCache, cached.sketch == sketch { return cached.value }
        let value = computeReferenceMeasurements()
        referenceCache = (sketch, value)
        return value
    }

    /// The centres of the sketch's closed shapes, where the cursor snaps: asked for on every cursor move, and
    /// only worked out again when the sketch has changed.
    func shapeCenters() -> [ShapeCenter] {
        if let cached = shapeCenterCache, cached.sketch == sketch { return cached.value }
        let value = sketch.shapeCenters()
        shapeCenterCache = (sketch, value)
        return value
    }

    @ObservationIgnored private var shapeCenterCache: (sketch: Sketch, value: [ShapeCenter])?
    @ObservationIgnored private var referenceCache: (sketch: Sketch, value: [(curve: EntityID, kind: SketchDimension.Kind, value: Double)])?

    private func computeReferenceMeasurements() -> [(curve: EntityID, kind: SketchDimension.Kind, value: Double)] {
        let suggestions = sketch.sizeSuggestions()
        var sized = Set<EntityID>()
        var spans: [Set<EntityID>: EntityID] = [:]  // a rounded side's corner-to-corner span -> the line
        for c in sketch.curves {
            if case .distance(let a, let b)? = suggestions[c.id]?.kind { spans[[a, b]] = c.id }
        }
        for d in sketch.dimensions {
            switch d.kind {
            case .length(let c), .radius(let c), .diameter(let c): sized.insert(c)
            case .distance(let a, let b): if let line = spans[[a, b]] { sized.insert(line) }
            default: break
            }
        }
        return sketch.curves.compactMap { c in
            guard !c.construction, !Sketch.isGenerated(c.id), !sized.contains(c.id), let s = suggestions[c.id] else { return nil }
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
        return addDimension(suggestion.kind, value: suggestion.value)
    }

    /// Adds a dimension at its current value and opens it for typing.
    private func addDimension(_ kind: SketchDimension.Kind, value: Double) -> String? {
        let unit: UnitKind
        if case .angle = kind { unit = .angle } else { unit = .length }
        let id = IDs.make()
        guard sketch.applyDimension(kind, expression: formatDimension(value, kind: unit), value: value,
                                    values: values, id: id) else {
            message = "That dimension would over-constrain the sketch"
            return nil
        }
        if let i = sketch.dimensions.firstIndex(where: { $0.id == id }) {
            sketch.dimensions[i].offset = sketch.defaultOffset(for: kind, value: value)
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
        else if patternSetup != nil { cancelPattern() }
        else if mirrorSetup != nil { cancelMirror() }
        else if gearBackup != nil { cancelGearEdit() }
        else if gearActive != nil { gearActive = nil }  // the next click places another gear
        else if offsetSetup != nil { cancelOffset() }
        else if manipulating != nil { stopManipulating() }
        else if tool != .select { setTool(.select) }
        else { selection = [] }
    }

    func deleteSelection() -> String? {
        if tool == .gear, gearActive != nil { return deleteActiveGear() }
        // With nothing selected, Delete takes the dimension line under the pointer.
        if selection.isEmpty, let d = hoverDimension { return deleteDimension(d) }
        guard !selection.isEmpty else { return nil }
        // The selected image of a mirror: deleting it takes the mirror away. Copies of a pattern go with their pattern's own Delete.
        let images = Set(selection.compactMap { Sketch.isGenerated($0) ? Sketch.pattern(ofGenerated: $0) : nil })
        let removedMirrors = sketch.mirrors.filter { images.contains($0.id) }.map(\.id)
        let drawn = selection.filter { !Sketch.isGenerated($0) }
        guard !removedMirrors.isEmpty || !drawn.isEmpty else { return nil }
        sketch.mirrors.removeAll { removedMirrors.contains($0.id) }
        sketch.delete(Set(drawn))
        sketch.refreshGenerated(parameters)
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

    /// Removes a dimension; the sketch keeps the size it has now, free to change again.
    func deleteDimension(_ id: EntityID) -> String? {
        guard sketch.dimensions.contains(where: { $0.id == id }) else { return nil }
        sketch.delete([id])
        if editingDimension == id { editingDimension = nil }
        hoverDimension = nil
        return finish("Delete Dimension")
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

    /// The dimension whose line (the part between its arrows, or the arrows) the point is on, within the pick tolerance.
    func dimensionLine(near uv: SIMD2<Double>) -> EntityID? {
        var best: (EntityID, Double)?
        for d in sketch.dimensions {
            guard let line = sketch.dimensionLine(of: d) else { continue }
            let a = line.q1, b = line.q2, ab = b - a
            let t = min(max(simd_dot(uv - a, ab) / max(simd_dot(ab, ab), 1e-18), 0), 1)
            let dist = simdLength(uv - (a + ab * t))
            if dist <= tolerance, dist < (best?.1 ?? .infinity) { best = (d.id, dist) }
        }
        return best?.0
    }

    /// Drags a dimension's line to where the cursor is: only how far it stands from what it measures changes.
    private func moveDimensionLine(_ id: EntityID, to uv: SIMD2<Double>) {
        guard let i = sketch.dimensions.firstIndex(where: { $0.id == id }), let line = sketch.dimensionLine(of: sketch.dimensions[i])
        else { return }
        sketch.dimensions[i].offset = line.value(through: uv)
    }

    /// How a distance between two points is taken, when it can be changed.
    enum DistanceDirection: String, CaseIterable, Identifiable {
        case aligned = "Straight", horizontal = "Horizontal", vertical = "Vertical"
        var id: String { rawValue }
    }

    func distanceDirection(of id: EntityID) -> DistanceDirection? {
        switch sketch.dimensions.first(where: { $0.id == id })?.kind {
        case .distance?: return .aligned
        case .horizontalDistance?: return .horizontal
        case .verticalDistance?: return .vertical
        default: return nil
        }
    }

    /// Measures a distance between two points straight, or only sideways or only up and down. The
    /// value stays what it is now (nothing moves); type a new one to move the points.
    func setDistanceDirection(_ id: EntityID, _ direction: DistanceDirection) -> String? {
        guard let i = sketch.dimensions.firstIndex(where: { $0.id == id }) else { return nil }
        let ends: (EntityID, EntityID)
        switch sketch.dimensions[i].kind {
        case .distance(let a, let b), .horizontalDistance(let a, let b), .verticalDistance(let a, let b): ends = (a, b)
        default: return nil
        }
        let kind: SketchDimension.Kind
        switch direction {
        case .aligned: kind = .distance(ends.0, ends.1)
        case .horizontal: kind = .horizontalDistance(ends.0, ends.1)
        case .vertical: kind = .verticalDistance(ends.0, ends.1)
        }
        guard kind != sketch.dimensions[i].kind, let value = sketch.measure(kind) else { return nil }
        var trial = sketch
        trial.dimensions[i].kind = kind
        trial.dimensions[i].expression = formatDimension(value, kind: .length)
        var v = values
        v[id] = value
        guard SketchSolver.solveLocally(&trial, dimensionValues: v).status == .solved else {
            message = "The sketch can't take that"
            return nil
        }
        sketch = trial
        return finish("Edit Dimension")
    }

    // MARK: display

    /// Rubber-band geometry for the tool in progress, in sketch coordinates.
    func previewPolylines() -> [[SIMD2<Double>]] {
        if tool == .bezier { return curvePreview()?.lines ?? [] }
        if tool == .gear { return gearPreview() }
        guard !clicks.isEmpty, let c = target()?.position else { return [] }
        let a = clicks[0].position
        switch tool {
        case .line: return [[a, c]]
        case .rectangle: return [[a, SIMD2(c.x, a.y), c, SIMD2(a.x, c.y), a]]
        case .roundedRectangle:
            let x0 = min(a.x, c.x), x1 = max(a.x, c.x), y0 = min(a.y, c.y), y1 = max(a.y, c.y)
            let r = min(roundedRadiusValue, min(x1 - x0, y1 - y0) / 2)
            guard r > 1e-6 else { return [[a, c]] }
            // Four quarter arcs, joined by the straight sides; the last point repeats the first to close the outline.
            let outline = circle(SIMD2(x1 - r, y0 + r), r, -.pi / 2, 0) + circle(SIMD2(x1 - r, y1 - r), r, 0, .pi / 2)
                + circle(SIMD2(x0 + r, y1 - r), r, .pi / 2, .pi) + circle(SIMD2(x0 + r, y0 + r), r, .pi, 1.5 * .pi)
            return [outline + [outline[0]]]
        case .ellipse:
            // The axis to the second click, and the ellipse with its other axis reaching to the cursor.
            guard clicks.count == 2, c != a else { return [[a, c]] }
            let axis = clicks[1].position - a, len = simdLength(axis)
            guard len > 1e-9 else { return [] }
            let perp = SIMD2(-axis.y, axis.x) / len
            let u = axis, v = perp * ((c - a).x * perp.x + (c - a).y * perp.y)
            return [(0...192).map { i in
                let t = Double(i) * 2 * .pi / 192
                return a + u * cos(t) + v * sin(t)
            }, [a, clicks[1].position]]
        case .tangentArc:
            // The arc from the start, along its free end, to the cursor, as it would be drawn.
            guard clicks.count == 1, let p = clicks[0].point, let free = sketch.freeEnd(at: p),
                  let made = Sketch.tangentArc(from: a, direction: free.direction, to: c) else { return [[a, c]] }
            let a0 = atan2(a.y - made.center.y, a.x - made.center.x)
            var a1 = atan2(c.y - made.center.y, c.x - made.center.x)
            if made.ccw { while a1 <= a0 { a1 += 2 * .pi } } else { while a1 >= a0 { a1 -= 2 * .pi } }
            return [circle(made.center, simdLength(a - made.center), a0, a1)]
        case .centerRectangle:
            let o = 2 * a - c
            return [[o, SIMD2(c.x, o.y), c, SIMD2(o.x, c.y), o], [o, c]]
        case .arc3Point:
            guard clicks.count > 1 else { return [[a, c]] }
            // The arc from start to end through the cursor, as it would be drawn.
            var trial = Sketch()
            guard let id = trial.addArc(from: SketchSnap(a), to: SketchSnap(clicks[1].position), through: SketchSnap(c)),
                  let g = trial.geometry(of: id) else { return [[a, clicks[1].position]] }
            return [(0...48).map { g.point(Double($0) / 48) }]
        case .slot, .overallSlot:
            // The two ends and the sides, as they would be drawn to the cursor.
            let r = slotWidthValue / 2
            var from = a, to = c
            if tool == .overallSlot {  // the clicks are the outside ends: the centers sit a radius inside them
                let len = simdLength(c - a)
                guard len > 2 * r + 1e-6 else { return [] }
                let inset = (c - a) / len * r
                from = a + inset
                to = c - inset
            }
            let len = simdLength(to - from)
            guard len > 1e-6 else { return [circle(from, r, 0, 2 * .pi)] }
            let t = atan2(to.y - from.y, to.x - from.x)
            let outline = circle(from, r, t + .pi / 2, t + 3 * .pi / 2) + circle(to, r, t - .pi / 2, t + .pi / 2)
            return [outline + [outline[0]]]  // back to the start: the last side closes the loop
        case .circle:
            let r = simdLength(c - a)
            return [circle(a, r, 0, 2 * .pi)]
        case .circle2Point:
            return [circle((a + c) / 2, simdLength(c - a) / 2, 0, 2 * .pi), [a, c]]
        case .polygon, .triangle:
            let r = simdLength(c - a), first = atan2(c.y - a.y, c.x - a.x), n = sidesCount
            return [(0...n).map { k in
                let t = first + 2 * .pi * Double(k) / Double(n)
                return a + r * SIMD2(cos(t), sin(t))
            }, [a, c]]
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

    /// The next gear as it would be drawn at the cursor (not while one is active: it is already shown).
    private func gearPreview() -> [[SIMD2<Double>]] {
        guard gearActive == nil, let c = target()?.position, let spec = try? gearDefaults.spec(parameters),
              let pieces = try? GearProfile.outline(spec) else { return [] }
        var line: [SIMD2<Double>] = []
        for piece in pieces {
            switch piece {
            case .line(let a, let b): line += [a, b]
            case .bezier(let a, let h1, let h2, let b): line += Bezier.flatten([a, h1, h2, b], steps: 8)
            case .arc(let a, let b):
                let r = simdLength(a), a0 = atan2(a.y, a.x)
                var sweep = atan2(b.y, b.x) - a0
                if sweep <= 0 { sweep += 2 * .pi }
                let n = max(Int(sweep * r / 0.5), 2)
                line += (0...n).map { k in let t = a0 + sweep * Double(k) / Double(n); return SIMD2(r * cos(t), r * sin(t)) }
            }
        }
        var out = [line.map { $0 + c }]
        if spec.boreDiameter > 0 {
            out.append((0...48).map { k in let t = 2 * Double.pi * Double(k) / 48; return c + spec.boreDiameter / 2 * SIMD2(cos(t), sin(t)) })
        }
        return out
    }

    /// The curves the Curve tool would draw next: the new one, and the last one placed (and, when the
    /// run would close, the first), which turn to meet it. `redrawn` are those already in the sketch.
    private func curvePreview() -> (lines: [[SIMD2<Double>]], redrawn: Set<EntityID>)? {
        let next = curveDown ?? target()
        guard let next else { return nil }
        guard let chain = curveChain else {
            guard let first = clicks.first else {  // nothing placed yet: just the handle being pulled out
                guard let down = curveDown, let pull = curvePull else { return nil }
                return ([[down.position - pull, down.position + pull]], [])
            }
            let pull = curveFirstPull, end = next.position
            guard distance(first, next) > 1e-6 else { return nil }
            return (curveLines([first.position, end], [pull, curvePull], closed: false, from: 0, handlesAt: end), [])
        }
        let anchors = chain.anchors.compactMap { sketch.position($0) }
        guard anchors.count == chain.anchors.count, let last = anchors.last, simdLength(next.position - last) > 1e-6 else { return nil }
        let pulled = chain.anchors.map { chain.pulled[$0] }
        if chain.anchors.count >= 3, next.point == chain.anchors.first {  // closes: smooth all the way round
            let lines = curveLines(anchors, pulled, closed: true, from: chain.segments.count - 1, handlesAt: nil)
            let first = Bezier.flatten(Self.poles(anchors, pulled, closed: true)[0])
            let redrawn = Set([chain.segments.first, chain.segments.last].compactMap { $0?.curve })
            return (lines + [first], redrawn)
        }
        let lines = curveLines(anchors + [next.position], pulled + [curvePull], closed: false,
                               from: chain.segments.count - 1, handlesAt: next.position)
        return (lines, Set([chain.segments.last?.curve].compactMap { $0 }))
    }

    private static func poles(_ anchors: [SIMD2<Double>], _ pulled: [SIMD2<Double>?], closed: Bool) -> [[SIMD2<Double>]] {
        let handles = Bezier.smoothHandles(through: anchors, pulled: pulled, closed: closed)
        return handles.enumerated().map { i, h in [anchors[i], h.0, h.1, anchors[(i + 1) % anchors.count]] }
    }

    /// The curve through `anchors` from segment `from` on, with the thin handle lines, and the handle
    /// being pulled out at `handlesAt` (the point the mouse is down on).
    private func curveLines(_ anchors: [SIMD2<Double>], _ pulled: [SIMD2<Double>?], closed: Bool, from: Int,
                            handlesAt: SIMD2<Double>?) -> [[SIMD2<Double>]] {
        var lines: [[SIMD2<Double>]] = []
        for p in Self.poles(anchors, pulled, closed: closed).dropFirst(max(from, 0)) {
            lines += [Bezier.flatten(p), [p[0], p[1]], [p[3], p[2]]]
        }
        if let at = handlesAt, let pull = curvePull { lines.append([at, at + pull]) }
        return lines
    }

    /// Curves already in the sketch that the Curve tool's preview draws over, so they aren't drawn twice.
    var redrawnCurves: Set<EntityID> { tool == .bezier ? curvePreview()?.redrawn ?? [] : [] }

    func circle(_ c: SIMD2<Double>, _ r: Double, _ a0: Double, _ a1: Double) -> [SIMD2<Double>] {
        let n = max(8, Int(abs(a1 - a0) / (2 * .pi) * 96))
        return (0...n).map { i in
            let t = a0 + (a1 - a0) * Double(i) / Double(n)
            return c + r * SIMD2(cos(t), sin(t))
        }
    }

    var statusText: String {
        if let message { return message }
        if patternSetup != nil { return message ?? patternHint }
        if mirrorSetup != nil { return message ?? mirrorHint }
        if offsetSetup != nil { return message ?? offsetHint }
        var s = manipulating == nil ? tool.hint : "Drag an arrow, the square or the ring to move or turn \(selection.isEmpty ? "the sketch" : "the selection") · or type the values · Esc to stop"
        if let snap = lastSnap { s = "Snap: \(snap.kind.rawValue)\(snap.kind == .grid ? " \(gridStep.map { formatDimension($0, kind: .length) } ?? "")" : "") · " + s }
        if !inputFields.isEmpty, manipulating == nil {
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

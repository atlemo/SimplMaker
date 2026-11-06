// The controls the Mac draws over the viewport as AppKit views, as SwiftUI over the iPad's: a sketch's dimension labels and constraint
// glyphs, the numeric fields beside a feature's arrows and beside a shape being drawn. Each is placed by projecting a point of the model
// through the camera, so it follows the part as the view moves.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

/// How the camera sees the model right now, for the overlays: they redraw when `revision` changes (the camera moved or the view resized).
@MainActor @Observable
final class PadViewState {
    var revision = 0
    var size: CGSize = .zero
    @ObservationIgnored weak var renderer: Renderer?
    /// Takes a picture of the view as PNG data (set by the viewport).
    /// The cube's actions on the camera (set by the viewport), and how much of the top the navigation bar and tool bar cover.
    @ObservationIgnored var lookAlong: ((SIMD3<Float>) -> Void)?
    @ObservationIgnored var orbit: ((Float, Float) -> Void)?
    @ObservationIgnored var turn: ((Int) -> Void)?
    var topInset: CGFloat = 0
    @ObservationIgnored var capture: ((@escaping @MainActor @Sendable (Data?) -> Void) -> Void)?
    @ObservationIgnored private var lastPose: CameraPose?

    func project(_ world: SIMD3<Float>) -> CGPoint? { renderer?.camera.project(world, viewSize: size) }
    func project(_ world: SIMD3<Double>) -> CGPoint? { project(SIMD3(Float(world.x), Float(world.y), Float(world.z))) }

    /// Called as the view draws: notes a camera move, which the overlays follow.
    func cameraMayHaveMoved(size newSize: CGSize) {
        guard let pose = renderer?.camera.pose else { return }
        if newSize != size || lastPose.map({ !$0.isClose(to: pose) }) ?? true {
            lastPose = pose
            Task { @MainActor [self] in
                size = newSize
                revision += 1
            }
        }
    }
}

struct PadOverlays: View {
    let model: DocumentModel
    let state: PadViewState
    let insets: (left: CGFloat, right: CGFloat, bottom: CGFloat)
    @AppStorage(Preferences.showConstraints) private var showConstraints = true

    var body: some View {
        let _ = state.revision
        let _ = model.overlayRevision
        ZStack(alignment: .topLeading) {
            PadManipulator(model: model, state: state)
            if let session = model.sketchSession {
                PadSketchRulers(state: state)
                PadDimensionLabels(model: model, session: session, state: state)
                if showConstraints || true { PadGlyphs(model: model, session: session, state: state, showConstraints: showConstraints) }
                PadSketchFields(model: model, session: session, state: state, insets: insets)
                PadTextEntry(model: model, session: session, state: state, insets: insets)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            PadViewCube(model: model, state: state)
                .padding(.trailing, insets.right + 12)
                .padding(.top, state.topInset + 8)
        }
    }
}

/// How far the on-screen keyboard reaches up from the bottom of the screen: 0 with none (a hardware keyboard shows only a thin bar). The fields
/// that are typed in keep above it. Started when the first part opens, so a keyboard raised later is seen.
@MainActor @Observable
final class KeyboardWatcher {
    static let shared = KeyboardWatcher()
    private(set) var overlap: CGFloat = 0
    private init() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let value = max(0, UIScreen.main.bounds.height - frame.minY)
            MainActor.assumeIsolated { self?.overlap = value }
        }
        // A size field starts with its text selected (as on the Mac), so what is typed replaces it.
        NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { note in
            guard let field = note.object as? UITextField, field.keyboardType == .numbersAndPunctuation else { return }
            DispatchQueue.main.async { field.selectAll(nil) }
        }
    }
}

// MARK: dimension labels

private struct PadDimensionLabels: View {
    let model: DocumentModel
    let session: SketchSession
    let state: PadViewState
    @Environment(\.accent) private var accent

    /// A label's size, estimated from its text (the layout does not report back).
    private func size(_ text: String) -> CGSize { CGSize(width: CGFloat(text.count) * 8 + 22, height: 30) }

    private func placed() -> [(label: DimensionLabel, center: CGPoint)] {
        var out: [(DimensionLabel, CGPoint)] = []
        var frames: [CGRect] = []
        for l in model.dimensionLabels() {
            guard let p = state.project(l.world) else { continue }
            let s = size(l.text)
            var center = p
            if let o = l.outward, let tip = state.project(l.world + o) {
                let d = CGVector(dx: tip.x - p.x, dy: tip.y - p.y), len = hypot(d.dx, d.dy)
                if len > 1e-3 {
                    let u = CGVector(dx: d.dx / len, dy: d.dy / len)
                    let reach = abs(u.dx) * s.width / 2 + abs(u.dy) * s.height / 2 + 8
                    center = CGPoint(x: p.x + u.dx * reach, y: p.y + u.dy * reach)
                }
            }
            var frame = CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
            for _ in 0..<8 {
                guard let hit = frames.first(where: { $0.insetBy(dx: -2, dy: -2).intersects(frame) }) else { break }
                frame.origin.y = hit.maxY + 4
            }
            frames.append(frame)
            out.append((l, CGPoint(x: frame.midX, y: frame.midY)))
        }
        return out
    }

    var body: some View {
        ForEach(placed(), id: \.label.id) { item in
            let l = item.label
            Button { clicked(l.id) } label: {
                Text(l.text)
                    .font(.system(size: 14, weight: l.isDimension ? .medium : .regular).monospacedDigit())
                    .foregroundStyle(l.reference ? Color.secondary : Color.primary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(l.editing ? accent : (l.isDimension ? accent.opacity(0.8) : Color.secondary.opacity(0.4)), lineWidth: l.editing ? 2 : 1))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!l.passesClicks)
            .popover(isPresented: Binding(get: { session.editingDimension == l.id },
                                          set: { if !$0 { session.editingDimension = nil; model.overlayRevision += 1 } })) {
                DimensionEditor(model: model, session: session, dimensionID: l.id) {
                    session.editingDimension = nil
                    model.overlayRevision += 1
                }
                .padding(8)
            }
            .position(item.center)
        }
    }

    private func clicked(_ id: EntityID) {
        if model.showsOriginPlanes, let plane = OriginPlane(labelID: id) {
            model.clickRay = nil
            model.click(plane.pickID, additive: false)
        } else if let curve = DimensionLabel.curve(ofReference: id) {
            model.sketchCommand { $0.dimensionReference(curve) }  // a measured size becomes a dimension
        } else if session.sketch.dimensions.contains(where: { $0.id == id }) {
            session.editingDimension = id
        }
        model.overlayRevision += 1
    }
}

// MARK: constraint glyphs

private struct PadGlyphs: View {
    let model: DocumentModel
    let session: SketchSession
    let state: PadViewState
    let showConstraints: Bool

    private func wanted() -> [(glyph: ConstraintGlyph, at: CGPoint)] {
        // A pattern's or mirror's button stays when constraint symbols are hidden: it is the way into them.
        let all = (showConstraints ? SketchOverlayBuilder.glyphs(session) : [])
            + SketchOverlayBuilder.patternGlyphs(session) + SketchOverlayBuilder.mirrorGlyphs(session)
        var frames: [CGRect] = []
        var out: [(ConstraintGlyph, CGPoint)] = []
        for g in all {
            guard let p = state.project(g.world) else { continue }
            var frame = CGRect(x: p.x + 10 + CGFloat(g.stack) * 30, y: p.y + 8, width: 28, height: 28)
            for _ in 0..<10 {
                guard let hit = frames.first(where: { $0.insetBy(dx: -1, dy: -1).intersects(frame) }) else { break }
                frame.origin.y = hit.maxY + 2
            }
            frames.append(frame)
            out.append((g, CGPoint(x: frame.midX, y: frame.midY)))
        }
        return out
    }

    var body: some View {
        ForEach(wanted(), id: \.glyph.id) { item in
            let g = item.glyph
            Button {
                if g.pattern != nil { model.beginSketchPattern(editing: g.constraint) }
                else if g.mirror != nil { model.beginSketchMirror(editing: g.constraint) }
                else { model.selectSketchItem(g.constraint, additive: false) }
                model.overlayRevision += 1
            } label: {
                Text(g.mirror != nil ? "⇋" : g.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(g.problem ? Color.red : (g.selected ? Color.white : Color.primary))
                    .frame(width: 26, height: 26)
                    .background(g.selected ? Color.accentColor : Color(.systemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(g.problem ? Color.red : Color.secondary.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .position(item.at)
        }
    }
}

// MARK: fields beside a shape being drawn

private struct PadSketchFields: View {
    let model: DocumentModel
    let session: SketchSession
    let state: PadViewState
    let insets: (left: CGFloat, right: CGFloat, bottom: CGFloat)

    /// Room under the fields for the Done / Cancel / OK bar that floats above the timeline while a tool is in the middle of something.
    private var barReserve: CGFloat {
        session.isOffsetting || session.isPatterning ? 116 : (session.toolInProgress || session.isManipulating ? 92 : 0)
    }

    var body: some View {
        let inputs = session.inputFields
        if !inputs.isEmpty, let t = session.manipulatorMiddle ?? session.target()?.position {
            let startsAtFirstClick: Set<SketchTool> = [.rectangle, .centerRectangle, .roundedRectangle, .slot, .overallSlot, .circle, .circle2Point, .polygon, .triangle]
            let anchor = session.gearAnchor ?? (session.manipulatorMiddle == nil && startsAtFirstClick.contains(session.tool)
                ? session.clicks.first?.position ?? t : t)
            let world = session.frame.point(anchor.x, anchor.y)
            if let p = state.project(world) {
                // With the manipulator up (Transform, Offset, Pattern) the fields stay at the bottom, off the arrows and rings a finger takes hold of.
                let docked = session.manipulatorMiddle != nil
                let lowest = max(state.size.height - max(insets.bottom + barReserve, KeyboardWatcher.shared.overlap) - 40, 40)
                HStack(spacing: 8) {
                    ForEach(inputs) { input in SketchField(model: model, session: session, input: input) }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .fixedSize()
                .position(x: docked ? insets.left + (state.size.width - insets.left - insets.right) / 2
                                    : min(max(p.x + 20 + 120, insets.left + 130), max(state.size.width - insets.right - 130, insets.left + 130)),
                          y: docked ? lowest : min(max(p.y + 44, 40), lowest))
                    .animation(.easeOut(duration: 0.25), value: KeyboardWatcher.shared.overlap)
            }
        }
    }
}

private struct SketchField: View {
    let model: DocumentModel
    let session: SketchSession
    let input: SketchInput
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(input.rawValue).font(.caption2).foregroundStyle(.secondary)
            TextField(input.rawValue, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .focused($focused)
                .numericEntry()
                .foregroundStyle(session.typedIsInvalid(input) ? Color.red : (session.typed[input] != nil ? Color.primary : Color.secondary))
                .onChange(of: text) {
                    guard focused else { return }
                    session.setTyped(input, text)
                    model.overlayRevision += 1
                }
                .onSubmit { model.commitSketchTyped() }
                .completesParameters(model, focused: focused)
        }
        .onAppear { text = shown }
        .onChange(of: model.overlayRevision) { if !focused { text = shown } }
    }

    private var shown: String {
        session.typed[input] ?? session.liveValue(input).map { formatDimension($0, kind: input.unit) } ?? ""
    }
}

// MARK: fields beside a feature's arrows

struct PadHandleFields: View {
    let model: DocumentModel
    let state: PadViewState
    let insets: (left: CGFloat, right: CGFloat, bottom: CGFloat)
    @FocusState private var focusedSlot: Int?
    @State private var hudSize = CGSize(width: 300, height: 40)

    var body: some View {
        let _ = state.revision
        let _ = model.overlayRevision
        let handles = model.dragHandles.filter { model.showsField($0) }
        if !handles.isEmpty {
            // The feature bar and the fields stay above the on-screen keyboard.
            let bottom = max(insets.bottom, KeyboardWatcher.shared.overlap)
            let hudTop = state.size.height - hudSize.height - bottom
            ZStack(alignment: .topLeading) {
                ForEach(Array(handles.enumerated()), id: \.element.slot) { index, h in
                    if let p = anchor(h) {
                        // Centre of this field: not lower than the room above the bar leaves for it and the fields after it.
                        let lowest = hudTop - 8 - 20 - CGFloat(handles.count - 1 - index) * 40
                        HandleField(model: model, handle: h, focused: $focusedSlot)
                            .position(x: min(max(p.x + 26 + 55, insets.left + 60), max(state.size.width - insets.right - 70, insets.left + 60)),
                                      y: min(max(p.y + CGFloat(index) * 40, 24), max(min(state.size.height - 24, lowest), 24)))
                    }
                }
                if let first = handles.first, let p = anchor(first) {
                    // Just below the fields, and left of the inspector rather than under it.
                    let minX = insets.left + 8
                    let maxX = max(state.size.width - insets.right - hudSize.width - 8, minX)
                    FeatureHUD(model: model)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { hudSize = $0 }
                        .position(x: min(max(p.x + 26, minX), maxX) + hudSize.width / 2,
                                  y: min(p.y + 44 + CGFloat(handles.count) * 40, hudTop) + hudSize.height / 2)
                }
            }
            .animation(.easeOut(duration: 0.25), value: KeyboardWatcher.shared.overlap)
            .onChange(of: model.handleFocusRequest) {
                focusedSlot = model.handleFocusSlot ?? handles.first?.slot
                model.handleFocusSlot = nil
            }
        }
    }

    private func anchor(_ h: DocumentModel.DragHandle) -> CGPoint? { state.project(h.anchor) }
}

private struct HandleField: View {
    let model: DocumentModel
    let handle: DocumentModel.DragHandle
    @FocusState.Binding var focused: Int?
    @State private var text = ""
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            TextField(handle.label, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 112)
                .focused($focused, equals: handle.slot)
                .numericEntry()
                .foregroundStyle(model.previewInvalid && handle.slot == model.activeHandleSlot ? Color.red : Color.primary)
                .onChange(of: text) { schedulePreview() }
                .onSubmit {
                    if model.commitHandle(text, for: handle.featureID, slot: handle.slot) { model.finishFeatureEdit() }
                    else { model.cancelHandleEdit(); text = model.handleFieldText(for: handle.slot) ?? text }
                }
                .completesParameters(model, focused: focused == handle.slot)
                .accessibilityLabel(handle.label)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { text = model.handleFieldText(for: handle.slot) ?? "" }
        .onChange(of: model.overlayRevision) { if focused != handle.slot { text = model.handleFieldText(for: handle.slot) ?? text } }
        .onChange(of: focused) {
            if focused == handle.slot { model.activeHandleSlot = handle.slot }
        }
    }

    /// Previews a typed size once typing pauses.
    private func schedulePreview() {
        guard focused == handle.slot else { return }
        previewTask?.cancel()
        let typed = text
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            model.activeHandleSlot = handle.slot
            _ = model.previewHandle(typed)
        }
    }
}

// MARK: the Move/Rotate manipulator

/// The Move feature's arrows, squares and rings, drawn over the viewport. It takes no touches of its own: the viewport's finger drag
/// asks the same layout what it has hold of (see `PadViewport`).
struct PadManipulator: View {
    let model: DocumentModel
    let state: PadViewState

    private static func color(of axis: Axis3) -> Color {
        switch axis {
        case .x: return Color(red: 0.92, green: 0.24, blue: 0.24)
        case .y: return Color(red: 0.22, green: 0.68, blue: 0.30)
        case .z: return Color(red: 0.24, green: 0.48, blue: 0.95)
        }
    }

    var body: some View {
        let _ = state.revision
        let _ = model.overlayRevision
        if let renderer = state.renderer, let place = model.manipulatorPlacement,
           let layout = ManipulatorLayout(middle: place.middle, turn: place.turn, frame: place.frame, camera: renderer.camera, viewSize: state.size) {
            let active = model.manipulatorActivePart
            Canvas { ctx, _ in draw(&ctx, layout, active) }
                .allowsHitTesting(false)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ layout: ManipulatorLayout, _ active: ManipulatorPart?) {
        let body = Color(white: 0.88), lit = Color(red: 0.35, green: 0.72, blue: 1)
        func fill(_ part: ManipulatorPart) -> Color { part == active ? lit : body }
        func polygon(_ pts: [CGPoint]) -> Path { var p = Path(); p.addLines(pts); p.closeSubpath(); return p }
        let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        for ring in layout.rings {
            let path = polygon(ring.outline)
            let strong = ManipulatorPart.ring(ring.axis) == active
            ctx.stroke(path, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: .color(Self.color(of: ring.axis).opacity(strong ? 1 : 0.85)),
                       style: StrokeStyle(lineWidth: strong ? 3.2 : 1.8, lineCap: .round, lineJoin: .round))
        }
        for square in layout.squares {
            let path = polygon(square.corners)
            ctx.fill(path, with: .color(fill(.plane(square.normal))))
            ctx.stroke(path, with: .color(.black), style: line)
        }
        for arrow in layout.arrows {
            var color = fill(.axis(arrow.axis))
            if layout.frame.coloredArrows, arrow.axis != .z {
                let base = Self.color(of: arrow.axis)
                color = ManipulatorPart.axis(arrow.axis) == active ? base.opacity(0.6) : base
            }
            let path = polygon(arrow.polygon)
            ctx.fill(path, with: .color(color))
            ctx.stroke(path, with: .color(.black), style: line)
        }
        func disc(_ c: CGPoint, _ r: CGFloat, _ color: Color, dot: Color?) {
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(color))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.black), style: line)
            if let dot { ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(dot)) }
        }
        disc(layout.center, ManipulatorLayout.dotRadius, fill(.center), dot: nil)
        for ring in layout.rings {
            let color = Self.color(of: ring.axis)
            disc(ring.handle, ManipulatorLayout.handleRadius, ManipulatorPart.ring(ring.axis) == active ? color.opacity(0.5) : body, dot: color)
        }
    }
}

/// The Text tool's fields: the words and the size of the letters, below the point that was tapped, until Return or Cancel.
/// The letters appear in the sketch as they are typed.
private struct PadTextEntry: View {
    let model: DocumentModel
    let session: SketchSession
    let state: PadViewState
    let insets: (left: CGFloat, right: CGFloat, bottom: CGFloat)
    @State private var words = ""
    @State private var size = ""
    @State private var editing: EntityID?
    @FocusState private var focus: Field?
    private enum Field { case words, size }

    var body: some View {
        if let at = session.pendingText?.position {
            let world = session.frame.point(at.x, at.y)
            if let p = state.project(world) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Type the text", text: $words)
                            .frame(width: 220)
                            .focused($focus, equals: .words)
                            .submitLabel(.done)
                            .onSubmit { done() }
                            .onChange(of: words) { session.setTextDraft(words); model.overlayRevision += 1 }
                        TextField("Size", text: $size)
                            .frame(width: 84)
                            .focused($focus, equals: .size)
                            .numericEntry()
                            .foregroundStyle(session.textHeightIsUsable ? Color.primary : Color.red)
                            .onSubmit { done() }
                            .onChange(of: size) { session.setTextHeightDraft(size); model.overlayRevision += 1 }
                            .completesParameters(model, focused: focus == .size)
                    }
                    .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel", role: .cancel) { session.cancelText(); model.overlayRevision += 1 }
                        Spacer()
                        Button("Done") { done() }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .fixedSize()
                .position(x: min(max(p.x + 160, insets.left + 180), max(state.size.width - insets.right - 180, insets.left + 180)),
                          y: min(max(p.y + 70, 80), max(state.size.height - max(insets.bottom, KeyboardWatcher.shared.overlap) - 70, 80)))
                .onAppear { load() }
                .onChange(of: session.editingText) { load() }
            }
        }
    }

    /// Starts with the words and size of the text being edited, or an empty box and the size the last text had.
    private func load() {
        words = session.textEntryInitial
        size = session.textHeightDraft
        editing = session.editingText
        DispatchQueue.main.async { focus = .words }
    }

    private func done() {
        guard session.textHeightIsUsable else { focus = .size; return }
        let text = words
        model.sketchCommand { $0.placeText(text) }
        model.overlayRevision += 1
    }
}

/// Numbers at the major grid lines along the sketch's axes, and the origin marker where the axes cross (as on the Mac).
private struct PadSketchRulers: View {
    let state: PadViewState

    var body: some View {
        let _ = state.revision
        if let grid = state.renderer?.sketchGrid { rulers(grid) }
    }

    private func rulers(_ grid: SketchGrid) -> some View {
        do {
            let size = state.size
            let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
            func at(_ u: Double, _ v: Double) -> CGPoint? { state.project(grid.frame.point(u, v)) }
            // Which way the numbers sit off their axis on screen: below the horizontal one, right of the vertical one.
            func across(alongU: Bool) -> CGVector {
                guard let a = at(0, 0), let b = alongU ? at(1, 0) : at(0, 1) else { return alongU ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0) }
                let len = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
                var n = CGVector(dx: -(b.y - a.y) / len, dy: (b.x - a.x) / len)
                if alongU ? (n.dy < -1e-6 || (abs(n.dy) <= 1e-6 && n.dx < 0)) : (n.dx < -1e-6 || (abs(n.dx) <= 1e-6 && n.dy < 0)) {
                    n = CGVector(dx: -n.dx, dy: -n.dy)
                }
                return n
            }
            let labels = rulerLabels(grid: grid, at: at, visible: visible, across: across)
            return ZStack(alignment: .topLeading) {
                ForEach(labels, id: \.id) { l in
                    Text(l.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(l.point)
                }
                if let o = at(0, 0), visible.contains(o) {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.55))
                        Circle().strokeBorder(Color.secondary, lineWidth: 1.2)
                        Path { p in
                            p.move(to: CGPoint(x: 10, y: 10)); p.addArc(center: CGPoint(x: 10, y: 10), radius: 8,
                                                                       startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
                            p.closeSubpath()
                        }.fill(Color(uiColor: .systemBackground).opacity(0.9))
                    }
                    .frame(width: 20, height: 20)
                    .position(o)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private struct RulerLabel { let id: String; let text: String; let point: CGPoint }

    private func rulerLabels(grid: SketchGrid, at: (Double, Double) -> CGPoint?, visible: CGRect,
                             across: (Bool) -> CGVector) -> [RulerLabel] {
        var out: [RulerLabel] = []
        for (alongU, range) in [(true, grid.u), (false, grid.v)] {
            let n = across(alongU)
            var k = (range.lowerBound / grid.major).rounded()
            while k * grid.major <= range.upperBound + 1e-9, out.count < 80 {
                let value = k * grid.major
                k += 1
                guard abs(value) > 1e-9, let p = alongU ? at(value, 0) : at(0, value), visible.contains(p) else { continue }
                let text = Preferences.rulerText(value, us: Preferences.unitSystemSetting.isUS)
                let w = CGFloat(text.count) * 6.5, h: CGFloat = 13
                let reach = 8 + abs(n.dx) * w / 2 + abs(n.dy) * h / 2
                out.append(RulerLabel(id: (alongU ? "u:" : "v:") + text, text: text,
                                      point: CGPoint(x: p.x + n.dx * reach, y: p.y + n.dy * reach)))
            }
        }
        return out
    }
}

// MARK: a tapped sketch

/// What a picked sketch offers on the iPad, where there is no Delete key and no right click: edit it, or delete it (Undo brings it back).
struct PadSketchActions: View {
    let model: DocumentModel

    var body: some View {
        let _ = model.overlayRevision
        if let id = model.pickedSketch {
            HStack(spacing: 12) {
                Text(model.featureName(id)).font(.headline).padding(.leading, 8)
                Button("Edit", systemImage: "pencil") { model.editSketch(id) }
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteFeature(id) }
                    .disabled(model.isLocked(id))
                    .tint(.red)
            }
            .touchControls()
            .padding(8)
            .panelGlass(in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(model.featureName(id)) actions")
        }
    }
}

// MARK: a waiting tool

/// A tool that waits for picks and finishes on Return (Shell, Draft, Combine, Thread, Loft...) has no key to press on the iPad: as soon
/// as its prompt asks for Return, a Cancel and a Done button float where the sketch's bar does.
struct PadToolActions: View {
    let model: DocumentModel

    var body: some View {
        let _ = model.overlayRevision
        if let tool = model.pendingTool, model.toolPrompt?.contains("Return") == true {
            HStack(spacing: 12) {
                Text(tool.rawValue).font(.headline).padding(.leading, 8)
                Button("Cancel", systemImage: "xmark") { model.cancelTool() }
                Button("Done", systemImage: "checkmark") { model.confirmTool() }
                    .buttonStyle(.borderedProminent)
            }
            .touchControls()
            .padding(8)
            .panelGlass(in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(tool.rawValue) actions")
        }
    }
}

// MARK: what a sketch tool needs besides the keyboard

/// The keys a sketch is drawn with have no touch twin: Esc to end a chain of lines, or to give up a first click; Return and Esc for the
/// Offset and Pattern options; ⌫ for deleting what is selected. They float where the other bars do, only when they are of use.
struct PadSketchBar: View {
    let model: DocumentModel

    var body: some View {
        let _ = model.overlayRevision
        if let session = model.sketchSession {
            if session.isOffsetting || session.isPatterning {
                SketchPatternHUD(model: model)  // the Mirror tool's own bar is part of the shared panels
            } else if session.isManipulating {
                bar { Button("Done", systemImage: "checkmark") { finish(session) { $0.stopManipulating() } }.buttonStyle(.borderedProminent) }
            } else if session.toolInProgress {
                bar {
                    if session.drawsChains {
                        Button("Done", systemImage: "checkmark") { finish(session) { $0.escape() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Cancel", systemImage: "xmark") { finish(session) { $0.escape() } }
                    }
                }
            } else if !session.selection.isEmpty, !session.isMirroring {
                bar {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.sketchCommand { $0.deleteSelection() }; model.overlayRevision += 1 }
                        .tint(.red)
                }
            }
        }
    }

    private func finish(_ session: SketchSession, _ action: (SketchSession) -> Void) {
        action(session)
        model.overlayRevision += 1
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .touchControls()
            .padding(8)
            .panelGlass(in: Capsule())
            .fixedSize()
    }
}

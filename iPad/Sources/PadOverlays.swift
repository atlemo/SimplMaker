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
            if let session = model.sketchSession {
                PadDimensionLabels(model: model, session: session, state: state)
                if showConstraints || true { PadGlyphs(model: model, session: session, state: state, showConstraints: showConstraints) }
                PadSketchFields(model: model, session: session, state: state, insets: insets)
            }
            PadHandleFields(model: model, state: state, insets: insets)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    var body: some View {
        let inputs = session.inputFields
        if !inputs.isEmpty, let t = session.manipulatorMiddle ?? session.target()?.position {
            let startsAtFirstClick: Set<SketchTool> = [.rectangle, .centerRectangle, .roundedRectangle, .slot, .overallSlot, .circle, .circle2Point, .polygon, .triangle]
            let anchor = session.gearAnchor ?? (session.manipulatorMiddle == nil && startsAtFirstClick.contains(session.tool)
                ? session.clicks.first?.position ?? t : t)
            let world = session.frame.point(anchor.x, anchor.y)
            if let p = state.project(world) {
                HStack(spacing: 8) {
                    ForEach(inputs) { input in SketchField(model: model, session: session, input: input) }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .fixedSize()
                .position(x: min(max(p.x + 20 + 120, insets.left + 130), max(state.size.width - insets.right - 130, insets.left + 130)),
                          y: min(max(p.y + 44, 40), state.size.height - insets.bottom - 40))
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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

private struct PadHandleFields: View {
    let model: DocumentModel
    let state: PadViewState
    let insets: (left: CGFloat, right: CGFloat, bottom: CGFloat)
    @FocusState private var focusedSlot: Int?
    @State private var hudSize = CGSize(width: 300, height: 40)

    var body: some View {
        let handles = model.dragHandles.filter { model.showsField($0) }
        if !handles.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(Array(handles.enumerated()), id: \.element.slot) { index, h in
                    if let p = anchor(h) {
                        HandleField(model: model, handle: h, focused: $focusedSlot)
                            .position(x: min(max(p.x + 26 + 55, insets.left + 60), max(state.size.width - insets.right - 70, insets.left + 60)),
                                      y: min(max(p.y + CGFloat(index) * 40, 24), max(state.size.height - 24, 24)))
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
                                  y: min(p.y + 44 + CGFloat(handles.count) * 40, state.size.height - hudSize.height - insets.bottom) + hudSize.height / 2)
                }
            }
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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

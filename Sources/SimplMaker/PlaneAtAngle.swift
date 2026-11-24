// The Plane at Angle tool: a construction plane turned by an angle from a plane or a flat face, about an axis or an edge. Click the
// base, then the axis (or choose X, Y or Z in the panel) and set the angle; the plane is previewed as it is set up and becomes a Plane
// feature on OK. "Use axis direction only" projects the axis onto the base and pivots about a point of the base (its origin, or a
// point clicked on it). Like Plane Along Path it keeps its state outside the document until OK.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd
import SwiftUI

/// What the tool has so far.
struct AnglePlaneDraft: Equatable {
    var base: PlaneRef?
    var basePick: PickID?
    var axis: PatternAxis?
    var axisPick: PickID?
    var angle = "45 deg"
    var directionOnly = false
    /// The pivot, in the base's own frame (nil = the base's origin), and whether the next click on the base sets it.
    var pivotU: String?
    var pivotV: String?
    var choosingPivot = false
}

extension DocumentModel {
    // MARK: starting and picking

    /// Starts the tool; a flat face or plane, and an edge, already selected are taken as the base and the axis.
    func beginAnglePlane() {
        if sketchSession != nil { finishSketch(keepingView: true) }
        let picks = selection
        pendingTool = .planeAtAngle
        anglePlane = AnglePlaneDraft()
        sketchPlaneSize = OriginPlane.displaySize(for: sceneBounds)
        for pick in picks { anglePlaneClick(pick) }
        showAnglePicks()
        overlayRevision += 1
    }

    /// A click while the tool waits: the base, the axis, or (when asked for) the pivot.
    func anglePlaneClick(_ pick: PickID) {
        guard var draft = anglePlane else { return }
        defer { anglePlane = draft; showAnglePicks(); overlayRevision += 1 }
        if draft.choosingPivot {
            guard pick.kind == .plane || pick.isFace, let base = draft.base, let frame = try? Regenerator.resolvePlane(base, result ?? RegenResult()),
                  let ray = clickRay, let uv = Self.intersect(ray: ray, with: frame) else { return }
            let step = 0.01
            draft.pivotU = formatDimension((uv.x / step).rounded() * step, kind: .length)
            draft.pivotV = formatDimension((uv.y / step).rounded() * step, kind: .length)
            draft.choosingPivot = false
            return
        }
        if pick.isEdge {
            if let (axis, _) = patternAxisAndKind(for: pick) { draft.axis = axis; draft.axisPick = pick }
            return
        }
        // A flat face or a plane is the base; a round face gives the axis it goes round.
        if let ref = planeRef(of: pick) {
            if case .face(let face) = ref, (try? result?.body(face.body)?.faceFrame(face.face)) == nil {
                if let body = result?.body(face.body), (try? body.measure(.face(face.face)))?.geometry == .cylinder {
                    draft.axis = .cylinder(face); draft.axisPick = pick
                }
                return
            }
            draft.base = ref; draft.basePick = pick
            draft.pivotU = nil; draft.pivotV = nil  // it was measured on the old base
        }
    }

    /// The picks the tool has, lit in the view.
    private func showAnglePicks() {
        selection = [anglePlane?.basePick, anglePlane?.axisPick].compactMap { $0 }
    }

    func setAnglePlane(_ edit: (inout AnglePlaneDraft) -> Void) {
        guard var draft = anglePlane else { return }
        edit(&draft)
        anglePlane = draft
        showAnglePicks()
        overlayRevision += 1
    }

    /// An origin axis from the panel's menu (nil: back to picking an edge).
    func chooseAngleAxis(_ axis: PatternAxis?) {
        setAnglePlane { $0.axis = axis; $0.axisPick = nil }
    }

    // MARK: the plane

    private func anglePlaneFeature(_ draft: AnglePlaneDraft) -> PlaneFeature? {
        guard let base = draft.base, let axis = draft.axis else { return nil }
        return PlaneFeature(base: base, turnedBy: draft.angle,
                            about: PlaneTurn(axis: axis, directionOnly: draft.directionOnly,
                                             pivotU: draft.directionOnly ? draft.pivotU : nil, pivotV: draft.directionOnly ? draft.pivotV : nil))
    }

    /// Where the plane would stand, or why it can't (shown in the panel).
    var anglePlaneOutcome: (frame: Frame?, problem: String?) {
        guard pendingTool == .planeAtAngle, let draft = anglePlane, let feature = anglePlaneFeature(draft), let result else { return (nil, nil) }
        do { return (try Regenerator.plane(feature, result), nil) }
        catch let e as KernelError { return (nil, e.message) }
        catch { return (nil, "\(error)") }
    }

    /// The point the plane turns about when only the axis's direction counts: a point on the base.
    private var anglePivotPoint: SIMD3<Double>? {
        guard let draft = anglePlane, draft.directionOnly, let base = draft.base, let result,
              let frame = try? Regenerator.resolvePlane(base, result) else { return nil }
        let u = (try? parameterValues.value(of: draft.pivotU ?? "0 mm", kind: .length)) ?? 0
        let v = (try? parameterValues.value(of: draft.pivotV ?? "0 mm", kind: .length)) ?? 0
        return frame.point(u, v)
    }

    /// Makes the plane. False (the tool keeps waiting) while something is missing or can't be built.
    @discardableResult
    func commitAnglePlane() -> Bool {
        guard let draft = anglePlane, let feature = anglePlaneFeature(draft), anglePlaneOutcome.frame != nil else { return false }
        pendingTool = nil
        add(Feature(name: document.nextName("Plane"), .plane(feature)))
        selectedFeature = nil  // the panel was the editor
        return true
    }

    // MARK: the viewport

    func addAnglePlaneOverlay(to o: inout SketchOverlay) {
        guard pendingTool == .planeAtAngle else { return }
        if let frame = anglePlaneOutcome.frame {
            SketchOverlayBuilder.constructionPlane(frame, extent: PlaneExtent(side: OriginPlane.displaySize(for: sceneBounds)),
                                                   id: 0, edgeIDs: nil, into: &o)
        }
        if let p = anglePivotPoint {  // a dot where it pivots
            let f = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            o.moveHandle = [SegmentInstance(ax: f.x, ay: f.y, az: f.z, bx: f.x, by: f.y, bz: f.z, id: 0)]
        }
    }

    /// What the waiting tool asks for next.
    var anglePlanePrompt: String {
        guard let draft = anglePlane else { return "" }
        if draft.choosingPivot { return "Click the point on the base plane to pivot about" }
        if draft.base == nil { return "Click a plane or a flat face to turn" }
        if draft.axis == nil { return "Click an edge or a round face as the axis to turn about · or choose X, Y or Z in the panel" }
        return "Set the angle · Return to make the plane"
    }
}

// MARK: - the panel

/// The Plane at Angle tool's options, floating at the top right of the view while it runs.
struct AnglePlanePanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 290

    private func axisName(_ axis: PatternAxis?) -> String {
        switch axis {
        case nil: return "Click an edge"
        case .x?: return "X axis"
        case .y?: return "Y axis"
        case .z?: return "Z axis"
        case .edge(let e)?: return "Edge \(e.edge)"
        case .cylinder?: return "Round face"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack(spacing: DS.Spacing.space4) {
                Icon("plane-at-angle", size: 16)
                Text("Plane at Angle").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Cancel (Esc)") { model.cancelTool() }
            }
            if let draft = model.anglePlane {
                LabeledContent("Base") {
                    chip(draft.base.map { model.planeName($0) } ?? "Click a plane or face", filled: draft.base != nil) {
                        model.setAnglePlane { $0.base = nil; $0.basePick = nil; $0.pivotU = nil; $0.pivotV = nil }
                    }
                }
                .font(.callout)
                LabeledContent("Axis") {
                    HStack(spacing: DS.Spacing.space3) {
                        Menu {
                            Button("X axis") { model.chooseAngleAxis(.x) }
                            Button("Y axis") { model.chooseAngleAxis(.y) }
                            Button("Z axis") { model.chooseAngleAxis(.z) }
                            Divider()
                            Text("Or click an edge in the view")
                        } label: {
                            Text(axisName(draft.axis)).foregroundStyle(draft.axis == nil ? .secondary : .primary).lineLimit(1)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .help("The line the plane turns about: an edge or a round face clicked in the view, or an origin axis")
                        Spacer(minLength: 0)
                        if draft.axis != nil {
                            Button { model.chooseAngleAxis(nil) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .help("Pick another axis")
                        }
                    }
                    .padding(.horizontal, DS.Spacing.space4)
                    .frame(width: 150, height: DS.ControlHeight.regular, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.control))
                }
                .font(.callout)
                LabeledContent("Angle") {
                    ExpressionField(text: draft.angle, preview: { v in model.setAnglePlane { $0.angle = v } },
                                    commit: { v in model.setAnglePlane { $0.angle = v } })
                        .frame(width: 110)
                        .help("How far the plane turns: a number of degrees or a parameter (↑ ↓ nudge it); a negative angle turns the other way")
                }
                .font(.callout)
                Toggle(isOn: Binding(get: { draft.directionOnly }, set: { on in model.setAnglePlane { $0.directionOnly = on; $0.choosingPivot = false } })) {
                    Text("Use axis direction only")
                }
                .toggleStyle(.switch)
                .font(.callout)
                .help("Project the axis onto the base and turn about a point on the base, instead of about the axis itself")
                if draft.directionOnly {
                    LabeledContent("Pivot") {
                        HStack(spacing: DS.Spacing.space3) {
                            Button(draft.choosingPivot ? "Click the base…" : draft.pivotU == nil ? "Base origin · pick" : "Picked · change") {
                                model.setAnglePlane { $0.choosingPivot = true }
                            }
                            .controlSize(.small)
                            .disabled(draft.base == nil)
                            .help("Then click the point on the base plane to pivot about")
                            if draft.pivotU != nil {
                                Button { model.setAnglePlane { $0.pivotU = nil; $0.pivotV = nil; $0.choosingPivot = false } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .help("Back to the base's origin")
                            }
                        }
                    }
                    .font(.callout)
                }
                if let problem = model.anglePlaneOutcome.problem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.anglePlanePrompt).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelTool() }
                        .keyboardShortcut(.cancelAction)
                    Button("OK") { model.commitAnglePlane() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.anglePlaneOutcome.frame == nil)
                }
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelMaterial(in: .rect(cornerRadius: DS.Radius.window))
    }

    private func chip(_ text: String, filled: Bool, clear: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Spacing.space3) {
            Text(text).foregroundStyle(filled ? .primary : .secondary).lineLimit(1)
            Spacer(minLength: 0)
            if filled {
                Button(action: clear) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Pick another")
            }
        }
        .padding(.horizontal, DS.Spacing.space4)
        .frame(width: 150, height: DS.ControlHeight.regular, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}

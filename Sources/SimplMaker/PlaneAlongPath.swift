// The Plane Along Path tool: click a sketch curve, then slide a dot along it (or type a position) to put a construction plane
// square to the path. Like Section Analysis it keeps its state outside the document: the plane is only drawn as a preview
// until OK, when it becomes a Plane feature. The engine (where the plane stands) is Regenerator.pathFrame.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd
import SwiftUI

/// What the tool has so far. `path` is nil until a curve is picked.
struct PathPlaneDraft: Equatable {
    var path: CurveRef?
    var position = "0.5"
    var offset = "0 mm"
    var angle = "0 deg"
}

extension DocumentModel {
    // MARK: starting and choosing

    /// Starts the tool (or, with a curve already selected, starts on its path).
    func beginPathPlane() {
        if sketchSession != nil { finishSketch(keepingView: true) }
        pendingTool = .planeAlongPath
        pathPlane = PathPlaneDraft()
        pathPlaneTrack = []
        if let curve = selection.lazy.compactMap({ self.curve(of: $0) }).first { choosePlanePath(curve) }
        selection = []
        overlayRevision += 1
    }

    /// The picked curve, and the curves joined end to end with it, become the path.
    func choosePlanePath(_ curve: (sketch: FeatureID, curve: EntityID)) {
        guard var draft = pathPlane, let path = pathRef([curve]), let sketch = result?.sketches[path.sketch] else { return }
        do { _ = try SketchPathLocator(curves: path.curves, in: sketch.solved) }
        catch {
            alert = AlertInfo(title: "That curve can't be a path", message: "\(error)")
            return
        }
        draft.path = path
        pathPlane = draft
        rebuildPathPlaneTrack()
        overlayRevision += 1
    }

    /// Forgets the path, to pick another (the cross in the panel's Path field).
    func clearPlanePath() {
        pathPlane?.path = nil
        pathPlaneTrack = []
        overlayRevision += 1
    }

    /// The path as a line of points in the world, evenly spaced along its length, for finding the spot nearest the pointer.
    private func rebuildPathPlaneTrack() {
        pathPlaneTrack = []
        guard let path = pathPlane?.path, let sketch = result?.sketches[path.sketch],
              let locator = try? SketchPathLocator(curves: path.curves, in: sketch.solved) else { return }
        let steps = 400
        pathPlaneTrack = (0...steps).map { i in
            let at = locator.location(at: Double(i) / Double(steps)).point
            return sketch.frame.point(at.x, at.y)
        }
    }

    // MARK: the plane

    /// The plane as the draft describes it now, to preview and to make.
    private func pathPlaneFeature(_ draft: PathPlaneDraft) -> PlaneFeature? {
        draft.path.map { PlaneFeature(along: $0, position: draft.position, offset: draft.offset, angle: draft.angle) }
    }

    /// Where the plane would stand; nil while there is no path or a value can't be read.
    var pathPlaneFrame: Frame? {
        guard pendingTool == .planeAlongPath, let draft = pathPlane, let feature = pathPlaneFeature(draft), let result else { return nil }
        return try? Regenerator.plane(feature, result)
    }

    /// The spot on the path, where the dot is (before any offset or tilt).
    var pathPlaneDot: SIMD3<Double>? {
        guard pendingTool == .planeAlongPath, let draft = pathPlane, let along = pathPlaneFeature(draft)?.along, let result else { return nil }
        return (try? Regenerator.pathFrame(along, result))?.origin
    }

    /// Makes the plane. False (the tool keeps waiting) when there is no path yet or a value is not a number.
    @discardableResult
    func commitPathPlane() -> Bool {
        guard let draft = pathPlane, let feature = pathPlaneFeature(draft), let result else { return false }
        guard (try? Regenerator.plane(feature, result)) != nil else {
            alert = AlertInfo(title: "The plane can't be made", message: "Check the position, offset and angle: each has to be a number or a parameter.")
            return false
        }
        pendingTool = nil
        add(Feature(name: document.nextName("Plane"), .plane(feature)))
        selectedFeature = nil  // the panel was the editor: no second OK for the offset arrow that a new feature opens with
        return true
    }

    func setPathPlane(position: String? = nil, offset: String? = nil, angle: String? = nil) {
        guard pathPlane != nil else { return }
        if let position { pathPlane?.position = position }
        if let offset { pathPlane?.offset = offset }
        if let angle { pathPlane?.angle = angle }
        overlayRevision += 1
    }

    // MARK: the viewport

    func addPathPlaneOverlay(to o: inout SketchOverlay) {
        guard let frame = pathPlaneFrame else { return }
        SketchOverlayBuilder.constructionPlane(frame, extent: PlaneExtent(side: OriginPlane.displaySize(for: sceneBounds)),
                                               id: 0, edgeIDs: nil, into: &o)
        if let dot = pathPlaneDot {
            let f = SIMD3<Float>(Float(dot.x), Float(dot.y), Float(dot.z))
            o.moveHandle = [SegmentInstance(ax: f.x, ay: f.y, az: f.z, bx: f.x, by: f.y, bz: f.z, id: PickID.pathHandle.raw)]
        }
    }

    /// The position, written beside the dot.
    func pathPlaneLabels() -> [DimensionLabel] {
        guard let dot = pathPlaneDot, let draft = pathPlane else { return [] }
        var label = DimensionLabel(id: "pathplane:position", world: SIMD3(Float(dot.x), Float(dot.y), Float(dot.z)),
                                   text: draft.position, editing: false)
        label.reference = true
        label.passesClicks = true
        // Standing to the side of the path (as Section Analysis's offset stands past its arrow), so the dot stays in view and grabbable.
        if let frame = try? Regenerator.pathFrame(PlanePath(path: draft.path ?? CurveRef(sketch: "", curves: []), position: draft.position), result!) {
            label.outward = SIMD3(Float(frame.xAxis.x), Float(frame.xAxis.y), Float(frame.xAxis.z))
        }
        return [label]
    }

    // MARK: dragging the dot

    func beginPathPlaneDrag() { pathPlaneDragging = true }
    func endPathPlaneDrag() { pathPlaneDragging = false }

    /// Slides the dot to the place on the path nearest the pointer's ray, in hundredths of the path (⌥: wherever it lands).
    func dragPathPlane(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, snapping: Bool = true) {
        guard pathPlaneDragging, pathPlaneTrack.count > 1 else { return }
        var best: (distance: Double, fraction: Double)?
        let count = pathPlaneTrack.count - 1
        for i in 0..<count {
            let (distance, t) = Self.nearest(ray: (o, d), segment: (pathPlaneTrack[i], pathPlaneTrack[i + 1]))
            if best == nil || distance < best!.distance { best = (distance, (Double(i) + t) / Double(count)) }
        }
        guard let fraction = best?.fraction else { return }
        setPathPlane(position: Self.fractionText(snapping ? (fraction * 100).rounded() / 100 : fraction))
    }

    /// "0.35", "1", "0": a fraction as it is typed (at most three decimals).
    static func fractionText(_ f: Double) -> String {
        let v = (min(max(f, 0), 1) * 1000).rounded() / 1000
        if v == v.rounded() { return String(Int(v)) }
        var text = String(format: "%.3f", v)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    /// How far the ray passes from the segment, and where along the segment (0 to 1) it comes closest.
    static func nearest(ray: (origin: SIMD3<Double>, direction: SIMD3<Double>),
                        segment: (a: SIMD3<Double>, b: SIMD3<Double>)) -> (distance: Double, t: Double) {
        let u = segment.b - segment.a, w = segment.a - ray.origin, d = ray.direction
        let uu = simd_dot(u, u), ud = simd_dot(u, d), dd = simd_dot(d, d)
        let denominator = uu * dd - ud * ud
        var t = denominator > 1e-12 ? (ud * simd_dot(d, w) - dd * simd_dot(u, w)) / denominator : 0
        t = min(max(t, 0), 1)
        let point = segment.a + u * t
        let s = max(simd_dot(point - ray.origin, d) / dd, 0)  // the ray starts at its origin
        return (simd_length(point - (ray.origin + d * s)), t)
    }
}

// MARK: - the panel

/// The Plane Along Path tool's options, floating at the top left of the view while it runs.
struct PathPlanePanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack(spacing: DS.Spacing.space4) {
                Icon("plane-along-path", size: 16)
                Text("Plane Along Path").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Cancel (Esc)") { model.cancelTool() }
            }
            if let draft = model.pathPlane {
                LabeledContent("Path") {
                    HStack(spacing: DS.Spacing.space3) {
                        Text(draft.path.map { model.featureName($0.sketch) } ?? "Click a curve")
                            .foregroundStyle(draft.path == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if draft.path != nil {
                            Button { model.clearPlanePath() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .help("Pick another path")
                        }
                    }
                    .padding(.horizontal, DS.Spacing.space4)
                    .frame(width: 140, height: DS.ControlHeight.regular, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.control))
                }
                .font(.callout)
                Group {
                    field("Position (0 to 1)", draft.position, "Where along the path: 0 is the start, 1 the end. Drag the dot in the view, or type a number or a parameter") {
                        model.setPathPlane(position: $0)
                    }
                    field("Offset", draft.offset, "Slide the plane along the path's direction from that spot") { model.setPathPlane(offset: $0) }
                    field("Angle", draft.angle, "Tip the plane about its own sideways axis") { model.setPathPlane(angle: $0) }
                }
                .disabled(draft.path == nil)
                Text(draft.path == nil ? "Click a sketch curve in the view for the plane to follow."
                                       : "Drag the dot along the path to place the plane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelTool() }
                        .keyboardShortcut(.cancelAction)
                    Button("OK") { model.commitPathPlane() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.path == nil)
                }
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelMaterial(in: .rect(cornerRadius: DS.Radius.window))
    }

    private func field(_ label: String, _ text: String, _ help: String, set: @escaping (String) -> Void) -> some View {
        LabeledContent(label) {
            ExpressionField(text: text, preview: set, commit: set)
                .frame(width: 110)
                .help(help)
        }
        .font(.callout)
    }
}

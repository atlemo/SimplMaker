// The Section Analysis tool (Inspect group): cut the bodies by a plane, to look inside them. The plane is an
// origin or construction plane, a flat face, a sketch or a canvas; an arrow in the view (or a typed distance)
// slides it in and out, and the whole view turns on and off. It reads the model without changing it: no
// feature, no undo step, nothing saved. The renderer does the cutting (see sectionFace in Shaders.swift).
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd
import SwiftUI

/// What the cutting plane comes from. It is looked up again after every rebuild, so the cut follows a sketch or
/// a face that moves.
enum SectionSource: Equatable {
    case origin(OriginPlane)
    case plane(FeatureID)
    case face(FaceRef)
    case sketch(FeatureID)
    case canvas(FeatureID)
}

struct SectionCut: Equatable {
    var source: SectionSource
    /// What it is cut at, for the panel: "XY plane", "Sketch1", "Face of Body1".
    var title: String
    /// The plane as last found, kept for a moment when its source can't be found (a rebuild under way).
    var frame: Frame
    /// How far the cut lies from the plane, in mm, along the side that is cut away (negative: into the other side).
    var offset = 0.0
    /// The cut-away side is the plane's normal side, or the opposite one.
    var flipped = false
}

extension DocumentModel {
    // MARK: where the cut is

    /// The plane a source stands for now: the last rebuild's own, or nil when it is gone.
    func sectionFrame(of source: SectionSource) -> Frame? {
        switch source {
        case .origin(let plane): return plane.frame
        case .plane(let id): return result?.planes[id]
        case .face(let ref): return try? result?.body(ref.body)?.faceFrame(ref.face)
        case .sketch(let id): return result?.sketches[id]?.frame
        case .canvas(let id): return result?.images[id]?.frame
        }
    }

    /// The plane the cut is made from, before its offset.
    func sectionBase(_ cut: SectionCut) -> Frame { sectionFrame(of: cut.source) ?? cut.frame }

    /// The unit direction the cut-away side lies in.
    func sectionNormal(_ cut: SectionCut) -> SIMD3<Double> {
        let n = simd_normalize(sectionBase(cut).normal)
        return cut.flipped ? -n : n
    }

    /// A point on the cutting plane.
    func sectionPoint(_ cut: SectionCut) -> SIMD3<Double> { sectionBase(cut).origin + sectionNormal(cut) * cut.offset }

    /// What the renderer cuts by: the plane's unit normal and its distance from the origin along it. Nil while the
    /// section is off, or there is none.
    var sectionClip: SIMD4<Float>? {
        guard sectionOn, let cut = section else { return nil }
        let n = sectionNormal(cut), d = simd_dot(n, sectionPoint(cut))
        return SIMD4(Float(n.x), Float(n.y), Float(n.z), Float(d))
    }

    /// Whether the viewport is showing the cut.
    var sectionActive: Bool { section != nil && sectionOn }

    // MARK: starting

    /// What a pick stands for as a cutting plane, with the name to show; nil for what has no plane (a curved face).
    func sectionSource(for pick: PickID) -> (source: SectionSource, title: String)? {
        switch pick.kind {
        case .plane:
            if let plane = OriginPlane(pick: pick) { return (.origin(plane), "\(plane.label) plane") }
            if let id = constructionPlane(of: pick) { return (.plane(id), featureTitle(id)) }
        case .face:
            guard let ref = faceRef(pick), (try? result?.body(ref.body)?.faceFrame(ref.face)) != nil else { return nil }
            let body = meshes.first { $0.id == ref.body }?.name
            return (.face(ref), body.map { "Face of \($0)" } ?? "Face")
        case .region:
            if let sketch = profile(of: pick)?.sketch, result?.sketches[sketch] != nil { return (.sketch(sketch), featureTitle(sketch)) }
        case .sketchCurve:
            if let sketch = curve(of: pick)?.sketch, result?.sketches[sketch] != nil { return (.sketch(sketch), featureTitle(sketch)) }
        default: break
        }
        return nil
    }

    /// What a sketch, a construction plane or a canvas of the timeline stands for as a cutting plane.
    func sectionSource(forFeature id: FeatureID) -> (source: SectionSource, title: String)? {
        guard let feature = document.features.first(where: { $0.id == id }) else { return nil }
        switch feature.kind {
        case .sketch where result?.sketches[id] != nil: return (.sketch(id), feature.name)
        case .plane where result?.planes[id] != nil: return (.plane(id), feature.name)
        case .image where result?.images[id] != nil: return (.canvas(id), feature.name)
        default: return nil
        }
    }

    private func featureTitle(_ id: FeatureID) -> String { document.features.first { $0.id == id }?.name ?? "Plane" }

    /// Cuts at the clicked plane, face or sketch. False when it has no plane to cut at (the alert says why).
    @discardableResult
    func beginSection(from pick: PickID) -> Bool {
        guard let found = sectionSource(for: pick) else {
            if pick.isFace {
                alert = AlertInfo(title: "That face isn't flat", message: "Pick a flat face, a plane, a sketch or a canvas to cut at.")
            }
            return false
        }
        return beginSection(found.source, title: found.title)
    }

    /// Cuts at a sketch, plane or canvas picked in the browser or the timeline.
    @discardableResult
    func beginSection(feature id: FeatureID) -> Bool {
        guard let found = sectionSource(forFeature: id) else { return false }
        return beginSection(found.source, title: found.title)
    }

    @discardableResult
    func beginSection(_ source: SectionSource, title: String) -> Bool {
        guard let frame = sectionFrame(of: source) else { return false }
        var cut = SectionCut(source: source, title: title, frame: frame)
        let normal = simd_normalize(frame.normal)
        // The cut-away side faces the viewer who picked, so what they then see is the cut and not the back of the model.
        if let ray = clickRay, simd_dot(ray.direction, normal) > 0 { cut.flipped = true }
        // A plane that doesn't pass through the model (a face, the floor under a part) would show nothing, or
        // nothing at all of the model: it goes halfway through instead.
        let n = cut.flipped ? -normal : normal
        if let range = sectionRange(along: n, from: frame.origin), !(range.lowerBound + 1e-6 < 0 && 0 < range.upperBound - 1e-6) {
            cut.offset = (range.lowerBound + range.upperBound) / 2
        }
        section = cut
        sectionOn = true
        sectionDrag = nil
        pendingTool = nil
        overlayRevision += 1
        return true
    }

    /// How far the model reaches along `direction`, measured from `origin`; nil for an empty scene.
    func sectionRange(along direction: SIMD3<Double>, from origin: SIMD3<Double>) -> ClosedRange<Double>? {
        guard let b = sceneBounds else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] { for z in [b.min.z, b.max.z] {
            let t = simd_dot(SIMD3(Double(x), Double(y), Double(z)) - origin, direction)
            lo = min(lo, t); hi = max(hi, t)
        } } }
        return lo...hi
    }

    // MARK: changing

    /// Turns the cut on or off, keeping the plane. With no plane yet, turning it on asks for one.
    func setSectionAnalysis(_ on: Bool) {
        if on, section == nil {
            run(.sectionAnalysis)
            return
        }
        sectionOn = on
        overlayRevision += 1
    }

    /// Ends the analysis: the plane is forgotten.
    func endSection() {
        section = nil
        sectionOn = true
        sectionDrag = nil
        if pendingTool == .sectionAnalysis { pendingTool = nil }
        overlayRevision += 1
    }

    /// Cuts away the other side of the plane; the plane stays where it is.
    func flipSection() {
        guard var cut = section else { return }
        cut.flipped.toggle()
        cut.offset = -cut.offset
        section = cut
        sectionOn = true
        overlayRevision += 1
    }

    func setSectionOffset(_ offset: Double) {
        guard var cut = section, offset.isFinite else { return }
        cut.offset = offset
        section = cut
        overlayRevision += 1
    }

    /// The offset as the field shows it, in the user's units.
    var sectionOffsetText: String {
        guard let cut = section else { return "" }
        return MeasureUnits(us: Preferences.unitSystemSetting.isUS).length(cut.offset)
    }

    /// Takes a typed offset ("12", "0.5 in", an expression with parameters). False if it isn't a length.
    @discardableResult
    func setSectionOffset(text: String) -> Bool {
        guard let value = try? parameterValues.value(of: text, kind: .length) else { return false }
        setSectionOffset(value)
        return true
    }

    // MARK: the arrow

    /// The arrow that slides the plane: where it starts (the middle of the model, on the plane), the way it points
    /// (toward the cut-away side) and how long it is drawn.
    func sectionArrow() -> (base: SIMD3<Double>, direction: SIMD3<Double>, length: Double)? {
        guard sectionOn, let cut = section, let b = sceneBounds else { return nil }
        let n = sectionNormal(cut), point = sectionPoint(cut)
        let middle = SIMD3(Double(b.min.x + b.max.x) / 2, Double(b.min.y + b.max.y) / 2, Double(b.min.z + b.max.z) / 2)
        let base = middle - n * simd_dot(middle - point, n)
        let size = Double(simd_reduce_max(b.max - b.min))
        return (base, n, max(size * 0.15, 4))
    }

    /// The arrow is shown when nothing else has handles in the view.
    var showsSectionArrow: Bool {
        sectionActive && sketchSession == nil && dragHandles.isEmpty && (pendingTool == nil || pendingTool == .sectionAnalysis)
    }

    /// The arrow and the plane's border, for the viewport.
    func addSectionOverlay(to o: inout SketchOverlay) {
        guard let cut = section, sectionOn, let b = sceneBounds else { return }
        func f(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        let base = sectionBase(cut), n = sectionNormal(cut), point = sectionPoint(cut)
        // The border: a rectangle in the plane a little larger than the model.
        let frame = Frame(origin: point, normal: n, xAxis: base.xAxis).upright
        var lo = SIMD2<Double>(repeating: .infinity), hi = -lo
        for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] { for z in [b.min.z, b.max.z] {
            let d = SIMD3(Double(x), Double(y), Double(z)) - point
            let uv = SIMD2(simd_dot(d, frame.xAxis), simd_dot(d, frame.yAxis))
            lo = simd_min(lo, uv); hi = simd_max(hi, uv)
        } } }
        let margin = max(hi.x - lo.x, hi.y - lo.y) * 0.06 + 1
        lo -= margin; hi += margin
        let corners = [SIMD2(lo.x, lo.y), SIMD2(hi.x, lo.y), SIMD2(hi.x, hi.y), SIMD2(lo.x, hi.y)].map { f(frame.point($0.x, $0.y)) }
        for i in 0..<4 {
            let a = corners[i], c = corners[(i + 1) % 4]
            o.section.append(SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: c.x, by: c.y, bz: c.z, id: 0))
        }
        if showsSectionArrow, let arrow = sectionArrow() {
            let a = f(arrow.base), c = f(arrow.base + arrow.direction * arrow.length)
            let segment = SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: c.x, by: c.y, bz: c.z, id: PickID.sectionHandle.raw)
            o.handle += [segment, segment]
        }
    }

    /// The offset, written beside the arrow.
    func sectionLabels() -> [DimensionLabel] {
        guard showsSectionArrow, let arrow = sectionArrow() else { return [] }
        let tip = arrow.base + arrow.direction * arrow.length
        // Standing past the arrow's tip, and letting clicks through, so the arrow can always be grabbed.
        let outward = SIMD3(Float(arrow.direction.x), Float(arrow.direction.y), Float(arrow.direction.z))
        var label = DimensionLabel(id: "section:offset", world: SIMD3(Float(tip.x), Float(tip.y), Float(tip.z)),
                                   text: sectionOffsetText, editing: false)
        label.reference = true
        label.outward = outward
        label.passesClicks = true
        return [label]
    }

    // MARK: dragging the arrow

    func beginSectionDrag(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>) {
        guard let cut = section, let arrow = sectionArrow(), let s = Self.alongArrow(arrow.base, arrow.direction, o, d) else { return }
        sectionDrag = (cut.offset, arrow.base, arrow.direction, s)
    }

    /// The offset moves in whole millimetres while dragging (type a distance in the panel for anything finer).
    static let sectionStep = 1.0

    /// Slides the plane to where the pointer's ray comes closest to the arrow's line, in 1 mm steps (`snapping`
    /// off: wherever the pointer is).
    func dragSection(rayOrigin o: SIMD3<Double>, direction d: SIMD3<Double>, snapping: Bool = true) {
        guard let drag = sectionDrag, let s = Self.alongArrow(drag.base, drag.direction, o, d) else { return }
        var offset = drag.offset + (s - drag.grab)
        if snapping { offset = (offset / Self.sectionStep).rounded() * Self.sectionStep }
        setSectionOffset(offset == 0 ? 0 : offset)
    }

    func endSectionDrag() { sectionDrag = nil }

    /// Where along the line (from `base`, along `direction`) the ray comes closest to it, in mm.
    private static func alongArrow(_ base: SIMD3<Double>, _ direction: SIMD3<Double>,
                                   _ o: SIMD3<Double>, _ d: SIMD3<Double>) -> Double? {
        let w = base - o, b = simd_dot(direction, d)
        guard 1 - b * b > 1e-6 else { return nil }  // looking straight down the arrow
        return (b * simd_dot(d, w) - simd_dot(direction, w)) / (1 - b * b)
    }

    // MARK: the tool

    /// Waits for another plane to cut at, whatever is selected.
    func chooseSectionPlane() {
        if sketchSession != nil { finishSketch(keepingView: true) }
        cancelSketchPlanePick()
        selection = []
        pendingTool = .sectionAnalysis
        sketchPlaneSize = OriginPlane.displaySize(for: sceneBounds)
        overlayRevision += 1
    }

    /// What the waiting tool asks for.
    var sectionPrompt: String {
        "Click a plane, a flat face, a sketch or a canvas to cut at · a sketch or canvas in the browser works too"
    }

    /// The plane the tool starts from when it runs with something already selected: a sketch, plane or canvas in
    /// the browser, or a plane, face or sketch picked in the view.
    func startSectionFromSelection() -> Bool {
        for pick in selection.reversed() where sectionSource(for: pick) != nil { return beginSection(from: pick) }
        if let id = selectedFeature { return beginSection(feature: id) }
        return false
    }
}

// MARK: - the panel

/// The Section Analysis tool's options, floating at the top left of the view while a cut is made.
struct SectionPanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270
    @State private var offsetText = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Section Analysis").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "End the section analysis") { model.endSection() }
            }
            if let cut = model.section {
                Toggle(isOn: Binding(get: { model.sectionOn }, set: { model.setSectionAnalysis($0) })) {
                    Text("Show the cut")
                }
                .toggleStyle(.switch)
                .help("Turn the cut on or off; the plane stays")
                LabeledContent("Cut at", value: cut.title)
                    .font(.callout)
                    .help("The plane the bodies are cut by")
                LabeledContent("Offset") {
                    TextField("Offset", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 110)
                        .focused($editing)
                        .onSubmit { commit() }
                        .help("How far the cut is from the plane: type a distance, or drag the arrow in the view")
                }
                .font(.callout)
                HStack {
                    Button("Flip Side") { model.flipSection() }
                        .help("Cut away the other side of the plane")
                    Button("Other Plane…") { model.chooseSectionPlane() }
                        .help("Click another plane, face, sketch or canvas to cut at")
                }
                .controlSize(.small)
                Text("Drag the arrow in the view to slide the cut in or out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.window))
        .onAppear { offsetText = model.sectionOffsetText }
        .onChange(of: model.sectionOffsetText) { _, text in if !editing { offsetText = text } }
        .onChange(of: editing) { _, now in if !now { offsetText = model.sectionOffsetText } }
    }

    private func commit() {
        if !model.setSectionOffset(text: offsetText) { NSSound.beep() }
        offsetText = model.sectionOffsetText
    }
}

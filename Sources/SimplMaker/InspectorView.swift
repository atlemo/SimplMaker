// Edits the selected feature: every value is an expression, and any change regenerates the model.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import SwiftUI

struct InspectorView: View {
    let model: DocumentModel

    var body: some View {
        if let id = model.selectedFeature, let feature = model.document.features.first(where: { $0.id == id }) {
            Form {
                Section {
                    LabeledContent("Name") {
                        ExpressionField(text: feature.name, monospaced: false, completes: false) { model.renameFeature(id, to: $0) }
                    }
                    if feature.createsBody, let body = model.bodies.first(where: { $0.id == id }) {
                        LabeledContent("Body name") {
                            ExpressionField(text: body.name, monospaced: false, completes: false) { model.renameBody(id, to: $0) }
                        }
                    }
                    LabeledContent("Type", value: feature.typeName)
                    if feature.createsBody, let made = model.bodies.first(where: { $0.id == id }) {
                        BodySizeRows(shape: made.body)
                    }
                    if let error = model.result?.errors[feature.id] {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Toggle("Suppressed", isOn: Binding(
                        get: { feature.suppressed },
                        set: { v in model.updateFeature(id, v ? "Suppress" : "Unsuppress") { $0.suppressed = v } }))
                }
                switch feature.kind {
                case .sketch(let s): SketchInspector(model: model, id: id, sketch: s)
                case .extrude(let e): ExtrudeInspector(model: model, id: id, extrude: e)
                case .fillet(let f): EdgeInspector(model: model, id: id, edges: f, fillet: true)
                case .chamfer(let f): EdgeInspector(model: model, id: id, edges: f, fillet: false)
                case .revolve(let f): RevolveInspector(model: model, id: id, revolve: f)
                case .sweep(let f): SweepInspector(model: model, id: id, sweep: f)
                case .loft(let f): LoftInspector(model: model, id: id, loft: f)
                case .twistSweep(let f): TwistSweepInspector(model: model, id: id, twist: f)
                case .rib(let f): RibInspector(model: model, id: id, rib: f)
                case .hole(let f): HoleInspector(model: model, id: id, hole: f)
                case .thread(let f): ThreadInspector(model: model, id: id, thread: f)
                case .primitive(let f): PrimitiveInspector(model: model, id: id, primitive: f)
                case .pipe(let f): PipeInspector(model: model, id: id, pipe: f)
                case .move(let f): MoveInspector(model: model, id: id, move: f)
                case .rotate(let f): RotateInspector(model: model, id: id, rotate: f)
                case .scale(let f): ScaleInspector(model: model, id: id, scale: f)
                case .combine(let f): CombineInspector(model: model, id: id, combine: f)
                case .plane(let f): PlaneInspector(model: model, id: id, plane: f)
                case .mirror(let f): MirrorInspector(model: model, id: id, mirror: f)
                case .pattern(let f): PatternInspector(model: model, id: id, pattern: f)
                case .shell(let f): ShellInspector(model: model, id: id, shell: f)
                case .draft(let f): DraftInspector(model: model, id: id, draft: f)
                case .split(let f): SplitInspector(model: model, id: id, split: f)
                case .layOnFloor(let f): LayOnFloorInspector(model: model, face: f.face)
                case .project(let f): ProjectInspector(model: model, id: id, project: f)
                case .importBody(let f): ImportInspector(model: model, id: id, imported: f)
                case .image(let f): ImageInspector(model: model, id: id, image: f)
                }
                Section {
                    Button("Delete Feature", role: .destructive) { model.deleteFeature(id) }
                }
            }
            .formStyle(.grouped)
        } else if let body = model.selectedBody, let b = model.bodies.first(where: { $0.id == body }) {
            // A body picked in the browser: its name, size and the feature that made it.
            Form {
                Section("Body") {
                    LabeledContent("Name") {
                        ExpressionField(text: b.name, monospaced: false, completes: false) { model.renameBody(body, to: $0) }
                    }
                    BodySizeRows(shape: b.body, volume: true)
                    LabeledContent("Made by") {
                        HStack {
                            Text(model.featureName(body))
                            Button("Edit") { model.editFeature(body) }
                        }
                    }
                    Button("Split into Parts") { model.splitIntoParts(bodies: [body]) }
                    Button(model.isHidden(body) ? "Show Body" : "Hide Body") { model.setHidden([body], !model.isHidden(body)) }
                }
            }
            .formStyle(.grouped)
        } else if model.selectedBodies.count > 1 {
            // Several bodies picked in the browser: what can be done to all of them at once.
            let ids = model.selectedBodies
            let names = model.bodies.filter { ids.contains($0.id) }.map(\.name)
            Form {
                Section("\(ids.count) Bodies") {
                    Text(ListFormatter.localizedString(byJoining: names)).foregroundStyle(.secondary)
                    Button("Move or Rotate") { model.move(bodies: ids) }
                    Button("Scale") { model.scale(bodies: ids) }
                    Button("Appearance…") { model.openAppearance(for: ids) }
                    Button("Split into Parts") { model.splitIntoParts(bodies: ids) }
                    Button(ids.allSatisfy(model.isHidden) ? "Show Bodies" : "Hide Bodies") {
                        model.setHidden(ids, !ids.allSatisfy(model.isHidden))
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Feature Selected", systemImage: "cursorarrow.click",
                                   description: Text("Select a feature in the timeline to edit it, or pick a tool in the toolbar to create one."))
        }
    }
}

/// How big a body is: its size along each world axis (its bounding box), and optionally its volume, in the
/// unit system chosen in Settings.
struct BodySizeRows: View {
    let shape: KBody
    var volume = false

    var body: some View {
        let units = MeasureUnits(us: Preferences.unitSystemSetting.isUS)
        if let box = shape.bounds {
            let e = box.max - box.min
            LabeledContent("Size X", value: units.length(e.x))
            LabeledContent("Size Y", value: units.length(e.y))
            LabeledContent("Size Z", value: units.length(e.z))
        }
        if volume { LabeledContent("Volume", value: units.volume(shape.volume)) }
    }
}

struct SketchInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let sketch: SketchFeature

    var planeName: String { model.planeName(sketch.plane) }

    var session: SketchSession? { model.sketchSession?.featureID == id ? model.sketchSession : nil }

    var body: some View {
        Section("Sketch") {
            if session == nil {
                Button("Edit Sketch") { model.editSketch(id) }
            } else {
                Button("Finish Sketch") { model.finishSketch() }
                Toggle("Slice View", isOn: Bindable(model).sketchSlice)
                    .help("Hide everything between this sketch's plane and the camera, to reach a sketch that lies between walls")
                Toggle("Show Shape Centres", isOn: Bindable(model).showShapeCentres)
                    .help("Mark the middle of each closed shape with an X, to see where a click will snap")
            }
            LabeledContent("Plane", value: planeName)
            if sketch.uprightAxes != true, session == nil, sketch.plane.isFaceOrPlane {
                LabeledContent("Axes") {
                    Button("Straighten") { model.straightenAxes(of: id) }
                        .help("Turn this sketch so its x axis runs level and y points up, like new sketches. Everything in it turns with it.")
                }
            }
            if let solve = model.result?.sketches[id]?.solve {
                LabeledContent("Status", value: solve.status == .solved
                               ? (solve.degreesOfFreedom == 0 ? "Fully constrained" : "\(solve.degreesOfFreedom) degrees of freedom")
                               : "Over-constrained")
            }
            LabeledContent("Curves", value: "\(sketch.sketch.curves.count)")
            LabeledContent("Constraints", value: "\(sketch.sketch.constraints.count)")
        }
        if let session {
            Section("Constrain Selection (\(session.selection.count + session.axisSelection.count))") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading) {
                    ForEach(ConstraintTool.allCases, id: \.self) { c in
                        Button(c.rawValue) { model.sketchCommand { $0.apply(c) } }
                            .disabled(!session.canApply(c))
                    }
                }
            }
            Section("Constraints") {
                ForEach(session.sketch.constraints) { c in
                    HStack {
                        Text(describe(c.kind)).font(.caption)
                        ruleMark(c.id, in: session.diagnosis)
                        Spacer()
                        Button { model.sketchCommand { $0.deleteConstraint(c.id) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        if !sketch.sketch.texts.isEmpty {
            Section("Text") {
                ForEach(sketch.sketch.texts) { t in
                    LabeledContent("Text") {
                        ExpressionField(text: t.text, completes: false) { v in updateText(t.id) { $0.text = v } }
                    }
                    LabeledContent("Height") {
                        ExpressionField(text: t.height) { v in updateText(t.id) { $0.height = v } }
                    }
                    Picker("Font", selection: Binding(get: { t.font }, set: { f in updateText(t.id) { $0.font = f } })) {
                        ForEach(Self.fonts, id: \.name) { Text($0.title).tag($0.name) }
                        if !Self.fonts.contains(where: { $0.name == t.font }) { Text(t.font).tag(t.font) }
                    }
                }
            }
        }
        Section("Dimensions") {
            ForEach(Array(sketch.sketch.dimensions.enumerated()), id: \.element.id) { i, d in
                LabeledContent(label(d)) {
                    HStack {
                        if let session { ruleMark(d.id, in: session.diagnosis) }
                        ExpressionField(text: d.expression) { text in
                            model.updateFeature(id, "Edit Dimension") { f in
                                if case .sketch(var s) = f.kind {
                                    s.sketch.dimensions[i].expression = text
                                    f.kind = .sketch(s)
                                }
                            }
                        }
                        if session != nil {
                            Button { model.sketchCommand { $0.deleteDimension(d.id) } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Delete this dimension")
                        }
                    }
                }
            }
        }
    }

    /// Fonts offered for sketch text: bold, regular, rounded, stencil-friendly and monospaced faces.
    static let fonts: [(name: String, title: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"), ("Helvetica", "Helvetica"), ("AvenirNext-DemiBold", "Avenir Next"),
        ("Futura-Bold", "Futura Bold"), ("ArialRoundedMTBold", "Arial Rounded"), ("Menlo-Bold", "Menlo Bold"),
        ("Georgia-Bold", "Georgia Bold"),
    ]

    /// Edits a text: through the sketch being edited, or straight in the document.
    func updateText(_ textID: EntityID, _ change: @escaping (inout SketchText) -> Void) {
        if session != nil {
            model.sketchCommand { $0.updateText(textID, change) }
        } else {
            model.updateFeature(id, "Edit Text") { f in
                guard case .sketch(var sf) = f.kind, let i = sf.sketch.texts.firstIndex(where: { $0.id == textID }) else { return }
                change(&sf.sketch.texts[i])
                f.kind = .sketch(sf)
            }
        }
    }

    func describe(_ k: SketchConstraint.Kind) -> String { k.title }

    /// A warning beside a constraint or dimension that fights the others, or a quiet mark on one that only repeats them.
    @ViewBuilder
    func ruleMark(_ id: EntityID, in diagnosis: SketchDiagnosis) -> some View {
        if diagnosis.conflicting.contains(id) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .help("This fights other constraints or dimensions: they can't all hold. Delete one of them.")
                .accessibilityLabel("Conflicts with other constraints")
        } else if diagnosis.redundant.contains(id) {
            Image(systemName: "equal.circle").foregroundStyle(.secondary)
                .help("Redundant: the other constraints and dimensions already say this. It does no harm; you can delete it.")
                .accessibilityLabel("Redundant")
        }
    }

    func label(_ d: SketchDimension) -> String { d.title }
}

/// The bodies a Join, Cut or Intersect works on, each one switched on or off, with "Choose Automatically" to go back
/// to the default. Shared by the features that combine a new shape with existing bodies (extrude, sweep).
struct AffectedBodiesList: View {
    let model: DocumentModel
    let id: FeatureID
    let operation: BodyOperation
    /// The bodies picked, or nil while the choice is automatic.
    let targets: [FeatureID]?
    let setTargets: ([FeatureID]?) -> Void

    /// The bodies the feature could work on: the ones that exist before it in the timeline.
    private var candidateBodies: [BodyResult] {
        let own = model.document.index(of: id) ?? Int.max
        return model.bodies.filter { b in b.id != id && (model.document.index(of: b.id).map { $0 < own } ?? true) }
    }

    /// What the feature works on right now: the bodies picked, or else what the automatic choice came to.
    private var affectedIDs: [FeatureID] { targets ?? model.result?.affectedBodies[id] ?? [] }

    var body: some View {
        let candidates = candidateBodies
        if !candidates.isEmpty {
            let chosen = Set(affectedIDs)
            VStack(alignment: .leading, spacing: 4) {
                Text("Affected bodies").font(.caption).foregroundStyle(.secondary)
                ForEach(candidates, id: \.id) { b in
                    Toggle(b.name, isOn: Binding(get: { chosen.contains(b.id) }, set: { on in
                        var next = chosen
                        if on { next.insert(b.id) } else { next.remove(b.id) }
                        setTargets(candidates.map(\.id).filter { next.contains($0) })
                    }))
                    .toggleStyle(.checkbox)
                }
            }
            if targets != nil {
                Button("Choose Automatically") { setTargets(nil) }
                    .help(operation == .cut ? "Cut every body the shape passes through" : "Work on the newest body")
            } else {
                Text(operation == .cut ? "Chosen automatically: every body the shape passes through. Tick bodies to choose."
                                       : "Chosen automatically. Tick bodies to choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if operation == .join, chosen.count > 1 {
                Text("The bodies ticked are joined into one.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ExtrudeInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let extrude: ExtrudeFeature

    func update(_ name: String, _ change: @escaping (inout ExtrudeFeature) -> Void) {
        model.updateFeature(id, name) { f in
            if case .extrude(var e) = f.kind { change(&e); f.kind = .extrude(e) }
        }
    }

    func preview(_ change: @escaping (inout ExtrudeFeature) -> Void) {
        model.preview(id) { f in
            if case .extrude(var e) = f.kind { change(&e); f.kind = .extrude(e) }
        }
    }

    private enum ExtentKind: String, CaseIterable {
        case distance = "One direction", twoSides = "Two directions", symmetric = "Mirrored", throughAll = "Through all", toFace = "To face"
    }

    private var extentKind: ExtentKind {
        switch extrude.extent {
        case .distance: return .distance
        case .symmetric: return .symmetric
        case .twoSides: return .twoSides
        case .throughAll: return .throughAll
        case .toFace: return .toFace
        }
    }

    /// The size typed so far, kept when switching between the kinds that have one.
    private var size: String {
        switch extrude.extent {
        case .distance(let d), .symmetric(let d), .twoSides(let d, _): return d
        case .throughAll, .toFace: return "10 mm"
        }
    }

    /// A flat face selected in the viewport, to extrude up to.
    private var selectedFace: FaceRef? {
        guard model.selection.count == 1, let pick = model.selection.first else { return nil }
        return model.faceRef(pick)
    }

    /// The list of bodies a Join, Cut or Intersect works on, each one switched on or off.
    private var affectedBodies: some View {
        AffectedBodiesList(model: model, id: id, operation: extrude.operation, targets: extrude.targets) { targets in
            update("Change Affected Bodies") { $0.targets = targets }
        }
    }

    /// Sets the distance. Typed through zero it turns round, as dragging the arrow does: a negative distance cuts
    /// (pushed into the body), a positive one joins. Other operations are left as chosen.
    private func setDistance(_ e: inout ExtrudeFeature, from old: String, to new: String) {
        e.extent = .distance(new)
        func negative(_ text: String) -> Bool { ((try? model.parameterValues.value(of: text, kind: .length)) ?? 0) < 0 }
        if !negative(old), negative(new), e.operation == .join { e.operation = .cut }
        else if negative(old), !negative(new), e.operation == .cut { e.operation = .join }
    }

    var body: some View {
        Section("Extrude") {
            Picker("Extent", selection: Binding(get: { extentKind }, set: { k in
                update("Change Extent") { e in
                    switch k {
                    case .distance: e.extent = e.extent.changed(to: .oneDirection, fallback: size)
                    case .symmetric: e.extent = e.extent.changed(to: .mirrored, fallback: size)
                    case .twoSides: e.extent = e.extent.changed(to: .twoDirections, fallback: size)
                    case .throughAll: e.extent = .throughAll
                    case .toFace: if let f = selectedFace { e.extent = .toFace(f) }
                    }
                }
                if k == .toFace { model.clearSelection() }
            })) {
                ForEach(ExtentKind.allCases, id: \.self) { k in
                    if k != .toFace || selectedFace != nil || extentKind == .toFace { Text(k.rawValue).tag(k) }
                }
            }
            switch extrude.extent {
            case .distance(let d):
                LabeledContent("Distance") {
                    ExpressionField(text: d, preview: { v in preview { setDistance(&$0, from: d, to: v) } }) { v in
                        update("Edit Distance") { setDistance(&$0, from: d, to: v) }
                    }
                }
            case .symmetric(let d):
                LabeledContent("Total") {
                    ExpressionField(text: d, preview: { v in preview { $0.extent = .symmetric(v) } }) { v in
                        update("Edit Distance") { $0.extent = .symmetric(v) }
                    }
                }
            case .twoSides(let d, let b):
                LabeledContent("Distance 1") {
                    ExpressionField(text: d, preview: { v in preview { $0.extent = .twoSides(v, back: b) } }) { v in
                        update("Edit Distance") { $0.extent = .twoSides(v, back: b) }
                    }
                }
                LabeledContent("Distance 2") {
                    ExpressionField(text: b, preview: { v in preview { $0.extent = .twoSides(d, back: v) } }) { v in
                        update("Edit Distance") { $0.extent = .twoSides(d, back: v) }
                    }
                }
            case .throughAll:
                Text("Goes through every body in its direction.").font(.caption).foregroundStyle(.secondary)
            case .toFace(let f):
                LabeledContent("Up to", value: f.face)
                if let face = selectedFace, face != f {
                    Button("Use the Selected Face") { update("Change Face") { $0.extent = .toFace(face) }; model.clearSelection() }
                }
            }
            LabeledContent("Taper") {
                ExpressionField(text: extrude.taper ?? "0 deg", preview: { v in preview { $0.taper = v } }) { v in
                    update("Edit Taper") { $0.taper = v }
                }
            }
            .help("Leans the sides: positive grows the shape as it goes, negative narrows it")
            if extrude.face == nil {
                LabeledContent("Start", value: extrude.start?.face ?? "Profile plane")
                if let face = selectedFace, face != extrude.start {
                    Button("Start from the Selected Face") { model.setStartFace(face, of: id) }
                }
                if extrude.start != nil {
                    Button("Start on the Profile Plane") { model.setStartFace(nil, of: id) }
                }
            }
            if selectedFace == nil, extentKind != .toFace {
                Text("To extrude up to a face, select a flat face parallel to the sketch, then choose To face.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Operation", selection: Binding(get: { extrude.operation },
                                                   set: { op in update("Change Operation") { $0.operation = op } })) {
                ForEach(BodyOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if extrude.operation != .newBody { affectedBodies }
            if extrude.extent.mode != .mirrored {  // a mirrored extrude reaches both ways alike
                Toggle("Flip direction", isOn: Binding(get: { extrude.flipped },
                                                       set: { v in update("Flip") { $0.flipped = v } }))
            }
            if let face = extrude.face {
                let faces = extrude.allFaces
                LabeledContent(faces.count == 1 ? "Face" : "Faces", value: faces.count == 1 ? face.face : "\(faces.count) faces")
            } else {
                LabeledContent("Profiles") {
                    HStack {
                        Text("\(extrude.profiles.count)")
                        Button("Reselect…") { model.reselectProfiles(id) }.help("Pick the profiles to extrude again")
                    }
                }
            }
        }
    }
}

struct EdgeInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let edges: EdgeFeature
    let fillet: Bool

    func update(_ name: String, _ change: @escaping (inout EdgeFeature) -> Void) {
        model.updateFeature(id, name) { f in
            switch f.kind {
            case .fillet(var e): change(&e); f.kind = .fillet(e)
            case .chamfer(var e): change(&e); f.kind = .chamfer(e)
            default: break
            }
        }
    }

    private var firstLabel: String {
        if fillet { return "Radius" }
        return edges.mode == .twoDistances ? "Distance 1" : "Distance"
    }

    var body: some View {
        Section(fillet ? "Fillet" : "Chamfer") {
            if !fillet {
                Picker("Type", selection: Binding(get: { edges.mode }, set: { model.setChamferMode($0, of: id) })) {
                    ForEach(ChamferMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            LabeledContent(firstLabel) {
                ExpressionField(text: edges.size, preview: { v in
                    model.preview(id) { f in
                        switch f.kind {
                        case .fillet(var e): e.size = v; f.kind = .fillet(e)
                        case .chamfer(var e): e.size = v; f.kind = .chamfer(e)
                        default: break
                        }
                    }
                }) { v in update(fillet ? "Edit Radius" : "Edit Distance") { $0.size = v } }
            }
            if !fillet, edges.mode != .equalDistance {
                LabeledContent(edges.mode == .twoDistances ? "Distance 2" : "Angle") {
                    ExpressionField(text: edges.second, preview: { v in
                        model.preview(id) { f in
                            if case .chamfer(var e) = f.kind { e.second = v; f.kind = .chamfer(e) }
                        }
                    }) { v in update(edges.mode == .twoDistances ? "Edit Distance" : "Edit Angle") { $0.second = v } }
                }
                Toggle(edges.mode == .twoDistances ? "Swap the two faces" : "Measure on the other face", isOn: Binding(get: { edges.flipped }, set: { v in
                    update("Flip Chamfer") { $0.flipped = v }
                }))
                .help(edges.mode == .twoDistances ? "Swap which face each distance is measured on"
                      : "Measure the distance, and the angle, on the edge's other face")
            }
            if model.previewInvalid, model.dragHandle?.featureID == id {
                Label("Too large for the neighbouring faces", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Text(!fillet && edges.mode != .equalDistance ? "Or drag the orange arrows in the viewport." : "Or drag the orange arrow in the viewport.").font(.caption).foregroundStyle(.secondary)
            }
        }
        let last = edges.edges.count + edges.faces.count == 1  // keep at least one thing to round
        if !edges.faces.isEmpty || !model.selection.filter(\.isFace).isEmpty {
            Section("Faces (\(edges.faces.count)) · every edge around them") {
                ForEach(Array(edges.faces.enumerated()), id: \.offset) { i, f in
                    HStack {
                        Text(f.face).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button { update("Remove Face") { $0.faces.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(last)
                    }
                }
                let picked = model.selection.compactMap { model.faceRef($0) }
                if !picked.isEmpty {
                    Button("Add \(picked.count) selected face(s)") {
                        update("Add Faces") { e in e.faces += picked.filter { !e.faces.contains($0) } }
                        model.clearSelection()
                    }
                }
            }
        }
        Section("Edges (\(edges.edges.count))") {
            ForEach(Array(edges.edges.enumerated()), id: \.offset) { i, e in
                HStack {
                    Text(e.edge).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button { update("Remove Edge") { $0.edges.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(last)
                }
            }
            if model.selectedEdgeCount > 0 {
                Button("Add \(model.selectedEdgeCount) selected edge(s)") {
                    let refs = model.selection.compactMap { pick -> EdgeRef? in
                        guard pick.isEdge, pick.body < model.meshes.count, let name = model.name(of: pick) else { return nil }
                        return EdgeRef(body: model.meshes[pick.body].id, edge: name)
                    }
                    update("Add Edges") { e in e.edges += refs.filter { !e.edges.contains($0) } }
                    model.clearSelection()
                }
            }
        }
    }
}

// MARK: - Shared pieces for the feature inspectors

/// Reads and writes one kind of feature payload: `update` is an undo step, `preview` is live.
@MainActor
struct FeatureEdit<T> {
    let model: DocumentModel
    let id: FeatureID
    let get: (Feature.Kind) -> T?
    let wrap: (T) -> Feature.Kind

    func update(_ name: String, _ change: @escaping (inout T) -> Void) {
        model.updateFeature(id, name) { f in
            if var v = get(f.kind) { change(&v); f.kind = wrap(v) }
        }
    }

    func preview(_ change: @escaping (inout T) -> Void) {
        model.preview(id) { f in
            if var v = get(f.kind) { change(&v); f.kind = wrap(v) }
        }
    }

    /// A labelled expression field that previews while typing and commits as one undo step.
    func row(_ label: String, _ text: String, _ action: String, _ set: @escaping (inout T, String) -> Void) -> some View {
        LabeledContent(label) {
            ExpressionField(text: text, preview: { v in preview { set(&$0, v) } }) { v in update(action) { set(&$0, v) } }
        }
    }

    func operation(_ value: BodyOperation, _ set: @escaping (inout T, BodyOperation) -> Void) -> some View {
        Picker("Operation", selection: Binding(get: { value }, set: { op in update("Change Operation") { set(&$0, op) } })) {
            ForEach(BodyOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
}

extension DocumentModel {
    func featureName(_ id: FeatureID) -> String { document.features.first { $0.id == id }?.name ?? "missing" }

    /// "XY plane", "Plane1" (a construction plane) or "Face e.end".
    func planeName(_ plane: PlaneRef) -> String {
        switch plane {
        case .xy: return "XY plane"
        case .xz: return "XZ plane"
        case .yz: return "YZ plane"
        case .face(let f): return "Face \(f.face)"
        case .plane(let id): return featureName(id)
        }
    }
}

/// Where a path comes from, with a button to replace it with the curves selected in the viewport.
struct PathSection: View {
    let model: DocumentModel
    let path: CurveRef
    let set: (CurveRef) -> Void

    var body: some View {
        LabeledContent("Path", value: "\(path.curves.count) curve\(path.curves.count == 1 ? "" : "s") in \(model.featureName(path.sketch))")
        if let picked = model.pathRef(model.selectedCurves), picked != path {
            Button("Use the \(picked.curves.count) selected curve\(picked.curves.count == 1 ? "" : "s")") {
                set(picked)
                model.clearSelection()
            }
        } else {
            Text("Click sketch curves in the viewport to choose another path.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Revolve, sweep, loft, rib

struct RevolveInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let revolve: RevolveFeature

    var edit: FeatureEdit<RevolveFeature> {
        FeatureEdit(model: model, id: id, get: { if case .revolve(let r) = $0 { r } else { nil } }, wrap: { .revolve($0) })
    }

    /// Lines of the sketch, numbered as the user sees them.
    var lines: [(id: EntityID, title: String)] {
        let curves = model.result?.sketches[revolve.sketch]?.solved.curves ?? []
        var n = 0
        return curves.compactMap { c in
            guard case .line = c.geometry else { return nil }
            n += 1
            return (c.id, "Line \(n)" + (c.construction ? " (construction)" : ""))
        }
    }

    var body: some View {
        Section("Revolve") {
            edit.row("Angle", revolve.angle, "Edit Angle") { $0.angle = $1 }
            Picker("Axis", selection: Binding(get: { revolve.axis }, set: { a in edit.update("Change Axis") { $0.axis = a } })) {
                Text("Sketch vertical").tag(AxisRef.sketchY)
                Text("Sketch horizontal").tag(AxisRef.sketchX)
                Text("X axis").tag(AxisRef.x)
                Text("Y axis").tag(AxisRef.y)
                Text("Z axis").tag(AxisRef.z)
                ForEach(lines, id: \.id) { Text($0.title).tag(AxisRef.line($0.id)) }
            }
            if let line = model.selectedCurves.first(where: { c in c.sketch == revolve.sketch && lines.contains { $0.id == c.curve } }),
               revolve.axis != .line(line.curve) {
                Button("Use the selected line as the axis") {
                    edit.update("Change Axis") { $0.axis = .line(line.curve) }
                    model.clearSelection()
                }
            }
            edit.operation(revolve.operation) { $0.operation = $1 }
            LabeledContent("Profiles") {
                HStack {
                    Text("\(revolve.profiles.count) in \(model.featureName(revolve.sketch))")
                    Button("Reselect…") { model.reselectProfiles(id) }.help("Pick the profiles (and axis line) again")
                }
            }
        }
    }
}

struct SweepInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let sweep: SweepFeature

    var edit: FeatureEdit<SweepFeature> {
        FeatureEdit(model: model, id: id, get: { if case .sweep(let s) = $0 { s } else { nil } }, wrap: { .sweep($0) })
    }

    var body: some View {
        Section("Sweep") {
            LabeledContent("Profiles") {
                HStack {
                    Text("\(sweep.profiles.count) in \(model.featureName(sweep.sketch))")
                    Button("Reselect…") { model.reselectProfiles(id) }.help("Pick the profiles to sweep again")
                }
            }
            PathSection(model: model, path: sweep.path) { p in edit.update("Change Path") { $0.path = p } }
            edit.operation(sweep.operation) { $0.operation = $1 }
            if sweep.operation != .newBody {
                AffectedBodiesList(model: model, id: id, operation: sweep.operation, targets: sweep.targets) { targets in
                    edit.update("Change Affected Bodies") { $0.targets = targets }
                }
            }
        }
    }
}

struct LoftInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let loft: LoftFeature

    var edit: FeatureEdit<LoftFeature> {
        FeatureEdit(model: model, id: id, get: { if case .loft(let l) = $0 { l } else { nil } }, wrap: { .loft($0) })
    }

    var body: some View {
        Section("Loft") {
            Toggle("Straight sides", isOn: Binding(get: { loft.ruled }, set: { v in edit.update("Change Loft") { $0.ruled = v } }))
            edit.operation(loft.operation) { $0.operation = $1 }
        }
        Section("Profiles, in order (\(loft.sections.count))") {
            ForEach(Array(loft.sections.enumerated()), id: \.offset) { i, section in
                HStack {
                    Text("\(i + 1). \(model.featureName(section.sketch))")
                    Spacer()
                    Button { edit.update("Remove Profile") { $0.sections.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(loft.sections.count <= 2)
                }
            }
            let picked = model.selectedProfiles.filter { p in !loft.sections.contains { $0.sketch == p.sketch } }
            if !picked.isEmpty {
                Button("Add the \(picked.count) selected profile\(picked.count == 1 ? "" : "s")") {
                    edit.update("Add Profile") { l in l.sections += picked.map { LoftSection(sketch: $0.sketch, profile: $0.ref) } }
                    model.clearSelection()
                }
            } else {
                Text("Click a profile in another sketch to add it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TwistSweepInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let twist: TwistSweepFeature

    var edit: FeatureEdit<TwistSweepFeature> {
        FeatureEdit(model: model, id: id, get: { if case .twistSweep(let t) = $0 { t } else { nil } }, wrap: { .twistSweep($0) })
    }

    var body: some View {
        Section("Twist Sweep") {
            edit.row("Length", twist.distance, "Edit Length") { $0.distance = $1 }
            Toggle("Flip direction", isOn: Binding(get: { twist.flipped }, set: { v in edit.update("Flip Direction") { $0.flipped = v } }))
            edit.row("Start angle", twist.startAngle, "Edit Start Angle") { $0.startAngle = $1 }
            edit.row("End angle", twist.endAngle, "Edit End Angle") { $0.endAngle = $1 }
            edit.row("Curve", twist.curve, "Edit Twist Curve") { $0.curve = $1 }
            Text("Curve 1 turns evenly. Above 1 the turn comes late (flat at the start, steep at the end); below 1 it comes early.")
                .font(.caption).foregroundStyle(.secondary)
            edit.row("Slide across (x)", twist.shiftU, "Edit Slide") { $0.shiftU = $1 }
            edit.row("Slide up (y)", twist.shiftV, "Edit Slide") { $0.shiftV = $1 }
            Toggle("Turn about the profile's middle", isOn: Binding(
                get: { twist.pivotU == nil && twist.pivotV == nil },
                set: { middle in
                    edit.update("Change Turning Point") { t in
                        if middle { t.pivotU = nil; t.pivotV = nil } else { t.pivotU = "0 mm"; t.pivotV = "0 mm" }
                    }
                }))
            if let u = twist.pivotU, let v = twist.pivotV {
                edit.row("Turning point x", u, "Edit Turning Point") { $0.pivotU = $1 }
                edit.row("Turning point y", v, "Edit Turning Point") { $0.pivotV = $1 }
            }
            edit.operation(twist.operation) { $0.operation = $1 }
            if twist.operation != .newBody {
                AffectedBodiesList(model: model, id: id, operation: twist.operation, targets: twist.targets) { targets in
                    edit.update("Change Affected Bodies") { $0.targets = targets }
                }
            }
            LabeledContent("Profiles") {
                HStack {
                    Text("\(twist.profiles.count) in \(model.featureName(twist.sketch))")
                    Button("Reselect…") { model.reselectProfiles(id) }.help("Pick the profiles to sweep again")
                }
            }
        }
    }
}

struct RibInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let rib: RibFeature

    var edit: FeatureEdit<RibFeature> {
        FeatureEdit(model: model, id: id, get: { if case .rib(let r) = $0 { r } else { nil } }, wrap: { .rib($0) })
    }

    var body: some View {
        Section("Rib") {
            edit.row("Thickness", rib.thickness, "Edit Thickness") { $0.thickness = $1 }
            PathSection(model: model, path: rib.path) { p in edit.update("Change Rib Curve") { $0.path = p } }
            Text("The rib grows from the curve to the body, and is as thick across the sketch plane.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Hole, primitives, pipe

struct HoleInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let hole: HoleFeature

    var edit: FeatureEdit<HoleFeature> {
        FeatureEdit(model: model, id: id, get: { if case .hole(let h) = $0 { h } else { nil } }, wrap: { .hole($0) })
    }

    var body: some View {
        Section("Hole") {
            Picker("Type", selection: Binding(get: { hole.kind }, set: { k in edit.update("Change Hole Type") { $0.kind = k } })) {
                ForEach(HoleKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            edit.row("Diameter", hole.diameter, "Edit Diameter") { $0.diameter = $1 }
            Picker("Extent", selection: Binding(get: { hole.depth == nil }, set: { through in
                edit.update("Change Extent") { $0.depth = through ? nil : "10 mm" }
            })) {
                Text("Distance").tag(false)
                Text("Through all").tag(true)
            }
            if let depth = hole.depth {
                edit.row("Depth", depth, "Edit Depth") { $0.depth = $1 }
                edit.row("Drill point", hole.tipAngle, "Edit Drill Point") { $0.tipAngle = $1 }
            }
            switch hole.kind {
            case .simple: EmptyView()
            case .counterbore:
                edit.row("Counterbore Ø", hole.headDiameter, "Edit Counterbore") { $0.headDiameter = $1 }
                edit.row("Counterbore depth", hole.headDepth, "Edit Counterbore") { $0.headDepth = $1 }
            case .countersink:
                edit.row("Countersink Ø", hole.headDiameter, "Edit Countersink") { $0.headDiameter = $1 }
                edit.row("Countersink angle", hole.headAngle, "Edit Countersink") { $0.headAngle = $1 }
            }
        }
        Section("Position on \(hole.face.face)") {
            edit.row("X", hole.u, "Move Hole") { $0.u = $1 }
            edit.row("Y", hole.v, "Move Hole") { $0.v = $1 }
        }
    }
}

struct ThreadInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let thread: ThreadFeature

    var edit: FeatureEdit<ThreadFeature> {
        FeatureEdit(model: model, id: id, get: { if case .thread(let t) = $0 { t } else { nil } }, wrap: { .thread($0) })
    }

    /// The face as it was before the thread.
    private var cylinder: KCylinder? {
        try? model.result?.featureInputs[id]?[thread.face.body]?.faceCylinder(thread.face.face, flipped: thread.flipped)
    }

    private var size: ThreadSize? { try? thread.size(of: thread.spec(at: 0), model.parameterValues) }

    private func mm(_ x: Double) -> String { formatDimension(x, kind: .length) }

    /// What the offset picker can say: no offset, a material's suggested percentage, or a value of your own.
    private enum ToleranceChoice: Hashable {
        case none, material(ThreadMaterial), percent, distance
    }

    private var toleranceChoice: ToleranceChoice {
        if thread.tolerance == nil { return .none }
        if let material = thread.toleranceMaterial { return .material(material) }
        return thread.toleranceUnit == .percent ? .percent : .distance
    }

    /// The tolerance offset for printing, in one row so that no dividers fall between its parts: a
    /// picker (none, the material presets, a percent or a distance of your own), the value, and a note.
    private var tolerance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tolerance offset", selection: Binding(get: { toleranceChoice }, set: { choice in
                edit.update(choice == .none ? "Remove Thread Tolerance" : "Change Thread Tolerance") { t in
                    switch choice {
                    case .none: t.tolerance = nil; t.toleranceMaterial = nil
                    case .material(let m):
                        t.toleranceUnit = .percent; t.tolerance = formatPercent(m.percent, unit: false); t.toleranceMaterial = m
                    case .percent, .distance:
                        let unit: ThreadToleranceUnit = choice == .percent ? .percent : .distance
                        // Keep the value when only the unit changes between the two custom choices.
                        if t.tolerance == nil || t.toleranceMaterial != nil || t.toleranceUnit != unit { t.tolerance = "0" }
                        t.toleranceUnit = unit; t.toleranceMaterial = nil
                    }
                }
            })) {
                Text("None").tag(ToleranceChoice.none)
                Divider()
                ForEach(ThreadMaterial.allCases, id: \.self) {
                    Text("\($0.rawValue) (+\(formatPercent($0.percent)))").tag(ToleranceChoice.material($0))
                }
                Divider()
                Text("Custom percent").tag(ToleranceChoice.percent)
                Text("Custom distance").tag(ToleranceChoice.distance)
            }
            if let value = thread.tolerance {
                edit.row(thread.toleranceUnit == .percent ? "Offset (%)" : "Offset", value, "Edit Thread Tolerance") {
                    $0.tolerance = $1; $0.toleranceMaterial = nil
                }
                Text("The thread is modeled this much larger (smaller if negative) on its major and minor diameters, to make up for printing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func formatPercent(_ x: Double, unit: Bool = true) -> String {
        let text = x == x.rounded() ? String(Int(x)) : String(format: "%g", x)
        return unit ? text + " %" : text
    }

    /// The standard and size pickers for the face at `n` (the only one, or one of several holes); a custom thread has
    /// its diameter and pitch typed instead.
    @ViewBuilder private func sizePickers(_ n: Int, label: String) -> some View {
        let spec = thread.spec(at: n)
        let current = try? thread.size(of: spec, model.parameterValues)
        Picker("\(label)Standard", selection: Binding(get: { spec.standard }, set: { standard in
            // Keep about the same diameter in the new standard.
            let d = current?.diameter ?? 6
            let changed: ThreadSpec
            if standard == .custom {
                changed = .custom(diameter: d, pitch: current?.pitch ?? 1)
            } else {
                let nearest = standard.sizes.min { abs($0.diameter - d) < abs($1.diameter - d) }
                changed = ThreadSpec(standard: standard, size: nearest?.name ?? spec.size)
            }
            edit.update("Change Thread Standard") { $0.setSpec(changed, at: n) }
        })) {
            ForEach(ThreadStandard.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        if spec.standard == .custom {
            LabeledContent("\(label)Major Ø") {
                ExpressionField(text: spec.diameter ?? "", preview: { v in
                    var s = spec; s.diameter = v
                    edit.preview { $0.setSpec(s, at: n) }
                }) { v in
                    var s = spec; s.diameter = v
                    edit.update("Edit Thread Diameter") { $0.setSpec(s, at: n) }
                }
            }
            LabeledContent("\(label)Pitch") {
                ExpressionField(text: spec.pitch ?? "", preview: { v in
                    var s = spec; s.pitch = v
                    edit.preview { $0.setSpec(s, at: n) }
                }) { v in
                    var s = spec; s.pitch = v
                    edit.update("Edit Thread Pitch") { $0.setSpec(s, at: n) }
                }
            }
        } else {
            Picker("\(label)Size", selection: Binding(get: { spec.size }, set: { name in
                edit.update("Change Thread Size") { $0.setSpec(ThreadSpec(standard: spec.standard, size: name), at: n) }
            })) {
                ForEach(spec.standard.sizes, id: \.name) { Text($0.label(spec.standard)).tag($0.name) }
                if current == nil { Text(spec.size).tag(spec.size) }  // from a file with a size we don't list
            }
        }
    }

    var body: some View {
        Section("Thread") {
            if let cylinder {
                LabeledContent("Kind", value: cylinder.isHole ? "Internal (in a hole)" : "External (on a shaft)")
            }
            if !thread.moreFaces.isEmpty { LabeledContent("Faces", value: "\(thread.faces.count) holes, one length, direction and tolerance") }
            if thread.faces.count > 1 {
                // Holes picked together may differ in size: each has its own.
                ForEach(0..<thread.faces.count, id: \.self) { n in
                    Divider()
                    sizePickers(n, label: "Hole \(n + 1) ")
                    if let size = try? thread.size(of: thread.spec(at: n), model.parameterValues) {
                        let grow = ((try? thread.modeledDiameter(of: size, model.parameterValues)) ?? size.diameter) - size.diameter
                        LabeledContent("Hole \(n + 1) Ø", value: "major \(mm(size.diameter + grow)), minor \(mm(size.minorDiameter + grow))")
                    }
                }
                Divider()
            } else {
                sizePickers(0, label: "")
                if let size {
                    if thread.standard != .custom {
                    LabeledContent("Pitch", value: thread.standard.isInch
                                   ? "\(mm(size.pitch)) (\(Int((25.4 / size.pitch).rounded())) per inch)" : mm(size.pitch))
                    }
                    // As modeled, with the tolerance offset (the nominal sizes when there is none).
                    let grow = ((try? thread.modeledDiameter(of: size, model.parameterValues)) ?? size.diameter) - size.diameter
                    LabeledContent(thread.standard == .custom ? "Modeled major Ø" : "Major Ø", value: mm(size.diameter + grow))
                    LabeledContent("Minor Ø", value: mm(size.minorDiameter + grow))
                    if cylinder?.isHole == true { LabeledContent("Tap drill", value: mm(size.tapDrill)) }
                }
            }
            tolerance
            Picker("Length", selection: Binding(get: { thread.length == nil }, set: { full in
                let half = cylinder.map { mm(($0.length / 2).rounded()) } ?? "10 mm"
                edit.update("Change Thread Length") { $0.length = full ? nil : half }
            })) {
                Text("Full length").tag(true)
                Text("Distance").tag(false)
            }
            if let length = thread.length {
                edit.row("Distance", length, "Edit Thread Length") { $0.length = $1 }
                Toggle("Start from the other end", isOn: Binding(get: { thread.flipped }, set: { v in
                    edit.update("Flip Thread") { $0.flipped = v }
                }))
            }
            Toggle("Left-handed", isOn: Binding(get: { thread.leftHanded }, set: { v in
                edit.update(v ? "Make Thread Left-Handed" : "Make Thread Right-Handed") { $0.leftHanded = v }
            }))
            Text("A modeled thread with the basic 60° profile. The face is turned or bored to the thread's diameters first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PrimitiveInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let primitive: PrimitiveFeature

    var edit: FeatureEdit<PrimitiveFeature> {
        FeatureEdit(model: model, id: id, get: { if case .primitive(let p) = $0 { p } else { nil } }, wrap: { .primitive($0) })
    }

    var planeName: String { model.planeName(primitive.plane) }

    var body: some View {
        Section(primitive.kind.rawValue) {
            switch primitive.kind {
            case .box:
                edit.row("Width", primitive.width, "Edit Width") { $0.width = $1 }
                edit.row("Length", primitive.length, "Edit Length") { $0.length = $1 }
                edit.row("Height", primitive.height, "Edit Height") { $0.height = $1 }
            case .cylinder:
                edit.row("Diameter", primitive.diameter, "Edit Diameter") { $0.diameter = $1 }
                edit.row("Height", primitive.height, "Edit Height") { $0.height = $1 }
            case .sphere:
                edit.row("Diameter", primitive.diameter, "Edit Diameter") { $0.diameter = $1 }
            case .torus:
                edit.row("Diameter", primitive.diameter, "Edit Diameter") { $0.diameter = $1 }
                edit.row("Tube Ø", primitive.tube, "Edit Tube") { $0.tube = $1 }
            case .coil:
                edit.row("Diameter", primitive.diameter, "Edit Diameter") { $0.diameter = $1 }
                edit.row("Section Ø", primitive.tube, "Edit Section") { $0.tube = $1 }
                edit.row("Pitch", primitive.pitch, "Edit Pitch") { $0.pitch = $1 }
                edit.row("Turns", primitive.turns, "Edit Turns") { $0.turns = $1 }
            }
            edit.operation(primitive.operation) { $0.operation = $1 }
        }
        Section("Position on \(planeName)") {
            edit.row("X", primitive.u, "Move \(primitive.kind.rawValue)") { $0.u = $1 }
            edit.row("Y", primitive.v, "Move \(primitive.kind.rawValue)") { $0.v = $1 }
        }
    }
}

struct PipeInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let pipe: PipeFeature

    var edit: FeatureEdit<PipeFeature> {
        FeatureEdit(model: model, id: id, get: { if case .pipe(let p) = $0 { p } else { nil } }, wrap: { .pipe($0) })
    }

    var body: some View {
        Section("Pipe") {
            edit.row("Diameter", pipe.diameter, "Edit Diameter") { $0.diameter = $1 }
            Toggle("Hollow", isOn: Binding(get: { pipe.wall != nil }, set: { v in edit.update("Change Pipe") { $0.wall = v ? "1 mm" : nil } }))
            if let wall = pipe.wall {
                edit.row("Wall", wall, "Edit Wall") { $0.wall = $1 }
            }
            PathSection(model: model, path: pipe.path) { p in edit.update("Change Path") { $0.path = p } }
            edit.operation(pipe.operation) { $0.operation = $1 }
        }
    }
}

// MARK: - Move and rotate

/// The bodies a move or rotate works on.
struct BodiesRow: View {
    let model: DocumentModel
    let ids: [FeatureID]
    var title: String?
    var body: some View {
        // A body used up by a later Combine is named after the feature that made it.
        let names = ids.map { id in
            model.bodies.first { $0.id == id }?.name ?? model.document.features.first { $0.id == id }?.name ?? "missing"
        }
        LabeledContent(title ?? (ids.count == 1 ? "Body" : "Bodies"), value: names.joined(separator: ", "))
    }
}

struct MoveInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let move: MoveFeature

    var edit: FeatureEdit<MoveFeature> {
        FeatureEdit(model: model, id: id, get: { if case .move(let m) = $0 { m } else { nil } }, wrap: { .move($0) })
    }

    var body: some View {
        Section("Move") {
            edit.row("X", move.dx, "Move X") { $0.dx = $1 }
            edit.row("Y", move.dy, "Move Y") { $0.dy = $1 }
            edit.row("Z", move.dz, "Move Z") { $0.dz = $1 }
            edit.row("Rotate X", move.rx, "Rotate X") { $0.rx = $1 }
            edit.row("Rotate Y", move.ry, "Rotate Y") { $0.ry = $1 }
            edit.row("Rotate Z", move.rz, "Rotate Z") { $0.rz = $1 }
            Text("Turns about the pivot, X then Y then Z, before the move. Drag the arrows, squares and rings in the viewport, or type here.")
                .font(.caption).foregroundStyle(.secondary)
            pivotRows
            if !move.bodies.isEmpty { BodiesRow(model: model, ids: move.bodies) }
            if !move.sketches.isEmpty {
                let names = move.sketches.map { id in model.document.features.first { $0.id == id }?.name ?? "missing" }
                LabeledContent(names.count == 1 ? "Sketch" : "Sketches", value: names.joined(separator: ", "))
            }
        }
    }
}

extension MoveInspector {
    /// The pivot the turns are about: the middle of what moves, or a point of the user's choosing.
    @ViewBuilder var pivotRows: some View {
        LabeledContent("Pivot") {
            Menu(move.pivot == nil ? "Middle" : "Point") {
                Button("Middle of What Moves") { model.setMovePivot(id, nil) }
                Button("Origin") { model.setMovePivot(id, .zero) }
                if let b = model.moveInputBounds(id) {
                    Divider()
                    let mid = (b.min + b.max) / 2
                    Button("Bottom Centre") { model.setMovePivot(id, SIMD3(mid.x, mid.y, b.min.z)) }
                    Button("Top Centre") { model.setMovePivot(id, SIMD3(mid.x, mid.y, b.max.z)) }
                    Button("Left Side Centre") { model.setMovePivot(id, SIMD3(b.min.x, mid.y, mid.z)) }
                    Button("Right Side Centre") { model.setMovePivot(id, SIMD3(b.max.x, mid.y, mid.z)) }
                    Button("Front Side Centre") { model.setMovePivot(id, SIMD3(mid.x, b.min.y, mid.z)) }
                    Button("Back Side Centre") { model.setMovePivot(id, SIMD3(mid.x, b.max.y, mid.z)) }
                    Button("Lowest Corner") { model.setMovePivot(id, b.min) }
                    Button("Highest Corner") { model.setMovePivot(id, b.max) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        if let pivot = move.pivot {
            edit.row("Pivot X", pivot[0], "Pivot X") { $0.pivotX = $1 }
            edit.row("Pivot Y", pivot[1], "Pivot Y") { $0.pivotY = $1 }
            edit.row("Pivot Z", pivot[2], "Pivot Z") { $0.pivotZ = $1 }
        }
    }
}

struct CombineInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let combine: CombineFeature

    var edit: FeatureEdit<CombineFeature> {
        FeatureEdit(model: model, id: id, get: { if case .combine(let c) = $0 { c } else { nil } }, wrap: { .combine($0) })
    }

    var body: some View {
        Section("Combine") {
            Picker("Operation", selection: Binding(get: { combine.operation },
                                                   set: { op in edit.update("Change Operation") { $0.operation = op } })) {
                ForEach([BodyOperation.join, .cut, .intersect], id: \.self) { Text($0.rawValue).tag($0) }
            }
            BodiesRow(model: model, ids: [combine.target], title: "Target")
            BodiesRow(model: model, ids: combine.tools, title: combine.tools.count == 1 ? "Tool" : "Tools")
            Toggle("Keep tool bodies", isOn: Binding(get: { combine.keepTools },
                                                     set: { v in edit.update("Keep Tools") { $0.keepTools = v } }))
            Button("Swap Target and Tool") {
                edit.update("Swap Bodies") { c in
                    guard let tool = c.tools.first else { return }
                    c.tools[0] = c.target
                    c.target = tool
                }
            }
            .disabled(combine.tools.count != 1)
        }
    }
}

struct SplitInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let split: SplitFeature

    var edit: FeatureEdit<SplitFeature> {
        FeatureEdit(model: model, id: id, get: { if case .split(let s) = $0 { s } else { nil } }, wrap: { .split($0) })
    }

    /// What the bodies are divided with, in words.
    var toolDescription: String {
        switch split.tool {
        case .plane(let ref): return model.planeName(ref)
        case .face(let face): return "Face \(face.face)"
        case .profile(let sketch): return "Profile of \(model.featureName(sketch))"
        case .parts: return "Separate parts"
        }
    }

    var body: some View {
        Section("Split Body") {
            BodiesRow(model: model, ids: split.bodies, title: split.bodies.count == 1 ? "Body" : "Bodies")
            LabeledContent("Split with", value: toolDescription)
            Text("A plane, a flat face or a profile cuts all the way through; a curved face cuts only where it is. A body it doesn't cross stays as it is. "
                 + "The first piece keeps the body's name, the others become bodies of their own.")
                .font(.caption).foregroundStyle(.secondary)
            let fresh = model.pickedBodies.filter { !split.bodies.contains($0) }
            if !fresh.isEmpty {
                Button("Split the \(fresh.count) Selected Bod\(fresh.count == 1 ? "y" : "ies") Too") {
                    edit.update("Add Bodies") { $0.bodies += fresh }
                    model.clearSelection()
                }
            }
        }
    }
}

struct LayOnFloorInspector: View {
    let model: DocumentModel
    let face: FaceRef

    var body: some View {
        Section("Lay on Floor") {
            BodiesRow(model: model, ids: [face.body])
            LabeledContent("Face", value: face.face)
            Text("The body turns until this face looks straight down, then drops until the face sits on the floor (the XY plane). "
                 + "The face stays where it is sideways. To lay another face down, delete this feature and click that face.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ScaleInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let scale: ScaleFeature

    var edit: FeatureEdit<ScaleFeature> {
        FeatureEdit(model: model, id: id, get: { if case .scale(let s) = $0 { s } else { nil } }, wrap: { .scale($0) })
    }

    var body: some View {
        Section("Scale") {
            edit.row("Factor", scale.factor, "Edit Scale Factor") { $0.factor = $1 }
            if !scale.bodies.isEmpty { BodiesRow(model: model, ids: scale.bodies) }
            if !scale.sketches.isEmpty {
                let names = scale.sketches.map { model.featureName($0) }
                LabeledContent(names.count == 1 ? "Sketch" : "Sketches", value: names.joined(separator: ", "))
            }
            Text(scale.bodies.isEmpty ? "Scales about each sketch's origin. Features after this one use the scaled sketch."
                 : "Bodies scale about the middle of them all, sketches about their own origins. Features after this one use the scaled shapes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RotateInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let rotate: RotateFeature

    var edit: FeatureEdit<RotateFeature> {
        FeatureEdit(model: model, id: id, get: { if case .rotate(let r) = $0 { r } else { nil } }, wrap: { .rotate($0) })
    }

    var body: some View {
        Section("Rotate") {
            edit.row("Angle", rotate.angle, "Edit Angle") { $0.angle = $1 }
            Picker("About", selection: Binding(get: { rotate.axis }, set: { a in edit.update("Change Axis") { $0.axis = a } })) {
                ForEach(Axis3.allCases, id: \.self) { Text("\($0.rawValue) axis").tag($0) }
            }
            Text("Turns about an axis through the middle of the body.").font(.caption).foregroundStyle(.secondary)
            BodiesRow(model: model, ids: rotate.bodies)
        }
    }
}

// MARK: - Planes, mirror, pattern, shell

struct PlaneInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let plane: PlaneFeature

    var edit: FeatureEdit<PlaneFeature> {
        FeatureEdit(model: model, id: id, get: { if case .plane(let p) = $0 { p } else { nil } }, wrap: { .plane($0) })
    }

    var body: some View {
        Section("Plane") {
            LabeledContent("From", value: model.planeName(plane.base))
            edit.row("Offset", plane.offset, "Edit Offset") { $0.offset = $1 }
            edit.row("Angle", plane.angle, "Edit Angle") { $0.angle = $1 }
            Picker("Turned about", selection: Binding(get: { plane.axis }, set: { a in edit.update("Change Axis") { $0.axis = a } })) {
                ForEach(PlaneAxis.allCases, id: \.self) { Text("\($0.rawValue) axis").tag($0) }
            }
            if plane.extent != nil { Button("Reset Size") { edit.update("Reset Plane Size") { $0.extent = nil } } }
            Button("New Sketch on This Plane") { model.beginSketch(on: .plane(id)) }
        }
    }
}

/// Join puts copies into their bodies; New Body keeps them apart (Cut and Intersect don't apply).
private struct CopyOperationPicker: View {
    let value: BodyOperation
    let set: @MainActor (BodyOperation) -> Void
    var body: some View {
        Picker("Copies", selection: Binding(get: { value == .newBody ? .newBody : .join }, set: { set($0) })) {
            Text("Join to the body").tag(BodyOperation.join)
            Text("New body").tag(BodyOperation.newBody)
        }
    }
}

struct MirrorInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let mirror: MirrorFeature

    var edit: FeatureEdit<MirrorFeature> {
        FeatureEdit(model: model, id: id, get: { if case .mirror(let m) = $0 { m } else { nil } }, wrap: { .mirror($0) })
    }

    /// The plane it was made with, an axis, or the picked edge.
    private var acrossChoice: Binding<String> {
        Binding(get: {
            switch mirror.line {
            case nil: return "Plane"
            case .x?: return "X"
            case .y?: return "Y"
            case .z?: return "Z"
            case .edge?: return "Edge"
            }
        }, set: { v in
            edit.update("Change Mirror") { m in
                switch v {
                case "Plane": m.line = nil
                case "X": m.line = .x
                case "Y": m.line = .y
                case "Z": m.line = .z
                default: break
                }
            }
        })
    }

    var body: some View {
        Section("Mirror") {
            Picker("Across", selection: acrossChoice) {
                Text(model.planeName(mirror.plane)).tag("Plane")
                Text("Along the X axis").tag("X")
                Text("Along the Y axis").tag("Y")
                Text("Along the Z axis").tag("Z")
                if case .edge(let e)? = mirror.line { Text("Along edge \(e.edge)").tag("Edge") }
            }
            if model.selectedEdgeCount == 1, let pick = model.selection.first(where: \.isEdge), let edge = model.straightEdgeRef(pick) {
                Button("Mirror Along the Selected Edge") {
                    edit.update("Change Mirror") { $0.line = .edge(edge) }
                    model.clearSelection()
                }
            }
            if mirror.line != nil {
                Text("The mirror plane holds the line and stands square to the face the edge borders (the floor for an axis).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CopyOperationPicker(value: mirror.operation) { op in edit.update("Change Operation") { $0.operation = op } }
            BodiesRow(model: model, ids: mirror.bodies)
        }
    }
}

struct PatternInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let pattern: PatternFeature

    var edit: FeatureEdit<PatternFeature> {
        FeatureEdit(model: model, id: id, get: { if case .pattern(let p) = $0 { p } else { nil } }, wrap: { .pattern($0) })
    }

    /// X, Y, Z, or the picked edge.
    private var axisChoice: Binding<String> {
        Binding(get: {
            switch pattern.axis {
            case .x: return "X"
            case .y: return "Y"
            case .z: return "Z"
            case .edge: return "Edge"
            }
        }, set: { v in
            edit.update("Change Direction") { p in
                switch v {
                case "X": p.axis = .x
                case "Y": p.axis = .y
                case "Z": p.axis = .z
                default: break
                }
            }
        })
    }

    var body: some View {
        Section("Pattern") {
            Picker("Kind", selection: Binding(get: { pattern.kind }, set: { k in
                edit.update("Change Pattern") { p in
                    guard p.kind != k else { return }
                    p.kind = k
                    p.spacing = k == .linear ? "20 mm" : "360 deg"
                }
            })) {
                ForEach(PatternKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            edit.row("Count", pattern.count, "Edit Count") { $0.count = $1 }
            if pattern.kind == .linear {
                edit.row("Spacing", pattern.spacing, "Edit Spacing") { $0.spacing = $1 }
            } else {
                edit.row("Angle", pattern.spacing, "Edit Angle") { $0.spacing = $1 }
            }
            Picker(pattern.kind == .linear ? "Along" : "Around", selection: axisChoice) {
                Text("X axis").tag("X")
                Text("Y axis").tag("Y")
                Text("Z axis").tag("Z")
                if case .edge(let e) = pattern.axis { Text("Edge \(e.edge)").tag("Edge") }
            }
            if model.selectedEdgeCount == 1, let pick = model.selection.first(where: \.isEdge),
               let m = model.meshes[safe: pick.body], let name = model.name(of: pick) {
                Button("Use the Selected Edge") {
                    edit.update("Change Direction") { $0.axis = .edge(EdgeRef(body: m.id, edge: name)) }
                    model.clearSelection()
                }
            }
            Text(pattern.kind == .linear ? "Count includes the original." : "Count includes the original; 360° spreads them all the way round.")
                .font(.caption).foregroundStyle(.secondary)
            CopyOperationPicker(value: pattern.operation) { op in edit.update("Change Operation") { $0.operation = op } }
            BodiesRow(model: model, ids: pattern.bodies)
        }
    }
}

struct ShellInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let shell: ShellFeature

    var edit: FeatureEdit<ShellFeature> {
        FeatureEdit(model: model, id: id, get: { if case .shell(let s) = $0 { s } else { nil } }, wrap: { .shell($0) })
    }

    var body: some View {
        Section("Shell") {
            edit.row("Thickness", shell.thickness, "Edit Thickness") { $0.thickness = $1 }
            Toggle("Walls inside the body", isOn: Binding(get: { shell.inside }, set: { v in edit.update("Change Side") { $0.inside = v } }))
            LabeledContent("Open faces", value: "\(shell.faces.count)")
            let picked = model.selection.compactMap { model.faceRef($0) }.filter { $0.body == shell.body }
            if !picked.isEmpty {
                Button("Open the \(picked.count) Selected Face(s) Too") {
                    edit.update("Add Faces") { s in s.faces += picked.filter { !s.faces.contains($0) } }
                    model.clearSelection()
                }
            }
            BodiesRow(model: model, ids: [shell.body])
        }
    }
}

struct DraftInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let draft: DraftFeature

    var edit: FeatureEdit<DraftFeature> {
        FeatureEdit(model: model, id: id, get: { if case .draft(let d) = $0 { d } else { nil } }, wrap: { .draft($0) })
    }

    var body: some View {
        Section("Draft") {
            edit.row("Angle", draft.angle, "Edit Angle") { $0.angle = $1 }
            Text("A positive angle leans the faces in, so the body gets narrower away from the face that stays put; a negative angle widens it.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Drafted faces", value: "\(draft.faces.count)")
            let picked = model.selection.compactMap { model.faceRef($0) }.filter { $0.body == draft.body }
            let fresh = picked.filter { !draft.faces.contains($0) && $0 != draft.fixed }
            if !fresh.isEmpty {
                Button("Draft the \(fresh.count) Selected Face\(fresh.count == 1 ? "" : "s") Too") {
                    edit.update("Add Faces") { d in d.faces += fresh }
                    model.clearSelection()
                }
            }
            LabeledContent("Stays put", value: draft.fixed?.face ?? "Pick a flat face")
            if picked.count == 1, let face = picked.first, face != draft.fixed, !draft.faces.contains(face) {
                Button("Use the Selected Face as the One That Stays Put") {
                    edit.update("Change Fixed Face") { $0.fixed = face }
                    model.clearSelection()
                }
            }
            BodiesRow(model: model, ids: [draft.body])
        }
    }
}

struct ProjectInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let project: ProjectFeature

    var edit: FeatureEdit<ProjectFeature> {
        FeatureEdit(model: model, id: id, get: { if case .project(let p) = $0 { p } else { nil } }, wrap: { .project($0) })
    }

    var body: some View {
        Section("Project") {
            Picker("Type", selection: Binding(get: { project.mode }, set: { m in edit.update("Change Type") { $0.mode = m } })) {
                ForEach(ProjectMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            edit.row("Height", project.signedHeight, "Edit Height") { $0.setHeight($1) }
            Toggle("Flip direction", isOn: Binding(get: { project.flipped }, set: { v in edit.update("Flip") { $0.flipped = v } }))
            Toggle("True size on round faces", isOn: Binding(get: { project.wrap ?? false }, set: { v in edit.update("Change Wrapping") { $0.wrap = v } }))
                .help("Wraps the profiles round a cylinder like a label on a can, so letters keep their size. Off throws them on from the side, which stretches them where the surface turns away.")
            LabeledContent("Profiles") {
                HStack {
                    Text("\(project.profiles.count)")
                    Button("Reselect…") { model.reselectProfiles(id) }.help("Pick the profiles to project again")
                }
            }
            LabeledContent("Faces", value: project.faces.isEmpty ? "All that face the sketch" : "\(project.faces.count)")
            let picked = model.selection.compactMap { model.faceRef($0) }.filter { $0.body == project.target }
            if !picked.isEmpty {
                Button("Project onto the \(picked.count) Selected Face(s)") {
                    edit.update("Change Faces") { $0.faces = picked }
                    model.clearSelection()
                }
            }
            if !project.faces.isEmpty {
                Button("Project onto Every Face Instead") { edit.update("Change Faces") { $0.faces = [] } }
            }
            BodiesRow(model: model, ids: [project.target])
            Text("The profiles follow the body's surface, flat or curved. With true size on, a cylinder gets them wrapped round it like a label (the sketch must run parallel to its axis); with it off they are thrown on along the sketch's direction like a projector, and are cut off where the surface turns edge-on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ImageInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let image: ImageFeature
    /// The opacity while the slider is dragged; nil otherwise, so the view follows the model.
    @State private var dragging: Double?

    var edit: FeatureEdit<ImageFeature> {
        FeatureEdit(model: model, id: id, get: { if case .image(let i) = $0 { i } else { nil } }, wrap: { .image($0) })
    }

    var body: some View {
        Section("Canvas") {
            LabeledContent("File", value: image.fileName)
            LabeledContent("On", value: model.planeName(image.plane))
            LabeledContent("Opacity") {
                HStack {
                    Slider(value: Binding(get: { dragging ?? image.opacity }, set: { v in
                        dragging = v
                        model.setImageOpacity(id, v, final: false)
                    }), in: 0...1) { editing in
                        if !editing, let v = dragging {
                            model.setImageOpacity(id, v)
                            dragging = nil
                        }
                    }
                    Text("\(Int(((dragging ?? image.opacity) * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            edit.row("Width", image.width, "Edit Width") { $0.width = $1 }
            LabeledContent("Height", value: model.imageHeightText(image))
            edit.row("Across", image.u, "Edit Position") { $0.u = $1 }
            edit.row("Up", image.v, "Edit Position") { $0.v = $1 }
            edit.row("Turn", image.angle, "Edit Angle") { $0.angle = $1 }
            Button("Replace Image…") { model.replaceImage(id) }
            Text("A reference to trace over: it builds nothing, and clicks pass through it. The image is kept in the part. Width, position and turn take expressions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ImportInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let imported: ImportFeature

    var body: some View {
        Section("Import") {
            LabeledContent("File", value: imported.fileName)
            LabeledContent("Size", value: imported.data.count.formatted(.byteCount(style: .file)))
            Button("Replace File…") { model.replaceImport(id) }
                .disabled(model.isImporting)
            Text("The file is kept in the part, so it rebuilds without the original. Move places it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

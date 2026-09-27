// Edits the selected feature: every value is an expression, and any change regenerates the model.
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
                        ExpressionField(text: feature.name, monospaced: false) { model.renameFeature(id, to: $0) }
                    }
                    if feature.createsBody, let body = model.bodies.first(where: { $0.id == id }) {
                        LabeledContent("Body name") {
                            ExpressionField(text: body.name, monospaced: false) { model.renameBody(id, to: $0) }
                        }
                    }
                    LabeledContent("Type", value: feature.typeName)
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
                case .rib(let f): RibInspector(model: model, id: id, rib: f)
                case .hole(let f): HoleInspector(model: model, id: id, hole: f)
                case .primitive(let f): PrimitiveInspector(model: model, id: id, primitive: f)
                case .pipe(let f): PipeInspector(model: model, id: id, pipe: f)
                case .move(let f): MoveInspector(model: model, id: id, move: f)
                case .rotate(let f): RotateInspector(model: model, id: id, rotate: f)
                case .combine(let f): CombineInspector(model: model, id: id, combine: f)
                }
                Section {
                    Button("Delete Feature", role: .destructive) { model.deleteFeature(id) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Feature Selected", systemImage: "cursorarrow.click",
                                   description: Text("Select a feature in the timeline to edit it, or pick a tool in the toolbar to create one."))
        }
    }
}

struct SketchInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let sketch: SketchFeature

    var planeName: String {
        switch sketch.plane {
        case .xy: return "XY plane"
        case .xz: return "XZ plane"
        case .yz: return "YZ plane"
        case .face(let f): return "Face \(f.face)"
        }
    }

    var session: SketchSession? { model.sketchSession?.featureID == id ? model.sketchSession : nil }

    var body: some View {
        Section("Sketch") {
            if session == nil {
                Button("Edit Sketch") { model.editSketch(id) }
            } else {
                Button("Finish Sketch") { model.finishSketch() }
            }
            LabeledContent("Plane", value: planeName)
            if let solve = model.result?.sketches[id]?.solve {
                LabeledContent("Status", value: solve.status == .solved
                               ? (solve.degreesOfFreedom == 0 ? "Fully constrained" : "\(solve.degreesOfFreedom) degrees of freedom")
                               : "Over-constrained")
            }
            LabeledContent("Curves", value: "\(sketch.sketch.curves.count)")
            LabeledContent("Constraints", value: "\(sketch.sketch.constraints.count)")
        }
        if let session {
            Section("Constrain Selection (\(session.selection.count))") {
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
                        ExpressionField(text: t.text) { v in updateText(t.id) { $0.text = v } }
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
                    ExpressionField(text: d.expression) { text in
                        model.updateFeature(id, "Edit Dimension") { f in
                            if case .sketch(var s) = f.kind {
                                s.sketch.dimensions[i].expression = text
                                f.kind = .sketch(s)
                            }
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

    func describe(_ k: SketchConstraint.Kind) -> String {
        switch k {
        case .coincident: return "Coincident"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .parallel: return "Parallel"
        case .perpendicular: return "Perpendicular"
        case .equal: return "Equal"
        case .tangent: return "Tangent"
        case .pointOnCurve: return "Point on curve"
        case .midpoint: return "Midpoint"
        case .fix: return "Fixed"
        }
    }

    func label(_ d: SketchDimension) -> String {
        switch d.kind {
        case .distance: return "Distance"
        case .horizontalDistance: return "Horizontal"
        case .verticalDistance: return "Vertical"
        case .pointLineDistance: return "Distance"
        case .length(let l): return "Length \(l)"
        case .radius(let c): return "Radius \(c)"
        case .diameter(let c): return "Ø \(c)"
        case .angle: return "Angle"
        case .radialOffset: return "Offset"
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

    var body: some View {
        Section("Extrude") {
            switch extrude.extent {
            case .distance(let d):
                LabeledContent("Distance") {
                    ExpressionField(text: d, preview: { v in preview { $0.extent = .distance(v) } }) { v in
                        update("Edit Distance") { $0.extent = .distance(v) }
                    }
                }
            case .symmetric(let d):
                LabeledContent("Total") {
                    ExpressionField(text: d, preview: { v in preview { $0.extent = .symmetric(v) } }) { v in
                        update("Edit Distance") { $0.extent = .symmetric(v) }
                    }
                }
            case .twoSides(let d, let b):
                LabeledContent("Side 1") { ExpressionField(text: d) { v in update("Edit Distance") { $0.extent = .twoSides(v, back: b) } } }
                LabeledContent("Side 2") { ExpressionField(text: b) { v in update("Edit Distance") { $0.extent = .twoSides(d, back: v) } } }
            }
            Picker("Operation", selection: Binding(get: { extrude.operation },
                                                   set: { op in update("Change Operation") { $0.operation = op } })) {
                ForEach(BodyOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Flip direction", isOn: Binding(get: { extrude.flipped },
                                                   set: { v in update("Flip") { $0.flipped = v } }))
            if let face = extrude.face {
                LabeledContent("Face", value: face.face)
            } else {
                LabeledContent("Profiles", value: "\(extrude.profiles.count)")
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

    var body: some View {
        Section(fillet ? "Fillet" : "Chamfer") {
            LabeledContent(fillet ? "Radius" : "Distance") {
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
            if model.previewInvalid, model.dragHandle?.featureID == id {
                Label("Too large for the neighbouring faces", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Text("Or drag the orange arrow in the viewport.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Edges (\(edges.edges.count))") {
            ForEach(Array(edges.edges.enumerated()), id: \.offset) { i, e in
                HStack {
                    Text(e.edge).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button { update("Remove Edge") { $0.edges.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(edges.edges.count == 1)
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
            LabeledContent("Profiles", value: "\(revolve.profiles.count) in \(model.featureName(revolve.sketch))")
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
            LabeledContent("Profiles", value: "\(sweep.profiles.count) in \(model.featureName(sweep.sketch))")
            PathSection(model: model, path: sweep.path) { p in edit.update("Change Path") { $0.path = p } }
            edit.operation(sweep.operation) { $0.operation = $1 }
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

struct PrimitiveInspector: View {
    let model: DocumentModel
    let id: FeatureID
    let primitive: PrimitiveFeature

    var edit: FeatureEdit<PrimitiveFeature> {
        FeatureEdit(model: model, id: id, get: { if case .primitive(let p) = $0 { p } else { nil } }, wrap: { .primitive($0) })
    }

    var planeName: String {
        switch primitive.plane {
        case .xy: return "XY plane"
        case .xz: return "XZ plane"
        case .yz: return "YZ plane"
        case .face(let f): return f.face
        }
    }

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
            Picker("Arrow along", selection: Binding(get: { move.arrow }, set: { a in edit.update("Change Axis") { $0.arrow = a } })) {
                ForEach(Axis3.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if !move.bodies.isEmpty { BodiesRow(model: model, ids: move.bodies) }
            if !move.sketches.isEmpty {
                let names = move.sketches.map { id in model.document.features.first { $0.id == id }?.name ?? "missing" }
                LabeledContent(names.count == 1 ? "Sketch" : "Sketches", value: names.joined(separator: ", "))
            }
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

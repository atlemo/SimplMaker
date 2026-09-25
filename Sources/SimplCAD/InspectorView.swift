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
                }
                Section {
                    Button("Delete Feature", role: .destructive) { model.deleteFeature(id) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(feature.name)
        } else {
            ContentUnavailableView("No Feature Selected", systemImage: "cursorarrow.click",
                                   description: Text("Select a feature in the timeline to edit it. Select edges in the viewport, then use Fillet or Chamfer."))
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

    var body: some View {
        Section("Sketch") {
            LabeledContent("Plane", value: planeName)
            if let solve = model.result?.sketches[id]?.solve {
                LabeledContent("Status", value: solve.status == .solved
                               ? (solve.degreesOfFreedom == 0 ? "Fully constrained" : "\(solve.degreesOfFreedom) degrees of freedom")
                               : "Over-constrained")
            }
            LabeledContent("Curves", value: "\(sketch.sketch.curves.count)")
            LabeledContent("Constraints", value: "\(sketch.sketch.constraints.count)")
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

    var body: some View {
        Section("Extrude") {
            switch extrude.extent {
            case .distance(let d):
                LabeledContent("Distance") { ExpressionField(text: d) { v in update("Edit Distance") { $0.extent = .distance(v) } } }
            case .symmetric(let d):
                LabeledContent("Total") { ExpressionField(text: d) { v in update("Edit Distance") { $0.extent = .symmetric(v) } } }
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
            LabeledContent("Profiles", value: "\(extrude.profiles.count)")
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
                ExpressionField(text: edges.size) { v in update(fillet ? "Edit Radius" : "Edit Distance") { $0.size = v } }
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

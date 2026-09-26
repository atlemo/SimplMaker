// What the viewport offers for the thing under the cursor: the right-click menu, double-click to
// edit, and the small options panel shown next to a feature's drag handle.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

/// One entry of the viewport's right-click menu.
enum ContextItem {
    case action(String, symbol: String? = nil, enabled: Bool = true, @MainActor () -> Void)
    case submenu(String, [ContextItem])
    case separator

    var title: String? {
        switch self {
        case .action(let t, _, _, _), .submenu(let t, _): return t
        case .separator: return nil
        }
    }
}

extension DocumentModel {
    // MARK: right-click menu

    /// The right-click menu for what's under the cursor. `ray` is the click's pointer ray, for
    /// placing things where the user clicked.
    func contextItems(for pick: PickID?, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)? = nil) -> [ContextItem] {
        if let tool = pendingTool {
            return [.action("Cancel \(tool.rawValue)", symbol: "xmark.circle") { self.cancelTool() }]
        }
        if let session = sketchSession { return sketchItems(session) }
        guard let pick else { return backgroundItems() }
        switch pick.kind {
        case .face: return faceItems(pick, ray: ray)
        case .edge: return edgeItems(pick)
        case .region: return profileItems(pick)
        case .sketchCurve: return curveItems(pick)
        default: return backgroundItems()
        }
    }

    private func faceItems(_ pick: PickID, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)?) -> [ContextItem] {
        guard let ref = faceRef(pick) else { return backgroundItems() }
        let flat = (try? result?.body(ref.body)?.faceFrame(ref.face)) != nil
        var items: [ContextItem] = [
            .action("Sketch on Face", symbol: "pencil.and.outline", enabled: flat) { self.beginSketch(on: .face(ref)) },
            .action("Extrude Face", symbol: DesignTool.extrude.symbol, enabled: flat) {
                self.selection = [pick]
                self.run(.extrude)
            },
            .action("Hole Here", symbol: DesignTool.hole.symbol, enabled: flat) {
                self.clickRay = ray
                self.place(.hole, on: pick)
            },
        ]
        items += ownerItems(featureMaking(face: ref.face), body: ref.body)
        return items
    }

    private func edgeItems(_ pick: PickID) -> [ContextItem] {
        // Keep a multi-edge selection that includes this edge; otherwise act on this edge alone.
        let pickEdge = { if !self.selection.contains(pick) { self.selection = [pick] } }
        var items: [ContextItem] = [
            .action("Fillet", symbol: DesignTool.fillet.symbol) { pickEdge(); self.run(.fillet) },
            .action("Chamfer", symbol: DesignTool.chamfer.symbol) { pickEdge(); self.run(.chamfer) },
        ]
        if let body = meshes[safe: pick.body]?.id { items += ownerItems(nil, body: body) }
        return items
    }

    private func profileItems(_ pick: PickID) -> [ContextItem] {
        guard let p = profile(of: pick) else { return backgroundItems() }
        let pickProfile = { if !self.selection.contains(pick) { self.selection = [pick] } }
        var items: [ContextItem] = ([.extrude, .revolve, .sweep, .loft] as [DesignTool]).map { tool in
            .action(tool.rawValue, symbol: tool.symbol) { pickProfile(); self.run(tool) }
        }
        items += sketchOwnerItems(p.sketch)
        return items
    }

    private func curveItems(_ pick: PickID) -> [ContextItem] {
        guard let c = curve(of: pick) else { return backgroundItems() }
        let pickCurve = { if !self.selection.contains(pick) { self.selection = [pick] } }
        var items: [ContextItem] = ([.pipe, .rib] as [DesignTool]).map { tool in
            .action(tool == .pipe ? "Pipe Along" : "Rib", symbol: tool.symbol) { pickCurve(); self.run(tool) }
        }
        items += sketchOwnerItems(c.sketch)
        return items
    }

    private func sketchOwnerItems(_ sketch: FeatureID) -> [ContextItem] {
        [.separator,
         .action("Edit \(featureName(sketch))", symbol: "pencil") { self.editSketch(sketch) },
         .action("Hide \(featureName(sketch))", symbol: "eye.slash") { self.setHidden([sketch], true) }]
    }

    /// "Edit Extrude1" for the feature that made a face, and "Hide Body1".
    private func ownerItems(_ feature: FeatureID?, body: FeatureID) -> [ContextItem] {
        var items: [ContextItem] = [.separator]
        if let feature { items.append(.action("Edit \(featureName(feature))", symbol: "pencil") { self.editFeature(feature) }) }
        let bodyName = bodies.first { $0.id == body }?.name ?? "Body"
        items.append(.action("Hide \(bodyName)", symbol: "eye.slash") { self.setHidden([body], true) })
        return items
    }

    private func backgroundItems() -> [ContextItem] {
        var items: [ContextItem] = [
            .action("New Sketch…", symbol: "pencil.and.outline") { self.startSketch() },
            .submenu("Add Shape", DesignTool.primitives.map { tool in .action(tool.rawValue, symbol: tool.symbol) { self.run(tool) } }),
            .separator,
            .action("Fit All", symbol: "arrow.up.left.and.arrow.down.right") { self.fitView() },
            .submenu("Standard Views", StandardView.allCases.map { v in .action(v.title) { self.show(v) } }),
        ]
        if !document.hidden.isEmpty {
            items.append(.action("Show All", symbol: "eye") { self.setHidden(Array(self.document.hidden), false) })
        }
        return items
    }

    private func sketchItems(_ session: SketchSession) -> [ContextItem] {
        var items: [ContextItem] = [.action("Finish Sketch", symbol: "checkmark.circle") { self.finishSketch() }, .separator]
        if !session.selection.isEmpty {
            let constraints = ConstraintTool.allCases.filter { session.canApply($0) }
            if !constraints.isEmpty {
                items.append(.submenu("Constrain", constraints.map { c in .action(c.rawValue) { self.sketchCommand { $0.apply(c) } } }))
            }
            if session.canToggleConstruction {
                items.append(.action("Construction", symbol: "pencil.slash") { self.sketchCommand { $0.toggleConstruction() } })
            }
            items.append(.action("Delete", symbol: "trash") { self.sketchCommand { $0.deleteSelection() } })
            items.append(.separator)
        }
        items += ([.select] + SketchTool.draw + [.dimension]).map { tool in
            .action(tool.rawValue, symbol: tool.symbol, enabled: session.tool != tool) { self.setSketchTool(tool) }
        }
        return items
    }

    // MARK: editing a feature from the viewport

    /// The feature a face's persistent name says made it ("plate.end" → "plate", "h.hole.wall" → "h").
    func featureMaking(face name: String) -> FeatureID? {
        guard let prefix = name.split(separator: ".").first.map(String.init),
              document.features.contains(where: { $0.id == prefix }) else { return nil }
        return prefix
    }

    /// Opens a feature for editing: a sketch goes into sketch mode; anything else is selected with
    /// its drag handle and size field ready for typing.
    func editFeature(_ id: FeatureID) {
        guard let f = document.features.first(where: { $0.id == id }) else { return }
        if case .sketch = f.kind { editSketch(id); return }
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        selection = []
        selectedFeature = id
        showInspector = true
        handleFocusRequest += 1
    }

    /// Double-click in the viewport: edit the feature that made the face, or the sketch of a curve or profile.
    func doubleClick(_ pick: PickID?) {
        guard sketchSession == nil, pendingTool == nil, let pick else { return }
        switch pick.kind {
        case .face:
            if let ref = faceRef(pick), let owner = featureMaking(face: ref.face) { editFeature(owner) }
        case .region:
            if let p = profile(of: pick) { editSketch(p.sketch) }
        case .sketchCurve:
            if let c = curve(of: pick) { editSketch(c.sketch) }
        default:
            break
        }
    }

    // MARK: the options panel next to the handle

    /// Join / Cut / New Body / Intersect of a feature, if it has one.
    func operation(of id: FeatureID) -> BodyOperation? {
        switch document.features.first(where: { $0.id == id })?.kind {
        case .extrude(let e)?: return e.operation
        case .revolve(let r)?: return r.operation
        case .sweep(let s)?: return s.operation
        case .loft(let l)?: return l.operation
        case .primitive(let p)?: return p.operation
        case .pipe(let p)?: return p.operation
        default: return nil
        }
    }

    func setOperation(_ op: BodyOperation, of id: FeatureID) {
        guard operation(of: id) != op else { return }
        updateFeature(id, "Change Operation") { f in
            switch f.kind {
            case .extrude(var e): e.operation = op; f.kind = .extrude(e)
            case .revolve(var r): r.operation = op; f.kind = .revolve(r)
            case .sweep(var s): s.operation = op; f.kind = .sweep(s)
            case .loft(var l): l.operation = op; f.kind = .loft(l)
            case .primitive(var p): p.operation = op; f.kind = .primitive(p)
            case .pipe(var p): p.operation = op; f.kind = .pipe(p)
            default: break
            }
        }
    }

    /// Whether an extrude goes against its sketch's (or face's) normal; nil for other features.
    func isFlipped(_ id: FeatureID) -> Bool? {
        if case .extrude(let e)? = document.features.first(where: { $0.id == id })?.kind { return e.flipped }
        return nil
    }

    func toggleFlip(_ id: FeatureID) {
        updateFeature(id, "Flip") { f in
            if case .extrude(var e) = f.kind { e.flipped.toggle(); f.kind = .extrude(e) }
        }
    }

    /// Cancel on a feature that was just created: take it out again (and show its sketches again).
    func cancelNewFeature() {
        guard let id = newFeature, let before = documentBeforeNewFeature else { return finishFeatureEdit() }
        let name = featureName(id)
        mutate("Cancel \(name)") { doc in
            doc.features.removeAll { $0.id == id }
            doc.hidden = before.hidden
        }
        newFeature = nil
        selectedFeature = nil
        selection = []
    }
}

import SwiftUI

/// The options panel under a feature's size field: how it combines with the body, flip, and
/// OK / Cancel — the choices that matter while sizing it, next to where you're looking.
struct FeatureHUD: View {
    let model: DocumentModel

    var body: some View {
        if let id = model.dragHandle?.featureID {
            HStack(spacing: DS.Spacing.space3) {
                if let op = model.operation(of: id) {
                    Picker("Operation", selection: Binding(get: { op }, set: { model.setOperation($0, of: id) })) {
                        ForEach(BodyOperation.allCases, id: \.self) { o in
                            Text(o == .newBody ? "New" : o.rawValue).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Join adds to the body, Cut removes from it, New makes a separate body, Intersect keeps the overlap")
                }
                if let flipped = model.isFlipped(id) {
                    Toggle(isOn: Binding(get: { flipped }, set: { _ in model.toggleFlip(id) })) {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .toggleStyle(.button)
                    .help("Flip the direction")
                }
                if model.newFeature == id {
                    Button("Cancel") { model.cancelNewFeature() }
                        .help("Remove this new feature (Esc in the field only undoes the typing)")
                }
                // No default-button shortcut: it would take Return from the size field before the
                // field could store what was typed. Return in the field already means OK.
                Button("OK") { model.finishFeatureEdit() }
                    .help("Done (Return)")
            }
            .controlSize(.small)
            .padding(DS.Spacing.space3)
            .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.xl2))
            .fixedSize()
        }
    }
}

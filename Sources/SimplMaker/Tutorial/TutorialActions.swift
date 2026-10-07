// "Do it for me": each tutorial step done through the same calls the interface makes, so what it
// leaves behind is what the user would have made (and undo, the timeline and the browser all agree).
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import simd

@MainActor
enum TutorialActions {
    // MARK: waiting for the kernel

    /// Waits until the model has been rebuilt for the latest change.
    static func settle(_ model: DocumentModel) async {
        try? await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: parameters

    /// Adds the tutorial's parameters that the part doesn't have yet.
    static func seedParameters(_ model: DocumentModel) {
        let missing = TutorialPart.parameters.filter { p in !model.document.parameters.contains { $0.name == p.name } }
        guard !missing.isEmpty else { return }
        model.mutate("Add Tutorial Parameters") { $0.parameters += missing }
    }

    // MARK: sketches

    /// A sketch on the floor, replacing one begun on another plane.
    static func startBaseSketch(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        if let wrong = facts.misplacedSketch {
            model.finishSketch()
            model.deleteFeature(wrong.id)
            await settle(model)
        }
        if let session = model.sketchSession, TutorialFacts(model).baseSketch?.id == session.featureID { return }
        model.cancelTool()
        model.selectedFeature = nil
        model.clearSelection()
        model.startSketch()
        model.click(OriginPlane.xy.pickID, additive: false)
        await settle(model)
    }

    /// A sketch on the leaning plane, replacing one begun somewhere else.
    static func startBackSketch(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        guard let plane = facts.plane else { return }
        if let wrong = facts.misplacedBackSketch {
            if model.sketchSession != nil { model.finishSketch() }
            model.deleteFeature(wrong.id)
            await settle(model)
        }
        if let session = model.sketchSession, TutorialFacts(model).backSketch?.id == session.featureID { return }
        if model.sketchSession != nil { model.finishSketch() }
        model.cancelTool()
        model.cancelSketchPlanePick()
        model.clearSelection()
        model.beginSketch(on: .plane(plane.id))
        await settle(model)
    }

    /// A mouse event in the sketch; picking waits for the move before a click.
    private static func mouse(_ model: DocumentModel, _ phases: [SketchMouse.Phase], _ uv: SIMD2<Double>) {
        for phase in phases { _ = model.sketchMouse(SketchMouse(phase: phase, uv: uv, pick: nil)) }
    }

    /// A rectangle in a sketch, drawn like a user would: the rectangle tool, a click on the origin, the mouse moved
    /// the way it should grow, then the two sizes typed. Anything already drawn in the sketch goes.
    static func drawRectangle(in sketchID: FeatureID, across: String, along: String, growing: TutorialFacts.Growth,
                              _ model: DocumentModel) async {
        if model.sketchSession?.featureID != sketchID {
            model.cancelTool()
            model.editSketch(sketchID)
            await settle(model)
        }
        guard let session = model.sketchSession, session.featureID == sketchID else { return }
        if !session.sketch.curves.isEmpty {
            model.mutate("Clear Sketch") { doc in
                guard let i = doc.index(of: sketchID), case .sketch(var sf) = doc.features[i].kind else { return }
                sf.sketch = Sketch()
                doc.features[i].kind = .sketch(sf)
            }
            await settle(model)
        }
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], .zero)
        mouse(model, [.moved], SIMD2(1, growing == .rightDown ? -1 : 1))
        session.setTyped(.width, across)
        session.setTyped(.height, along)
        model.commitSketchTyped()
        await settle(model)
    }

    // MARK: picking things the way a click would

    /// The pick for a region of a sketch (the rectangle's inside).
    static func profilePick(of sketchID: FeatureID, _ model: DocumentModel) -> PickID? {
        guard let slot = model.sketchSlots.firstIndex(of: sketchID).map({ $0 + 1 }),
              let regions = model.result?.sketches[sketchID]?.regions else { return nil }
        return regions.indices.map { PickID(region: $0, slot: slot) }.first { model.profile(of: $0) != nil }
    }

    /// Starts a tool the way its button does, from a clean slate.
    private static func startTool(_ tool: DesignTool, _ model: DocumentModel) {
        model.cancelTool()
        model.run(tool)
    }

    // MARK: features

    /// Extrudes the profile of a sketch and sizes it (a join, when there already is a body).
    static func extrude(_ sketchID: FeatureID, size: String, _ model: DocumentModel) async {
        if model.sketchSession != nil { model.finishSketch(); await settle(model) }
        startTool(.extrude, model)
        guard let pick = profilePick(of: sketchID, model) else { return }
        model.click(pick, additive: false)
        await settle(model)
        guard let id = model.selectedFeature else { return }
        model.commitHandle(size, for: id)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// A construction plane on the floor, with its offset left as it comes.
    static func makePlane(_ model: DocumentModel) async {
        if let plane = TutorialFacts(model).plane {
            if model.newFeature == plane.id { model.finishFeatureEdit() }
            return
        }
        startTool(.plane, model)
        model.click(OriginPlane.xy.pickID, additive: false)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// The plane's angle set to `lean`, as typing it in the inspector does.
    static func tiltPlane(_ model: DocumentModel) async {
        if TutorialFacts(model).plane == nil { await makePlane(model) }
        guard let plane = TutorialFacts(model).plane else { return }
        if model.newFeature == plane.id { model.finishFeatureEdit() }
        model.updateFeature(plane.id, "Edit Angle") { f in
            if case .plane(var p) = f.kind { p.angle = "lean"; f.kind = .plane(p) }
        }
        await settle(model)
    }

    /// `width` set wide enough for a tablet.
    static func widen(_ model: DocumentModel) async {
        model.setParameter("width", expression: TutorialPart.tabletWidth)
        await settle(model)
    }
}

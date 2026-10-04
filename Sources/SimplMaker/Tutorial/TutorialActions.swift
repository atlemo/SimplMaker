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
    static func startBoxSketch(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        if let wrong = facts.misplacedSketch {
            model.finishSketch()
            model.deleteFeature(wrong.id)
            await settle(model)
        }
        if let session = model.sketchSession, TutorialFacts(model).boxSketch?.id == session.featureID { return }
        model.cancelTool()
        model.selectedFeature = nil
        model.clearSelection()
        model.startSketch()
        model.click(OriginPlane.xy.pickID, additive: false)
        await settle(model)
    }

    /// A sketch on the lid's plane.
    static func startLidSketch(_ model: DocumentModel) async {
        guard let plane = TutorialFacts(model).plane else { return }
        if model.sketchSession != nil { model.finishSketch() }
        model.cancelTool()
        model.cancelSketchPlanePick()
        model.clearSelection()
        model.beginSketch(on: .plane(plane.id))
        await settle(model)
    }

    private static func click(_ model: DocumentModel, _ uv: SIMD2<Double>) {
        for phase in [SketchMouse.Phase.moved, .down, .up] {
            _ = model.sketchMouse(SketchMouse(phase: phase, uv: uv, pick: nil))
        }
    }

    /// The tutorial's rectangle in a sketch, drawn like a user would: the center rectangle tool, a click on
    /// the origin, then `width` and `depth` typed. Anything already drawn in the sketch goes.
    static func drawRectangle(in sketchID: FeatureID, _ model: DocumentModel) async {
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
        model.setSketchTool(.centerRectangle)
        click(model, .zero)
        session.setTyped(.width, "width")
        session.setTyped(.height, "depth")
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

    /// The pick for a face of a body, by its persistent name.
    static func facePick(_ ref: FaceRef, _ model: DocumentModel) -> PickID? {
        guard let body = model.meshes.firstIndex(where: { $0.id == ref.body }),
              let face = model.meshes[body].mesh.faceNames.firstIndex(of: ref.face) else { return nil }
        return PickID(body: body, face: face)
    }

    /// Starts a tool the way its button does, from a clean slate.
    private static func startTool(_ tool: DesignTool, _ model: DocumentModel) {
        model.cancelTool()
        model.run(tool)
    }

    // MARK: features

    /// Extrudes the profile of a sketch, sizes it, and (for the lid) makes it a body of its own.
    static func extrude(_ sketchID: FeatureID, size: String, newBody: Bool, _ model: DocumentModel) async {
        if model.sketchSession != nil { model.finishSketch(); await settle(model) }
        startTool(.extrude, model)
        guard let pick = profilePick(of: sketchID, model) else { return }
        model.click(pick, additive: false)
        await settle(model)
        guard let id = model.selectedFeature else { return }
        if newBody {
            model.updateFeature(id, "Change Operation") { f in
                if case .extrude(var e) = f.kind { e.operation = .newBody; f.kind = .extrude(e) }
            }
            await settle(model)
        }
        model.commitHandle(size, for: id)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// Hollows the box through its top face, `wall` thick.
    static func shell(_ model: DocumentModel) async {
        guard let top = TutorialFacts(model).boxTopFace, let pick = facePick(top, model) else { return }
        startTool(.shell, model)
        model.click(pick, additive: false)
        model.confirmTool()
        await settle(model)
        guard let shell = TutorialFacts(model).shell else { return }
        model.commitHandle("wall", for: shell.id)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// A construction plane on the floor, lifted by `height`.
    static func plane(_ model: DocumentModel) async {
        startTool(.plane, model)
        model.click(OriginPlane.xy.pickID, additive: false)
        await settle(model)
        guard let plane = TutorialFacts(model).plane else { return }
        model.commitHandle("height", for: plane.id)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// Rounds every edge around the lid's top face, `wall` in radius.
    static func fillet(_ model: DocumentModel) async {
        guard let top = TutorialFacts(model).lidTopFace, let pick = facePick(top, model) else { return }
        startTool(.fillet, model)
        model.click(pick, additive: false)
        model.confirmTool()
        await settle(model)
        guard let fillet = TutorialFacts(model).lidFillet else { return }
        model.commitHandle("wall", for: fillet.id)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// A hole in the middle of the lid's top face.
    static func hole(_ model: DocumentModel) async {
        guard let top = TutorialFacts(model).lidTopFace, let pick = facePick(top, model) else { return }
        startTool(.hole, model)
        model.clickRay = nil
        model.click(pick, additive: false)
        await settle(model)
    }

    /// A thread in the hole: a click on the top face a few millimetres from the hole's axis.
    static func thread(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        guard let top = facts.lidTopFace, let pick = facePick(top, model),
              let body = model.result?.body(top.body), let frame = try? body.faceFrame(top.face) else { return }
        startTool(.thread, model)
        let hit = frame.point(3, 0)
        model.clickRay = (origin: hit + frame.normal * 10, direction: -frame.normal)
        model.click(pick, additive: false)
        await settle(model)
    }

    /// `width` set to 80 mm.
    static func widen(_ model: DocumentModel) async {
        model.setParameter("width", expression: "80 mm")
        await settle(model)
    }
}

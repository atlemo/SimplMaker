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
        await model.rebuilt()
    }

    // MARK: parameters

    /// Adds the tutorial's parameters that the part doesn't have yet.
    static func seedParameters(_ model: DocumentModel) {
        let missing = TutorialPart.parameters.filter { p in !model.document.parameters.contains { $0.name == p.name } }
        guard !missing.isEmpty else { return }
        model.mutate("Add Tutorial Parameters") { $0.parameters += missing }
    }

    // MARK: the floor's sketch

    /// A sketch on the floor plane, replacing one begun on another plane.
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

    /// A mouse event in the sketch; picking waits for the move before a click.
    private static func mouse(_ model: DocumentModel, _ phases: [SketchMouse.Phase], _ uv: SIMD2<Double>) {
        for phase in phases { _ = model.sketchMouse(SketchMouse(phase: phase, uv: uv, pick: nil)) }
    }

    /// The floor's rectangle, drawn like a user would: the rectangle tool, a click on the origin, the mouse moved up
    /// and to the right, then the two sizes typed. Anything already drawn in the sketch goes.
    static func drawBaseRectangle(in sketchID: FeatureID, _ model: DocumentModel) async {
        if model.sketchSession?.featureID != sketchID {
            model.cancelTool()
            model.editSketch(sketchID)
            await settle(model)
        }
        guard let session = model.sketchSession, session.featureID == sketchID else { return }
        await clearSketch(sketchID, if: !session.sketch.curves.isEmpty, model)
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], .zero)
        mouse(model, [.moved], SIMD2(12, 12))
        session.setTyped(.width, "width")
        session.setTyped(.height, "depth")
        model.commitSketchTyped()
        await settle(model)
    }

    private static func clearSketch(_ sketchID: FeatureID, if condition: Bool, _ model: DocumentModel) async {
        guard condition else { return }
        model.mutate("Clear Sketch") { doc in
            guard let i = doc.index(of: sketchID), case .sketch(var sf) = doc.features[i].kind else { return }
            sf.sketch = Sketch()
            doc.features[i].kind = .sketch(sf)
        }
        await settle(model)
    }

    // MARK: the walls' sketch

    private static let floorTop = { (floor: FeatureID) in FaceRef(body: floor, face: "\(floor).end") }

    /// A sketch on top of the floor, replacing one begun somewhere else.
    static func startWallSketch(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        guard let floor = facts.baseExtrude else { return }
        if let wrong = facts.misplacedWallSketch {
            if model.sketchSession != nil { model.finishSketch() }
            model.deleteFeature(wrong.id)
            await settle(model)
        }
        if let session = model.sketchSession, TutorialFacts(model).wallSketch?.id == session.featureID { return }
        if model.sketchSession != nil { model.finishSketch() }
        model.cancelTool()
        model.cancelSketchPlanePick()
        model.clearSelection()
        model.beginSketch(on: .face(floorTop(floor.id)))
        await settle(model)
    }

    /// The walls' sketch, open for drawing.
    private static func openWallSketch(_ model: DocumentModel) async -> SketchSession? {
        guard let sketch = TutorialFacts(model).wallSketch else { return nil }
        if model.sketchSession?.featureID != sketch.id {
            model.cancelTool()
            model.editSketch(sketch.id)
            await settle(model)
        }
        guard let session = model.sketchSession, session.featureID == sketch.id else { return nil }
        return session
    }

    /// The floor's outline: the rectangle tool and a click on two opposite corners of the floor, which the sketch then follows.
    static func traceOutline(_ model: DocumentModel) async {
        guard let session = await openWallSketch(model), let layout = TutorialFacts(model).layout,
              let sketch = TutorialFacts(model).wallSketch else { return }
        await clearSketch(sketch.id, if: !session.sketch.curves.isEmpty, model)
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], layout.outline.min)
        mouse(model, [.moved, .down, .up], layout.outline.max)
        await settle(model)
    }

    /// The outline offset inwards by `wall`, as typing it in the Offset field does.
    static func insetOutline(_ model: DocumentModel) async {
        guard let session = await openWallSketch(model), let walls = TutorialFacts(model).walls,
              let outline = walls.match(walls.layout.outline, in: walls.solid) else { return }
        model.setSketchTool(.select)
        if !session.isOffsetting {
            // An inset that went the wrong way, or by a plain number, goes first.
            if let wrong = walls.wrongGuide {
                session.selection = wrong.lines
                model.sketchCommand { $0.deleteSelection() }
                await settle(model)
            }
            session.selection = outline.lines
            model.beginSketchOffset()
        }
        session.setTyped(.offsetDistance, "-wall")
        model.commitSketchTyped()
        await settle(model)
    }

    /// The inset turned into construction lines.
    static func makeGuide(_ model: DocumentModel) async {
        guard let session = await openWallSketch(model), let walls = TutorialFacts(model).walls,
              let guide = walls.guideBox, !guide.isConstruction else { return }
        model.setSketchTool(.select)
        session.selection = guide.lines
        model.sketchCommand { $0.toggleConstruction() }
        await settle(model)
    }

    /// A rectangle for a section: a click on a corner of the guide, the mouse moved the way it grows, then what is typed.
    /// A size left out comes from where the mouse was. A rectangle already there for the section, and any drawn
    /// where no section goes, are taken out first.
    static func drawSection(replacing rect: TutorialFacts.Layout.Rect, from corner: SIMD2<Double>, toward direction: SIMD2<Double>,
                            width: String?, height: String?, _ model: DocumentModel) async {
        guard let session = await openWallSketch(model) else { return }
        if let walls = TutorialFacts(model).walls {
            let stale = (walls.match(rect, in: walls.solid).map { [$0] } ?? []) + walls.strays
            let lines = stale.flatMap(\.lines)
            if !lines.isEmpty {
                session.selection = lines
                model.sketchCommand { $0.deleteSelection() }
                await settle(model)
            }
        }
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], corner)
        mouse(model, [.moved], corner + direction)
        if let width { session.setTyped(.width, width) }
        if let height { session.setTyped(.height, height) }
        model.commitSketchTyped()
        await settle(model)
    }

    static func frontSection(_ model: DocumentModel) async {
        guard let layout = TutorialFacts(model).layout else { return }
        await drawSection(replacing: layout.frontSection, from: layout.guide.min, toward: SIMD2(12, 12),
                          width: "width - 2 * wall", height: "front", model)
    }

    static func backLeftSection(_ model: DocumentModel) async {
        guard let layout = TutorialFacts(model).layout else { return }
        await drawSection(replacing: layout.backLeft, from: SIMD2(layout.guide.min.x, layout.guide.max.y), toward: SIMD2(12, -12),
                          width: "(width - 3 * wall) / 2", height: "depth - 3 * wall - front", model)
    }

    static func backRightSection(_ model: DocumentModel) async {
        guard let layout = TutorialFacts(model).layout else { return }
        await drawSection(replacing: layout.backRight, from: layout.guide.max, toward: SIMD2(-12, -10),
                          width: "(width - 3 * wall) / 2", height: "depth - 3 * wall - front", model)
    }

    // MARK: picking things the way a click would

    /// The pick for a region of a sketch: one with all the curves given among its boundaries (the wall is the region
    /// bounded by the outline), else the first there is.
    static func profilePick(of sketchID: FeatureID, containing curves: [EntityID] = [], _ model: DocumentModel) -> PickID? {
        guard let slot = model.sketchSlots.firstIndex(of: sketchID).map({ $0 + 1 }),
              let regions = model.result?.sketches[sketchID]?.regions else { return nil }
        let wanted = Set(curves)
        return regions
            .filter { wanted.isEmpty || Set($0.tags.split(separator: ",").map(String.init)).isSuperset(of: wanted) }
            .map { PickID(region: $0.index, slot: slot) }
            .first { model.profile(of: $0) != nil }
    }

    /// Starts a tool the way its button does, from a clean slate.
    private static func startTool(_ tool: DesignTool, _ model: DocumentModel) {
        model.cancelTool()
        model.run(tool)
    }

    // MARK: features

    /// Extrudes the profile of a sketch and sizes it (a join, when there already is a body). `containing` picks the
    /// profile bounded by those curves.
    static func extrude(_ sketchID: FeatureID, size: String, containing curves: [EntityID] = [], _ model: DocumentModel) async {
        if model.sketchSession != nil { model.finishSketch(); await settle(model) }
        startTool(.extrude, model)
        guard let pick = profilePick(of: sketchID, containing: curves, model) else { return }
        model.click(pick, additive: false)
        await settle(model)
        guard let id = model.selectedFeature else { return }
        model.commitHandle(size, for: id)
        await settle(model)
        model.finishFeatureEdit()
    }

    /// The walls: the region round and between the sections, raised by `height`.
    static func extrudeWalls(_ model: DocumentModel) async {
        var facts = TutorialFacts(model)
        guard let sketch = facts.wallSketch else { return }
        // The whole top of the floor pulled up goes.
        if let pulled = facts.facePull {
            model.finishFeatureEdit()
            model.deleteFeature(pulled.id)
            await settle(model)
            facts = TutorialFacts(model)
        }
        if let ex = facts.wallExtrude, facts.extrudesTheWall(ex.value) {
            // The right region is raised: the size, and the join, are what is left to put right.
            if ex.value.operation == .newBody {
                model.updateFeature(ex.id, "Change Operation") { f in
                    if case .extrude(var e) = f.kind { e.operation = .join; f.kind = .extrude(e) }
                }
                await settle(model)
            }
            model.commitHandle("height", for: ex.id)
            await settle(model)
            model.finishFeatureEdit()
            return
        }
        // Nothing yet, or a section was filled in: that goes, and the wall is raised instead.
        if let wrong = facts.wallExtrude {
            model.finishFeatureEdit()
            model.deleteFeature(wrong.id)
            await settle(model)
        }
        let outline = TutorialFacts(model).walls.flatMap { $0.match($0.layout.outline, in: $0.solid) }?.lines ?? []
        await extrude(sketch.id, size: "height", containing: outline, model)
    }

    /// `width` and `depth` set to the bigger organizer's.
    static func resize(_ model: DocumentModel) async {
        for change in TutorialPart.resized { model.setParameter(change.name, expression: change.expression) }
        await settle(model)
    }
}

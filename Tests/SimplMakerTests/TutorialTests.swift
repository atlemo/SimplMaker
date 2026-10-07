// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The guided first part (a desk organizer): its steps, how each knows it is done, and "Do it for me" for all of them.
@Suite @MainActor struct TutorialTests {
    private func settle(_ model: DocumentModel) async { await TutorialActions.settle(model) }

    /// Runs the tutorial to the end the way the card does: a step's `enter`, then its button or "Do it for me".
    /// Returns the ids of the steps it went through, in order.
    @discardableResult
    private func run(_ guide: TutorialGuide, _ model: DocumentModel, until stop: String? = nil) async -> [String] {
        var seen: [String] = []
        for _ in 0..<60 {
            guard let step = guide.current(in: model) else { break }
            if step.id == stop { break }
            seen.append(step.id)
            // Without a run loop turning, a step's changes would all land in one undo group: make each step its own.
            let grouping = model.undoManager.map { !$0.groupsByEvent } ?? false
            if grouping { model.undoManager?.beginUndoGrouping() }
            defer { if grouping { model.undoManager?.endUndoGrouping() } }
            step.enter?(model)
            await settle(model)
            switch step.kind {
            case .read: guide.acknowledge(step)
            case .task: await guide.assist(step, in: model)
            }
            await settle(model)
            #expect(guide.current(in: model)?.id != step.id, "\(step.id) is still showing after it was done for the user")
            // A step that was done stays done while later ones are worked on, or the card would jump back to it.
            for earlier in seen.dropLast() {
                if let e = TutorialScript.step(earlier) { #expect(guide.isDone(e, in: model), "\(earlier) came undone during \(step.id)") }
            }
            if guide.current(in: model)?.id == step.id { break }
        }
        return seen
    }

    /// A model that can undo each step on its own, ready for a run.
    private func undoableModel() async -> DocumentModel {
        let model = DocumentModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        await settle(model)
        return model
    }

    private func mouse(_ model: DocumentModel, _ phases: [SketchMouse.Phase], _ uv: SIMD2<Double>) {
        for phase in phases { _ = model.sketchMouse(SketchMouse(phase: phase, uv: uv, pick: nil)) }
    }

    // MARK: the script

    @Test func scriptHasNineteenWellFormedSteps() {
        let steps = TutorialScript.steps
        #expect(steps.count == 19)
        #expect(Set(steps.map(\.id)).count == steps.count, "ids are unique")
        #expect(steps.map(\.chapter.rawValue) == steps.map(\.chapter.rawValue).sorted(), "chapters run in order")
        for step in steps where step.isTask { #expect(step.assist != nil, "\(step.id) can't be done for the user") }
        for step in steps { #expect(!step.title.isEmpty && !step.text.isEmpty) }
        #expect(steps.first?.id == "welcome" && steps.last?.id == "done")
        #expect(TutorialScript.welcome.text.count < 160, "the first card says little: \(TutorialScript.welcome.text.count) characters")
    }

    @Test func aFreshPartStartsAtTheWelcome() {
        let model = DocumentModel()
        let guide = TutorialGuide(active: true)
        #expect(guide.current(in: model)?.id == "welcome")
        #expect(guide.canResume == false)
    }

    @Test func readStepsNeedTheButtonAndTaskStepsNeedThePart() {
        let model = DocumentModel()
        let guide = TutorialGuide(active: true)
        guide.acknowledge(TutorialScript.welcome)
        guide.acknowledge(TutorialScript.look)
        guide.acknowledge(TutorialScript.parameters)
        #expect(guide.current(in: model)?.id == "sketch-plane", "nothing is drawn yet")
        #expect(guide.canResume == false || guide.isActive)
    }

    // MARK: doing everything for the user

    @Test func doItForMeBuildsTheWholeOrganizerAndResizesIt() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        let seen = await run(guide, model)

        #expect(seen == TutorialScript.steps.map(\.id), "every step came up once, in order: \(seen)")
        #expect(guide.isFinished && !guide.isActive)
        #expect(guide.current(in: model) == nil || guide.isFinished)

        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 1, "one body, the organizer: \(r.bodies.map(\.id))")
        let facts = TutorialFacts(model)
        let floor = try #require(facts.baseExtrude), walls = try #require(facts.wallExtrude)
        #expect(walls.value.operation == .join)
        let body = try #require(r.body(floor.id))

        // 190 by 120 once `width` and `depth` were changed, a 3 mm floor and walls 30 mm above it.
        let b = try #require(body.bounds)
        #expect(abs(b.min.x) < 0.05 && abs(b.max.x - 190) < 0.05, "width follows: \(b)")
        #expect(abs(b.min.y) < 0.05 && abs(b.max.y - 120) < 0.05, "depth follows: \(b)")
        #expect(abs(b.max.z - 33) < 0.05, "3 mm floor and 30 mm walls: \(b)")

        // The wall is what is left of the floor's outline after the three sections: they follow the new size too.
        let sectionWidth = (190.0 - 9) / 2, backDepth = 120.0 - 9 - 25
        let wallArea = 190.0 * 120 - (190 - 6) * 25 - 2 * sectionWidth * backDepth
        let volume = 190.0 * 120 * 3 + wallArea * 30
        #expect(abs(body.volume - volume) < 1, "volume \(body.volume), expected \(volume)")

        let walls2 = try #require(facts.walls)
        #expect(walls2.outline == .good && walls2.frontSection == .good && walls2.backLeft == .good && walls2.backRight == .good)
        #expect(walls2.guide == .construction)
        #expect(walls2.solved.constraints.contains { if case .equal = $0.kind { true } else { false } }, "the sections are tied by Equal")
    }

    @Test func theUsersOwnWorkIsEnoughAndStepsTakeTheFirstUndoneOne() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-base")
        #expect(guide.current(in: model)?.id == "extrude-base")

        // Undo the sketch's rectangle: the guide goes back to drawing it.
        model.undoManager = UndoManager()
        let base = try #require(TutorialFacts(model).baseSketch)
        model.mutate("Clear") { doc in
            guard let i = doc.index(of: base.id), case .sketch(var sf) = doc.features[i].kind else { return }
            sf.sketch = Sketch()
            doc.features[i].kind = .sketch(sf)
        }
        await settle(model)
        #expect(guide.current(in: model)?.id == "base-rectangle")
    }

    // MARK: going back

    @Test func backUnreadsAReadStep() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        guide.acknowledge(TutorialScript.welcome)
        guide.acknowledge(TutorialScript.look)
        #expect(guide.current(in: model)?.id == "parameters")
        await guide.goBack(from: TutorialScript.parameters, in: model)
        #expect(guide.current(in: model)?.id == "look")
        #expect(guide.previous(of: TutorialScript.welcome) == nil, "nothing before the welcome")
        await guide.goBack(from: TutorialScript.welcome, in: model)
        #expect(guide.current(in: model)?.id == "look", "no step to go back to: nothing changes")
    }

    @Test func backUndoesTheWorkOfTheStepBefore() async throws {
        let model = await undoableModel()
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "wall-sketch")
        #expect(guide.current(in: model)?.id == "wall-sketch")
        #expect(TutorialFacts(model).baseExtrude != nil)

        // Back from "wall-sketch" takes the extrude away and shows "extrude-base" again; the sketch stays.
        let step = try #require(guide.current(in: model))
        await guide.goBack(from: step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "extrude-base")
        #expect(TutorialFacts(model).baseExtrude == nil && TutorialFacts(model).baseSketch != nil)
        #expect(model.result?.errors.isEmpty == true)

        // Once more: leaving the sketch can't be undone, so the sketch opens again, and the card asks to finish it.
        let again = try #require(guide.current(in: model))
        await guide.goBack(from: again, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "finish-base")
        #expect(model.sketchSession?.featureID == TutorialFacts(model).baseSketch?.id)
        #expect(TutorialFacts(model).baseSketch.map { TutorialFacts.baseOutline(of: $0.value.sketch) } == .good, "the rectangle is kept")

        // And once more: the rectangle goes, and the card asks for it.
        let third = try #require(guide.current(in: model))
        await guide.goBack(from: third, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "base-rectangle")

        // Forward again with "Do it for me" all the way: the same organizer.
        await run(guide, model)
        #expect(guide.isFinished)
        #expect(model.result?.errors.isEmpty == true && model.result?.bodies.count == 1)
    }

    @Test func backWorksStepByStepInsideTheWallsSketch() async throws {
        let model = await undoableModel()
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "front-section")
        #expect(TutorialFacts(model).walls?.guide == .construction)

        // The guide goes back to solid lines, then the inset goes, then the outline.
        var step = try #require(guide.current(in: model))
        await guide.goBack(from: step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "guide")
        #expect(TutorialFacts(model).walls?.guide == .solid)

        step = try #require(guide.current(in: model))
        await guide.goBack(from: step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "inset")
        #expect(TutorialFacts(model).walls?.guide == .missing)
        #expect(TutorialFacts(model).walls?.outline == .good)

        step = try #require(guide.current(in: model))
        await guide.goBack(from: step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "outline")

        // And forward again, to the end.
        await run(guide, model)
        #expect(guide.isFinished && model.result?.errors.isEmpty == true && model.result?.bodies.count == 1)
    }

    // MARK: what each step looks for

    @Test func theFloorRectangleMustUseTheParametersAndGrowFromTheOrigin() async throws {
        func sketch(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ first: String, _ second: String) -> Sketch {
            var s = Sketch()
            s.addRectangle(x0, y0, x1, y1)
            s.dimension(.length(s.curves[0].id), first)
            s.dimension(.length(s.curves[1].id), second)
            return s
        }
        var plain = Sketch()
        plain.addRectangle(0, 0, 150, 90)
        plain.dimension(.length(plain.curves[0].id), "150 mm")
        #expect(TutorialFacts.baseOutline(of: plain) == .plainNumbers)

        // Sized by parameters, but the wrong ones: not "plain numbers", and the hint names what's missing.
        #expect(TutorialFacts.baseOutline(of: sketch(0, 0, 150, 90, "width", "height")) == .missingParameters(["depth"]))

        // The floor grows up and to the right from the origin: any other way is called out.
        #expect(TutorialFacts.baseOutline(of: sketch(0, 0, 150, 90, "width", "depth")) == .good)
        #expect(TutorialFacts.baseOutline(of: sketch(0, -90, 150, 0, "width", "depth")) == .offOrigin)
        #expect(TutorialFacts.baseOutline(of: sketch(10, 10, 160, 100, "width", "depth")) == .offOrigin)
        #expect(TutorialFacts.baseOutline(of: sketch(0, 0, 150, 90, "width / 1", "depth * 1")) == .good)
        #expect(TutorialFacts.baseOutline(of: Sketch()) == .missing)
    }

    @Test func theCardWaitsForFinishSketchBeforeAskingForTheExtrude() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "finish-base")
        // The rectangle is drawn and the sketch is still open: this is the step that asks to finish it.
        let step = try #require(guide.current(in: model))
        #expect(step.id == "finish-base" && model.sketchSession != nil)
        #expect(step.spotlight(model) == ["Finish Sketch"])
        model.finishSketch()
        await settle(model)
        #expect(guide.current(in: model)?.id == "extrude-base")
    }

    @Test func aSketchOnTheWrongPlaneIsCalledOut() async throws {
        let model = DocumentModel()
        await settle(model)
        model.beginSketch(on: .xz)
        await settle(model)
        let guide = TutorialGuide(active: true)
        for s in [TutorialScript.welcome, TutorialScript.look, TutorialScript.parameters] { guide.acknowledge(s) }
        let step = try #require(guide.current(in: model))
        #expect(step.id == "sketch-plane")
        #expect(step.hint(model)?.isProblem == true)

        // "Do it for me" puts it right: the wrong sketch goes, one on the floor takes its place.
        await guide.assist(step, in: model)
        await settle(model)
        let facts = TutorialFacts(model)
        #expect(facts.baseSketch != nil && facts.misplacedSketch == nil)
        #expect(model.sketchSession?.featureID == facts.baseSketch?.id)
    }

    @Test func aSketchOnAnotherFaceThanTheFloorsTopIsCalledOut() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "wall-sketch")
        let floor = try #require(TutorialFacts(model).baseExtrude)
        // The underside of the floor: a face, but not where the walls go.
        model.beginSketch(on: .face(FaceRef(body: floor.id, face: "\(floor.id).start")))
        await settle(model)
        model.finishSketch()
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "wall-sketch" && step.hint(model)?.isProblem == true)

        await guide.assist(step, in: model)
        await settle(model)
        let facts = TutorialFacts(model)
        #expect(facts.wallSketch != nil && facts.misplacedWallSketch == nil)
        #expect(guide.current(in: model)?.id == "outline")
    }

    @Test func anOutlineThatMissesTheFloorsCornersIsCalledOut() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "outline")
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], SIMD2(10, 10))
        mouse(model, [.moved, .down, .up], SIMD2(100, 60))
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "outline" && step.hint(model)?.isProblem == true)

        // "Do it for me" clears it and clicks the corners.
        await guide.assist(step, in: model)
        await settle(model)
        #expect(TutorialFacts(model).walls?.outline == .good)
        #expect(guide.current(in: model)?.id == "inset")
        let walls = try #require(TutorialFacts(model).walls)
        let outline = try #require(walls.match(walls.layout.outline, in: walls.solid))
        #expect(walls.followsFloor(outline), "the outline follows the floor")
    }

    @Test func anInsetThatGoesOutwardsOrUsesANumberIsCalledOutAndReplaced() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "inset")

        func inset(_ text: String) async throws {
            let session = try #require(model.sketchSession)
            let walls = try #require(TutorialFacts(model).walls)
            let outline = try #require(walls.match(walls.layout.outline, in: walls.solid))
            model.setSketchTool(.select)
            session.selection = outline.lines
            model.beginSketchOffset()
            session.setTyped(.offsetDistance, text)
            model.commitSketchTyped()
            await settle(model)
        }

        // Outwards: the plain `wall` has no minus.
        try await inset("wall")
        #expect(TutorialFacts(model).walls?.guide == .outward)
        var step = try #require(guide.current(in: model))
        #expect(step.id == "inset" && step.hint(model)?.isProblem == true)
        await guide.assist(step, in: model)
        await settle(model)
        #expect(TutorialFacts(model).walls?.guide == .solid)
        #expect(TutorialFacts(model).walls?.boxes.count == 2, "the outward inset was taken out: the outline and the guide are left")

        // A number: the right place, but fixed.
        let model2 = DocumentModel()
        await settle(model2)
        let guide2 = TutorialGuide(active: true)
        await run(guide2, model2, until: "inset")
        let session2 = try #require(model2.sketchSession)
        let walls2 = try #require(TutorialFacts(model2).walls)
        let outline2 = try #require(walls2.match(walls2.layout.outline, in: walls2.solid))
        model2.setSketchTool(.select)
        session2.selection = outline2.lines
        model2.beginSketchOffset()
        session2.setTyped(.offsetDistance, "-3")
        model2.commitSketchTyped()
        await settle(model2)
        #expect(TutorialFacts(model2).walls?.guide == .plainNumber)
        step = try #require(guide2.current(in: model2))
        #expect(step.id == "inset" && step.hint(model2)?.isProblem == true)
        await guide2.assist(step, in: model2)
        await settle(model2)
        #expect(TutorialFacts(model2).walls?.guide == .solid)
    }

    @Test func aSectionWithPlainNumbersOrInTheWrongPlaceIsCalledOutAndReplaced() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "front-section")
        let session = try #require(model.sketchSession)
        let layout = try #require(TutorialFacts(model).layout)

        // The right place and the right size, typed as numbers: it wouldn't follow.
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], layout.guide.min)
        mouse(model, [.moved], layout.guide.min + SIMD2(12, 12))
        session.setTyped(.width, "144")
        session.setTyped(.height, "25")
        model.commitSketchTyped()
        await settle(model)
        #expect(TutorialFacts(model).walls?.frontSection == .plainNumbers)
        var step = try #require(guide.current(in: model))
        #expect(step.id == "front-section" && step.hint(model)?.isProblem == true)

        // Sized by the wrong parameters: the hint names the missing one.
        await guide.assist(step, in: model)
        await settle(model)
        #expect(TutorialFacts(model).walls?.frontSection == .good)
        #expect(TutorialFacts(model).walls?.solid.count == 2, "the numbers were replaced, not stacked: outline and section")

        // A rectangle where no section goes.
        model.setSketchTool(.rectangle)
        mouse(model, [.moved, .down, .up], SIMD2(40, 50))
        mouse(model, [.moved, .down, .up], SIMD2(60, 70))
        await settle(model)
        step = try #require(guide.current(in: model))
        #expect(step.id == "back-left" && step.hint(model)?.isProblem == true, "\(step.id)")
        await guide.assist(step, in: model)
        await settle(model)
        #expect(TutorialFacts(model).walls?.strays.isEmpty == true && TutorialFacts(model).walls?.backLeft == .good)
        #expect(guide.current(in: model)?.id == "back-right")
    }

    @Test func theRightSectionTakesItsWidthFromTheParametersAndItsDepthFromEqual() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "back-right")
        await guide.assist(try #require(guide.current(in: model)), in: model)
        await settle(model)

        // Drawn: the right width, hanging from the back-right corner, but not as deep as the left one yet.
        let walls = try #require(TutorialFacts(model).walls)
        let drawn = try #require(walls.backRightDrawn)
        #expect(abs(drawn.depth - 10) < 0.05, "the depth is where the mouse was: \(drawn.depth)")
        #expect(walls.backRight != .good)
        var step = try #require(guide.current(in: model))
        #expect(step.id == "equal")

        // The two edges that face each other, selected: the card asks for Constrain ▸ Equal and points at it.
        let left = try #require(walls.match(walls.layout.backLeft, in: walls.solid))
        let a = try #require(walls.side(of: left, right: true)), b = try #require(walls.side(of: drawn, right: false))
        let session = try #require(model.sketchSession)
        model.setSketchTool(.select)
        session.selection = [a, b]
        #expect(step.hint(model)?.text.contains("Equal") == true && step.spotlight(model) == ["Constrain", "Equal"])
        model.sketchCommand { $0.apply(.equal) }
        await settle(model)
        step = try #require(guide.current(in: model))
        #expect(step.id == "finish-walls")
        #expect(TutorialFacts(model).walls?.backRight == .good)

        // Equal on the wrong pair (the two bottoms) doesn't make them the same depth: a different run.
        let model2 = DocumentModel()
        await settle(model2)
        let guide2 = TutorialGuide(active: true)
        await run(guide2, model2, until: "back-right")
        await guide2.assist(try #require(guide2.current(in: model2)), in: model2)
        await settle(model2)
        let w2 = try #require(TutorialFacts(model2).walls)
        let l2 = try #require(w2.match(w2.layout.backLeft, in: w2.solid)), r2 = try #require(w2.backRightDrawn)
        let bottom: (TutorialFacts.Box) -> EntityID? = { box in
            box.lines.first { id in w2.solved.lineEnds(id).map { abs($0.0.y - $0.1.y) < 1e-6 && abs($0.0.y - box.min.y) < 1e-6 } ?? false }
        }
        let session2 = try #require(model2.sketchSession)
        session2.selection = [try #require(bottom(l2)), try #require(bottom(r2))]
        model2.sketchCommand { $0.apply(.equal) }
        await settle(model2)
        let step2 = try #require(guide2.current(in: model2))
        #expect(step2.id == "equal" && step2.hint(model2)?.isProblem == true)
        await guide2.assist(step2, in: model2)
        await settle(model2)
        #expect(TutorialFacts(model2).walls?.backRight == .good && guide2.current(in: model2)?.id == "finish-walls")
    }

    @Test func fillingASectionInsteadOfTheWallIsCalledOutAndReplaced() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-walls")
        let wall = try #require(TutorialFacts(model).wallSketch)
        model.run(.extrude)
        // The front section is a region of its own: the one bounded by exactly its four lines.
        let walls = try #require(TutorialFacts(model).walls)
        let section = try #require(walls.match(walls.layout.frontSection, in: walls.solid))
        let slot = try #require(model.sketchSlots.firstIndex(of: wall.id)) + 1
        let region = try #require(model.result?.sketches[wall.id]?.regions.first { Set($0.tags.split(separator: ",").map(String.init)) == Set(section.lines) })
        let pick = PickID(region: region.index, slot: slot)
        model.click(pick, additive: false)
        await settle(model)
        let id = try #require(model.selectedFeature)
        model.commitHandle("height", for: id)
        await settle(model)
        model.finishFeatureEdit()
        await settle(model)

        let step = try #require(guide.current(in: model))
        #expect(step.id == "extrude-walls" && step.hint(model)?.isProblem == true)
        #expect(TutorialFacts(model).wallExtrude.map { TutorialFacts(model).extrudesTheWall($0.value) } == false)
        await guide.assist(step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "change")
        #expect(model.document.features.filter { if case .extrude = $0.kind { true } else { false } }.count == 2, "the wrong extrude was replaced")
        #expect(model.result?.errors.isEmpty == true && model.result?.bodies.count == 1)
    }

    @Test func pullingTheWholeTopOfTheFloorUpIsCalledOutAndReplaced() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-walls")
        let floor = try #require(TutorialFacts(model).baseExtrude)
        model.finishSketch()
        model.mutate("Extrude Face") { doc in
            doc.features.append(Feature(name: "Extrude", .extrude(ExtrudeFeature(face: FaceRef(body: floor.id, face: "\(floor.id).end"), extent: .distance("height")))))
        }
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "extrude-walls" && step.hint(model)?.isProblem == true)
        await guide.assist(step, in: model)
        await settle(model)
        #expect(TutorialFacts(model).facePull == nil)
        #expect(guide.current(in: model)?.id == "change")
        #expect(model.result?.errors.isEmpty == true && model.result?.bodies.count == 1)
    }

    @Test func wallsThatAreNotJoinedAreNotDone() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-walls")
        let wall = try #require(TutorialFacts(model).wallSketch)
        model.finishSketch()
        await settle(model)
        model.run(.extrude)
        let outline = try #require(TutorialFacts(model).walls.flatMap { $0.match($0.layout.outline, in: $0.solid) })
        let pick = try #require(TutorialActions.profilePick(of: wall.id, containing: outline.lines, model))
        model.click(pick, additive: false)
        await settle(model)
        let id = try #require(model.selectedFeature)
        model.updateFeature(id, "Change Operation") { f in
            if case .extrude(var e) = f.kind { e.operation = .newBody; f.kind = .extrude(e) }
        }
        model.commitHandle("height", for: id)
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "extrude-walls" && step.hint(model)?.isProblem == true)
        #expect(step.spotlight(model) == ["inspector"])
        await guide.assist(step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "change")
        #expect(model.result?.bodies.count == 1)
    }

    @Test func changingOnlyOneOfWidthAndDepthIsNotEnough() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "change")
        let step = try #require(guide.current(in: model))
        #expect(step.spotlight(model) == ["parameter-width", "parameter-depth"])
        model.setParameter("width", expression: "200 mm")
        await settle(model)
        #expect(guide.current(in: model)?.id == "change")
        #expect(step.spotlight(model) == ["parameter-depth"] && step.hint(model)?.text.contains("depth") == true)
        model.setParameter("depth", expression: "100 mm")
        await settle(model)
        #expect(guide.current(in: model)?.id == "done")

        // Whatever sizes were chosen, the sections follow: everything before stays done and the part is sound.
        for s in TutorialScript.steps.dropLast() { #expect(guide.isDone(s, in: model), "\(s.id)") }
        let r = try #require(model.result)
        #expect(r.errors.isEmpty && r.bodies.count == 1, "\(r.errors)")
        let floor = try #require(TutorialFacts(model).baseExtrude)
        let b = try #require(r.body(floor.id)?.bounds)
        #expect(abs(b.max.x - 200) < 0.05 && abs(b.max.y - 100) < 0.05)
    }

    @Test func parametersAreOnlyAddedOnce() async throws {
        let model = DocumentModel()
        await settle(model)
        TutorialActions.seedParameters(model)
        TutorialActions.seedParameters(model)
        #expect(model.document.parameters.map(\.name) == ["width", "depth", "height", "wall", "front"])
        model.setParameter("width", expression: "170 mm")
        TutorialActions.seedParameters(model)
        #expect(model.document.parameters.first { $0.name == "width" }?.expression == "170 mm", "the user's value stays")
        #expect(TutorialFacts(model).isChanged("width") && !TutorialFacts(model).isChanged("depth"))
    }

    @Test func parametersThatLeaveNoRoomForTheSectionsAreCalledOut() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "front-section")
        model.setParameter("front", expression: "200 mm")
        await settle(model)
        #expect(TutorialFacts(model).layout == nil)
        let step = try #require(TutorialScript.step("front-section"))
        #expect(step.hint(model)?.isProblem == true)
    }

    // MARK: the card's state

    @Test func closingKeepsProgressAndHelpResumes() async throws {
        let model = DocumentModel()
        let guide = TutorialGuide(active: true)
        guide.acknowledge(TutorialScript.welcome)
        guide.stop()
        #expect(!guide.isActive && guide.canResume)
        guide.start()
        #expect(guide.isActive && guide.current(in: model)?.id == "look")
    }

    @Test func finishingRemembersIt() async throws {
        UserDefaults.standard.removeObject(forKey: Preferences.tutorialCompleted)
        let guide = TutorialGuide(active: true)
        guide.acknowledge(TutorialScript.done)
        #expect(guide.isFinished && !guide.isActive && !guide.canResume)
        #expect(UserDefaults.standard.bool(forKey: Preferences.tutorialCompleted))
        UserDefaults.standard.removeObject(forKey: Preferences.tutorialCompleted)
    }

    @Test func eachTaskStepNamesItsNextMoveFromTheStart() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        for step in TutorialScript.steps {
            guard step.isTask else { guide.acknowledge(step); continue }
            if let hint = step.hint(model) { #expect(!hint.text.isEmpty) }
            _ = step.spotlight(model)
        }
    }
}

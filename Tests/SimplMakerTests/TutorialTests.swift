// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The guided first part (a phone stand): its steps, how each knows it is done, and "Do it for me" for all of them.
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

    // MARK: the script

    @Test func scriptHasFifteenWellFormedSteps() {
        let steps = TutorialScript.steps
        #expect(steps.count == 15)
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

    @Test func doItForMeBuildsTheWholeStandAndWidensIt() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        let seen = await run(guide, model)

        #expect(seen == TutorialScript.steps.map(\.id), "every step came up once, in order: \(seen)")
        #expect(guide.isFinished && !guide.isActive)
        #expect(guide.current(in: model) == nil || guide.isFinished)

        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 1, "one body, the stand: \(r.bodies.map(\.id))")
        let facts = TutorialFacts(model)
        let base = try #require(facts.baseExtrude), back = try #require(facts.backExtrude)
        #expect(back.value.operation == .join)
        let body = try #require(r.body(base.id))

        // The base is 190 mm wide once `width` was changed (a tablet), 60 deep toward the viewer, and the
        // backrest rises from its rear edge and leans back past it.
        let b = try #require(body.bounds)
        #expect(abs(b.min.x) < 0.05 && abs(b.max.x - 190) < 0.05, "width follows: \(b)")
        #expect(b.min.y < -50 && b.min.y > -65, "the base reaches toward the viewer: \(b)")
        #expect(b.max.y > 5, "the backrest leans back past the base: \(b)")
        #expect(b.max.z > 60 && b.max.z < 75, "70 mm of backrest at 70 degrees: \(b)")
        #expect(facts.planeLeans)
        let width = 190.0
        #expect(body.volume > width * 60 * 4 * 0.95 + width * 70 * 4 * 0.9, "base and backrest: \(body.volume)")
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
        let model = DocumentModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "plane")
        #expect(guide.current(in: model)?.id == "plane")
        #expect(TutorialFacts(model).baseExtrude != nil)

        // Back from "plane" takes the extrude away and shows "extrude-base" again; the sketch stays.
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

        // Forward again with "Do it for me" all the way: the same stand.
        await run(guide, model)
        #expect(guide.isFinished)
        #expect(model.result?.errors.isEmpty == true && model.result?.bodies.count == 1)
    }

    // MARK: what each step looks for

    @Test func theRectanglesMustUseTheParametersAndGrowFromTheOrigin() async throws {
        func sketch(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ first: String, _ second: String) -> Sketch {
            var s = Sketch()
            s.addRectangle(x0, y0, x1, y1)
            s.dimension(.length(s.curves[0].id), first)
            s.dimension(.length(s.curves[1].id), second)
            return s
        }
        var plain = Sketch()
        plain.addRectangle(0, -60, 80, 0)
        plain.dimension(.length(plain.curves[0].id), "80 mm")
        #expect(TutorialFacts.baseOutline(of: plain) == .plainNumbers)

        // Sized by parameters, but the wrong ones: not "plain numbers", and the hint names what's missing.
        #expect(TutorialFacts.baseOutline(of: sketch(0, -60, 80, 0, "width", "thickness")) == .missingParameters(["depth"]))

        // The base grows toward the viewer (down), the backrest up: the wrong way round is called out.
        #expect(TutorialFacts.baseOutline(of: sketch(0, -60, 80, 0, "width", "depth")) == .good)
        #expect(TutorialFacts.baseOutline(of: sketch(0, 0, 80, 60, "width", "depth")) == .offOrigin)
        #expect(TutorialFacts.baseOutline(of: sketch(10, -70, 90, -10, "width", "depth")) == .offOrigin)
        #expect(TutorialFacts.backOutline(of: sketch(0, 0, 80, 70, "width", "backrest")) == .good)
        #expect(TutorialFacts.backOutline(of: sketch(0, -70, 80, 0, "width", "backrest")) == .offOrigin)
        #expect(TutorialFacts.backOutline(of: sketch(0, 0, 80, 70, "width / 1", "backrest * 1")) == .good)
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

    @Test func aNewPlaneIsNotDoneUntilItsOffsetIsSettledAndItMustLeanByTheParameter() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "plane")
        model.run(.plane)
        model.click(OriginPlane.xy.pickID, additive: false)
        await settle(model)

        // The new plane's offset field is still open: the card asks for Return, and `lean` typed there would be wrong.
        var step = try #require(guide.current(in: model))
        #expect(step.id == "plane" && step.hint(model)?.text.contains("Return") == true)
        model.finishFeatureEdit()
        step = try #require(guide.current(in: model))
        #expect(step.id == "tilt" && step.hint(model)?.text.lowercased().contains("select") == true, "\(step.id)")

        // The step selects the plane for the user, so the inspector has its Angle field ready (clicking the plane
        // in the viewport isn't needed). It asks for the angle; a plain number tilts it too, but won't follow `lean`.
        let plane = try #require(TutorialFacts(model).plane)
        step.enter?(model)
        #expect(model.selectedFeature == plane.id)
        #expect(step.hint(model)?.text.contains("Angle") == true && step.spotlight(model) == ["inspector"])
        model.updateFeature(plane.id, "Angle") { f in if case .plane(var p) = f.kind { p.angle = "60 deg"; f.kind = .plane(p) } }
        await settle(model)
        #expect(guide.current(in: model)?.id == "tilt" && step.hint(model)?.isProblem == true)
        await guide.assist(step, in: model)
        await settle(model)
        #expect(TutorialFacts(model).planeLeans && guide.current(in: model)?.id == "back-sketch")
        #expect(model.document.features.filter { if case .plane = $0.kind { true } else { false } }.count == 1)
    }

    @Test func aBackrestSketchedAnywhereButOnThePlaneIsCalledOut() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "back-sketch")
        model.beginSketch(on: .xz)
        await settle(model)
        model.finishSketch()
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "back-sketch" && step.hint(model)?.isProblem == true)
        await guide.assist(step, in: model)
        await settle(model)
        let facts = TutorialFacts(model)
        #expect(facts.backSketch != nil && facts.misplacedBackSketch == nil)
        #expect(guide.current(in: model)?.id == "back-rectangle")
    }

    @Test func aBackrestThatIsNotJoinedIsNotDone() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-back")
        let back = try #require(TutorialFacts(model).backSketch)
        model.finishSketch()
        await settle(model)
        model.run(.extrude)
        let pick = try #require(TutorialActions.profilePick(of: back.id, model))
        model.click(pick, additive: false)
        await settle(model)
        let id = try #require(model.selectedFeature)
        model.updateFeature(id, "Change Operation") { f in
            if case .extrude(var e) = f.kind { e.operation = .newBody; f.kind = .extrude(e) }
        }
        model.commitHandle("thickness", for: id)
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "extrude-back" && step.hint(model)?.isProblem == true)
        #expect(step.spotlight(model) == ["inspector"])
        await guide.assist(step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "change")
        #expect(model.result?.bodies.count == 1)
    }

    @Test func parametersAreOnlyAddedOnce() async throws {
        let model = DocumentModel()
        await settle(model)
        TutorialActions.seedParameters(model)
        TutorialActions.seedParameters(model)
        #expect(model.document.parameters.map(\.name) == ["width", "depth", "thickness", "backrest", "lean"])
        #expect(model.document.parameters.first { $0.name == "lean" }?.unit == .angle)
        model.setParameter("width", expression: "70 mm")
        TutorialActions.seedParameters(model)
        #expect(model.document.parameters.first { $0.name == "width" }?.expression == "70 mm", "the user's value stays")
        #expect(TutorialFacts(model).parametersChanged)
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

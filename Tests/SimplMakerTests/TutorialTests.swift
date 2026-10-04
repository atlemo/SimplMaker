// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The guided first part: its steps, how each knows it is done, and "Do it for me" for all of them.
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

    @Test func scriptHasSeventeenWellFormedSteps() {
        let steps = TutorialScript.steps
        #expect(steps.count == 17)
        #expect(Set(steps.map(\.id)).count == steps.count, "ids are unique")
        #expect(steps.map(\.chapter.rawValue) == steps.map(\.chapter.rawValue).sorted(), "chapters run in order")
        for step in steps where step.isTask { #expect(step.assist != nil, "\(step.id) can't be done for the user") }
        for step in steps { #expect(!step.title.isEmpty && !step.text.isEmpty) }
        #expect(steps.first?.id == "welcome" && steps.last?.id == "done")
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

    @Test func doItForMeBuildsTheWholeBoxAndLid() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        let seen = await run(guide, model)

        #expect(seen == TutorialScript.steps.map(\.id), "every step came up once, in order: \(seen)")
        #expect(guide.isFinished && !guide.isActive)
        #expect(guide.current(in: model) == nil || guide.isFinished)

        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 2, "a box and a lid: \(r.bodies.map(\.id))")
        let facts = TutorialFacts(model)
        let box = try #require(facts.boxExtrude), lid = try #require(facts.lidExtrude)
        let boxBody = try #require(r.body(box.id)), lidBody = try #require(r.body(lid.id))

        // The box: 80 × 40 × 25 once `width` was changed to 80 mm, hollow, open at the top.
        let b = try #require(boxBody.bounds)
        #expect(abs(b.max.x - 40) < 1e-3 && abs(b.min.x + 40) < 1e-3, "width follows: \(b)")
        #expect(abs(b.max.z - 25) < 1e-3 && abs(b.max.y - 20) < 1e-3)
        #expect(boxBody.volume < 80 * 40 * 25 * 0.3, "hollow: \(boxBody.volume)")

        // The lid: rests on the box, 4 mm thick (wall × 2), same footprint. (The box around a filleted and
        // threaded body is only approximate, so a little slack.)
        let l = try #require(lidBody.bounds)
        #expect(abs(l.min.z - 25) < 0.05 && abs(l.max.z - 29) < 0.05, "\(l)")
        #expect(abs(l.max.x - 40) < 0.05 && abs(l.max.y - 20) < 0.05)

        // Fillet, hole and thread on the lid.
        #expect(facts.lidFillet != nil && facts.lidHole != nil && facts.lidThread != nil)
        let thread = try #require(facts.lidThread)
        #expect(thread.value.standard == .metric && thread.value.size == "M6x1", "\(thread.value.size)")
        let hole = try #require(facts.lidHole)
        #expect(hole.value.u == "0 mm" && hole.value.v == "0 mm", "the hole is in the middle: \(hole.value.u), \(hole.value.v)")
    }

    @Test func theUsersOwnWorkIsEnoughAndStepsTakeTheFirstUndoneOne() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-box")
        #expect(guide.current(in: model)?.id == "extrude-box")

        // Undo the sketch's rectangle: the guide goes back to drawing it.
        model.undoManager = UndoManager()
        let box = try #require(TutorialFacts(model).boxSketch)
        model.mutate("Clear") { doc in
            guard let i = doc.index(of: box.id), case .sketch(var sf) = doc.features[i].kind else { return }
            sf.sketch = Sketch()
            doc.features[i].kind = .sketch(sf)
        }
        await settle(model)
        #expect(guide.current(in: model)?.id == "box-rectangle")
    }

    // MARK: what each step looks for

    @Test func theRectangleMustUseTheParametersAndSitOnTheOrigin() async throws {
        var plain = Sketch()
        plain.addRectangle(-30, -20, 30, 20)
        plain.dimension(.length(plain.curves[0].id), "60 mm")
        #expect(TutorialFacts.outline(of: plain) == .plainNumbers)

        // Sized by parameters, but the wrong ones: not "plain numbers", and the hint names what's missing.
        var wrong = Sketch()
        wrong.addRectangle(-30, -20, 30, 20)
        wrong.dimension(.length(wrong.curves[0].id), "width")
        wrong.dimension(.length(wrong.curves[1].id), "height")
        #expect(TutorialFacts.outline(of: wrong) == .missingParameters(["depth"]))

        var shifted = Sketch()
        shifted.addRectangle(0, 0, 60, 40)
        shifted.dimension(.length(shifted.curves[0].id), "width")
        shifted.dimension(.length(shifted.curves[1].id), "depth")
        #expect(TutorialFacts.outline(of: shifted) == .offCenter)

        var good = Sketch()
        good.addRectangle(-30, -20, 30, 20)
        good.dimension(.length(good.curves[0].id), "width")
        good.dimension(.length(good.curves[1].id), "depth / 1")
        #expect(TutorialFacts.outline(of: good) == .good)
        #expect(TutorialFacts.outline(of: Sketch()) == .missing)
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
        #expect(facts.boxSketch != nil && facts.misplacedSketch == nil)
        #expect(model.sketchSession?.featureID == facts.boxSketch?.id)
    }

    @Test func aLidThatJoinsTheBoxIsNotDone() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "extrude-lid")
        // Extrude the lid as the tool's default (a join), with the right size: still not done.
        let lid = try #require(TutorialFacts(model).lidSketch)
        model.finishSketch()
        await settle(model)
        model.run(.extrude)
        let pick = try #require(TutorialActions.profilePick(of: lid.id, model))
        model.click(pick, additive: false)
        await settle(model)
        let id = try #require(model.selectedFeature)
        model.commitHandle("wall * 2", for: id)
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "extrude-lid", "joined to the box, so not a lid yet")
        #expect(step.hint(model)?.isProblem == true)
        #expect(step.spotlight(model) == ["inspector"])
        await guide.assist(step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "fillet")
        #expect(model.result?.bodies.count == 2)
    }

    @Test func aShellThroughASideIsCalledOut() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true)
        await run(guide, model, until: "shell")
        let ex = try #require(TutorialFacts(model).boxExtrude)
        let side = FaceRef(body: ex.id, face: "\(ex.id).start")  // the bottom, not the top
        model.add(Feature(name: "Shell1", .shell(ShellFeature(body: ex.id, faces: [side]))))
        await settle(model)
        let step = try #require(guide.current(in: model))
        #expect(step.id == "shell" && step.hint(model)?.isProblem == true)
    }

    @Test func parametersAreOnlyAddedOnce() async throws {
        let model = DocumentModel()
        await settle(model)
        TutorialActions.seedParameters(model)
        TutorialActions.seedParameters(model)
        #expect(model.document.parameters.map(\.name) == ["width", "depth", "height", "wall"])
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

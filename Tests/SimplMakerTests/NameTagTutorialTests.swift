// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The iPad's tutorial (a name tag keyring): its steps, how each knows it is done, and "Do it for me" for all of them.
@Suite @MainActor struct NameTagTutorialTests {
    private func settle(_ model: DocumentModel) async { await TutorialActions.settle(model) }

    @discardableResult
    private func run(_ guide: TutorialGuide, _ model: DocumentModel, until stop: String? = nil) async -> [String] {
        var seen: [String] = []
        for _ in 0..<40 {
            guard let step = guide.current(in: model) else { break }
            if step.id == stop { break }
            seen.append(step.id)
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
            for earlier in seen.dropLast() {
                if let e = NameTagScript.step(earlier) { #expect(guide.isDone(e, in: model), "\(earlier) came undone during \(step.id)") }
            }
            if guide.current(in: model)?.id == step.id { break }
        }
        return seen
    }

    private func undoableModel() async -> DocumentModel {
        let model = DocumentModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        await settle(model)
        return model
    }

    @Test func scriptHasFourteenWellFormedSteps() {
        let steps = NameTagScript.steps
        #expect(steps.count == 14)
        #expect(Set(steps.map(\.id)).count == steps.count, "ids are unique")
        #expect(steps.map(\.chapter.rawValue) == steps.map(\.chapter.rawValue).sorted(), "chapters run in order")
        for step in steps where step.isTask { #expect(step.assist != nil, "\(step.id) can't be done for the user") }
        for step in steps { #expect(!step.title.isEmpty && !step.text.isEmpty) }
        #expect(steps.first?.id == "welcome" && steps.last?.id == "done")
        #expect(NameTagScript.welcome.text.count < 160)
    }

    @Test func touchWordingHasNoMouseOrKeyboardInIt() {
        let forbidden = ["click", "Click", "mouse", "Mouse", "⌘", "Press ", "press ", "Tab", "scroll", "wheel", "Return**"]
        for step in NameTagScript.steps {
            let model = DocumentModel()
            var texts = [step.title, step.text]
            if let hint = step.hint(model) { texts.append(hint.text) }
            for text in texts {
                for word in forbidden where word != "Return**" { #expect(!text.contains(word), "\(step.id): \"\(word)\" in \(text)") }
            }
        }
    }

    @Test func thePlatformPicksItsTutorial() {
        #if os(macOS)
        #expect(TutorialGuide().kind == .deskOrganizer)
        #endif
        #expect(TutorialGuide(kind: .nameTag).steps.count == 14)
        #expect(TutorialGuide(kind: .nameTag).kind.title == "Name Tag Keyring")
    }

    @Test func doItForMeBuildsTheNameTagAndResizesIt() async throws {
        let model = DocumentModel()
        await settle(model)
        let guide = TutorialGuide(active: true, kind: .nameTag)
        let seen = await run(guide, model)

        #expect(seen == NameTagScript.steps.map(\.id), "every step came up once, in order: \(seen)")
        #expect(guide.isFinished && !guide.isActive)

        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 1, "one body, the tag: \(r.bodies.map(\.id))")
        let facts = TutorialFacts(model)
        let tag = try #require(facts.baseExtrude), letters = try #require(facts.wallExtrude)
        #expect(letters.value.operation == .join)
        let hole = try #require(facts.tagHole)
        #expect(TutorialFacts.uses(hole.value.diameter, "hole"))
        #expect(facts.tagText == NameTagScript.sampleName)
        let body = try #require(r.body(tag.id))

        // 75 by 25 once `width` was changed, 3 mm thick with letters 1 mm above.
        let b = try #require(body.bounds)
        #expect(abs(b.min.x) < 0.1 && abs(b.max.x - 75) < 0.1, "width follows: \(b)")
        #expect(abs(b.min.y) < 0.1 && abs(b.max.y - 25) < 0.1, "depth: \(b)")
        #expect(abs(b.max.z - 4) < 0.1, "3 mm tag and 1 mm letters: \(b)")

        // The hole goes right through: the plate alone would be bigger.
        // (The plate with its rounded corners and a 6 mm hole, plus a few letters 1 mm tall.)
        let plateWithHole = 75.0 * 25 * 3 - (4 - .pi) * 6.25 * 6.25 * 3 - .pi * 3 * 3 * 3
        #expect(body.volume > plateWithHole + 30 && body.volume < plateWithHole + 300, "plate, letters and hole: \(body.volume) vs \(plateWithHole)")
        // The hole is 6 mm wide now.
        #expect((try? model.parameterValues.value(of: "hole", kind: .length)) == 6)
    }

    @Test func backUndoesTheWorkOfTheStepBefore() async throws {
        let model = await undoableModel()
        let guide = TutorialGuide(active: true, kind: .nameTag)
        await run(guide, model, until: "name-sketch")
        #expect(guide.current(in: model)?.id == "name-sketch")
        #expect(TutorialFacts(model).baseExtrude != nil)

        let step = try #require(guide.current(in: model))
        await guide.goBack(from: step, in: model)
        await settle(model)
        #expect(guide.current(in: model)?.id == "extrude-tag")
        #expect(TutorialFacts(model).baseExtrude == nil && TutorialFacts(model).baseSketch != nil)

        await run(guide, model)
        #expect(guide.isFinished)
        #expect(model.result?.errors.isEmpty == true && model.result?.bodies.count == 1)
    }

    @Test func draggingTheCardOnlyChangesItsOffset() {
        let guide = TutorialGuide(active: true, kind: .nameTag)
        #expect(guide.cardOffset == .zero)
        guide.cardOffset = CGSize(width: 10, height: -20)
        #expect(guide.cardOffset.height == -20)
    }

    @Test func aTagWithPlainNumbersIsNotAccepted() async throws {
        let model = await undoableModel()
        let guide = TutorialGuide(active: true, kind: .nameTag)
        await run(guide, model, until: "outline")
        let base = try #require(TutorialFacts(model).baseSketch)
        let session = try #require(model.sketchSession)
        #expect(session.featureID == base.id)
        model.undoManager?.beginUndoGrouping()
        defer { model.undoManager?.endUndoGrouping() }
        model.setSketchTool(.roundedRectangle)
        for phase in [SketchMouse.Phase.moved, .down, .up] { _ = model.sketchMouse(SketchMouse(phase: phase, uv: .zero, pick: nil)) }
        _ = model.sketchMouse(SketchMouse(phase: .moved, uv: SIMD2(12, 12), pick: nil))
        session.setTyped(.width, "60")
        session.setTyped(.height, "25")
        session.setTyped(.radius, "6")
        model.commitSketchTyped()
        await settle(model)
        #expect(guide.current(in: model)?.id == "outline")
        let hint = try #require(guide.current(in: model)?.hint(model))
        #expect(hint.isProblem, "\(hint.text)")
    }
}

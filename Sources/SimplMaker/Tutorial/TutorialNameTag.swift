// The iPad's tutorial: a name tag keyring, in 14 steps, all with a finger.
//
// Five named numbers (width, depth, thick, hole, relief) drive everything. A rounded rectangle sketched on the floor plane
// and extruded by `thick` is the tag. A second sketch on its top face holds the name, extruded by `relief` and joined to the tag.
// A hole for the key ring is drilled through the left end, and the last step changes `width` and `hole` and watches the tag follow.
// The wording is for touch: tap, drag, pinch. Nothing asks for a mouse or a key.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd

@MainActor
enum NameTagScript {
    static let steps: [TutorialStep] = [
        welcome, look, parameters,
        sketchPlane, outline, finishOutline, extrudeTag,
        nameSketch, nameText, finishName, extrudeName,
        ringHole,
        change, done,
    ]

    static func step(_ id: String) -> TutorialStep? { steps.first { $0.id == id } }

    /// The words "Do it for me" puts on the tag.
    static let sampleName = "Sam"

    /// Both side panels out of the way: the tag gets the room (the browser comes back for the steps that point at it).
    private static func clearPanels(_ model: DocumentModel) {
        model.showSidebar = false
        model.showInspector = false
    }

    // MARK: get started

    static let welcome = TutorialStep(
        id: "welcome", chapter: .start,
        title: "Make a name tag keyring",
        text: "A flat tag with your name on it and a hole for the ring. It takes about ten minutes, and you can leave whenever you like. No hard feelings.",
        kind: .read(button: "Let's start"))

    static let look = TutorialStep(
        id: "look", chapter: .start,
        title: "Find your way around",
        text: "**Drag** one finger on empty space to orbit the view, **pinch** to zoom, and drag with **two fingers** to pan. The cube in the corner turns the view to a standard side when you tap it.",
        kind: .read(button: "Next"),
        enter: { clearPanels($0) })

    static let parameters = TutorialStep(
        id: "parameters", chapter: .start,
        title: "Name your numbers",
        text: "A **parameter** is a number with a name. Five are now in the browser on the left: `width`, `depth`, `thick`, `hole` and `relief`. Use a name instead of a number and the whole tag follows when you change it. That is what makes a model *parametric*.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["parameters"] },
        enter: { model in
            model.showInspector = false
            model.showSidebar = true
            model.parametersOpen = true
            TutorialActions.seedParameters(model, kind: .nameTag)
        })

    // MARK: the tag

    static let sketchPlane = TutorialStep(
        id: "sketch-plane", chapter: .tagShape,
        title: "Start with a sketch",
        text: "Every solid begins as a flat drawing. Tap **Sketch** in the toolbar, then tap the square labelled **XY**: that is the floor the tag will lie on.",
        kind: .task(done: { TutorialFacts($0).baseSketch != nil }),
        hint: { model in
            if TutorialFacts(model).misplacedSketch != nil {
                return .problem("That sketch is on the wrong plane. Tap **Undo** at the top, tap **Sketch** again, then tap the square labelled **XY**.")
            }
            return model.isPickingSketchPlane
                ? .next("Now tap the square labelled **XY**.")
                : .next("Tap **Sketch** in the toolbar.")
        },
        spotlight: { model in model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"] },
        enter: { clearPanels($0) },
        assist: { await TutorialActions.startBaseSketch($0) })

    static let outline = TutorialStep(
        id: "outline", chapter: .tagShape,
        title: "Draw the tag",
        text: "The tag is a rounded rectangle, and the tool is ready. Tap the **origin**, the point in the middle of the grid. Boxes for the sizes appear: type `width`, `depth` and `depth / 4` in them, then tap **OK**.",
        kind: .task(done: { model in
            guard let base = TutorialFacts(model).baseSketch else { return false }
            return TutorialFacts.baseOutline(of: base.value.sketch) == .good
        }),
        hint: { model in
            guard let base = TutorialFacts(model).baseSketch else { return nil }
            return outlineHint(model, sketch: base, outline: TutorialFacts.baseOutline(of: base.value.sketch))
        },
        enter: { model in clearPanels(model); model.setSketchTool(.roundedRectangle) },
        assist: { await drawTag($0) })

    static let finishOutline = TutorialStep(
        id: "finish-outline", chapter: .tagShape,
        title: "Finish the sketch",
        text: "Tap **Finish Sketch** in the toolbar to leave sketch mode. The rounded rectangle is now a profile that can be extruded.",
        // Done once the tag's sketch isn't being edited: sketching on top of it later must not bring this step back.
        kind: .task(done: { model in model.sketchSession?.featureID != TutorialFacts(model).baseSketch?.id }),
        hint: { _ in .next("Tap **Finish Sketch** in the toolbar.") },
        spotlight: { _ in ["Finish Sketch"] },
        assist: { $0.finishSketch() },
        rewind: { model in
            guard let base = TutorialFacts(model).baseSketch else { return }
            model.editSketch(base.id)
            await TutorialActions.settle(model)
        })

    static let extrudeTag = TutorialStep(
        id: "extrude-tag", chapter: .tagShape,
        title: "Pull it up",
        text: "**Extrude** turns a flat profile into a solid. Tap **Extrude**, then tap inside the rounded rectangle. An orange arrow appears: type `thick` in the box beside it and tap **OK**. Now it is a tag.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).baseExtrude, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "thick")
        }),
        hint: { model in
            if TutorialFacts(model).baseExtrude != nil {
                return .next("Type `thick` in the box beside the orange arrow, then tap **OK**.")
            }
            // Sketch mode has no Extrude button: the sketch has to be finished first.
            if model.sketchSession != nil { return .next("Tap **Finish Sketch**, then choose Extrude.") }
            return model.pendingTool == .extrude
                ? .next("Now tap inside the rounded rectangle.")
                : .next("Tap **Extrude** in the toolbar.")
        },
        spotlight: { model in
            if TutorialFacts(model).baseExtrude != nil { return [] }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Extrude"] : []
        },
        enter: { clearPanels($0) },
        assist: { model in
            guard let base = TutorialFacts(model).baseSketch else { return }
            if let ex = TutorialFacts(model).baseExtrude {
                model.commitHandle("thick", for: ex.id)
                await TutorialActions.settle(model)
                model.finishFeatureEdit()
            } else {
                await TutorialActions.extrude(base.id, size: "thick", model)
            }
        })

    // MARK: your name

    static let nameSketch = TutorialStep(
        id: "name-sketch", chapter: .tagName,
        title: "Sketch on the tag",
        text: "Your name goes on top of the tag, so it starts as a drawing there. Tap **Sketch**, then tap the top of the tag.",
        kind: .task(done: { TutorialFacts($0).wallSketch != nil }),
        hint: { model in
            if TutorialFacts(model).misplacedWallSketch != nil {
                return .problem("That sketch isn't on top of the tag. Tap **Undo**, tap **Sketch**, then tap the tag's top face.")
            }
            return model.isPickingSketchPlane
                ? .next("Now tap the top of the tag.")
                : .next("Tap **Sketch** in the toolbar.")
        },
        spotlight: { model in model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"] },
        enter: { model in clearPanels(model); model.show(.home) },
        assist: { await TutorialActions.startWallSketch($0) })

    static let nameText = TutorialStep(
        id: "name-text", chapter: .tagName,
        title: "Write your name",
        text: "The **Text** tool is ready. Tap on the tag where the name should start, about a third of the way in: the hole for the ring goes at the left end. Type your name in the box that opens and tap **Done**.",
        kind: .task(done: { model in !(TutorialFacts(model).tagText ?? "").isEmpty }),
        hint: { model in
            guard let session = nameSession(model) else {
                return TutorialFacts(model).wallSketch == nil ? nil : .next("Double-tap the sketch in the browser to open it again.")
            }
            if session.tool != .text { return .next("Choose **Text** in the toolbar, then tap the tag.") }
            return session.pendingText == nil
                ? .next("Tap the tag where the name should start.")
                : .next("Type your name in the box, then tap **Done**.")
        },
        enter: { model in clearPanels(model); model.setSketchTool(.text) },
        assist: { await addName($0) })

    static let finishName = TutorialStep(
        id: "finish-name", chapter: .tagName,
        title: "Finish the sketch",
        text: "Tap **Finish Sketch** once more.",
        kind: .task(done: { model in model.sketchSession?.featureID != TutorialFacts(model).wallSketch?.id }),
        hint: { _ in .next("Tap **Finish Sketch** in the toolbar.") },
        spotlight: { _ in ["Finish Sketch"] },
        assist: { $0.finishSketch() },
        rewind: { model in
            guard let sketch = TutorialFacts(model).wallSketch else { return }
            model.editSketch(sketch.id)
            await TutorialActions.settle(model)
        })

    static let extrudeName = TutorialStep(
        id: "extrude-name", chapter: .tagName,
        title: "Raise the letters",
        text: "Tap **Extrude**, then tap your name: the letters light up together. Type `relief` in the box beside the orange arrow and tap **OK**. The letters join the tag, so it is one piece.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).wallExtrude, ex.value.operation != .newBody, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "relief") && !ex.value.profiles.isEmpty
        }),
        hint: { model in
            let facts = TutorialFacts(model)
            if facts.facePull != nil {
                return .problem("That pulled the whole top of the tag up. Tap **Undo**, then tap the letters of your name.")
            }
            if let ex = facts.wallExtrude {
                if ex.value.operation == .newBody {
                    return .problem("Tap **Join** in the bar at the bottom of the view, so the letters are one piece with the tag.")
                }
                return .next("Type `relief` in the box beside the orange arrow, then tap **OK**.")
            }
            if model.sketchSession != nil { return .next("Tap **Finish Sketch**, then choose Extrude.") }
            return model.pendingTool == .extrude
                ? .next("Now tap your name.")
                : .next("Tap **Extrude** in the toolbar.")
        },
        spotlight: { model in
            let facts = TutorialFacts(model)
            if facts.wallExtrude != nil { return [] }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Extrude"] : []
        },
        enter: { clearPanels($0) },
        assist: { await extrudeName($0) })

    // MARK: the ring hole

    static let ringHole = TutorialStep(
        id: "ring-hole", chapter: .tagRing,
        title: "Drill the ring hole",
        text: "Tap **Hole**, then tap the top of the tag, a little way in from its left end and clear of the letters. Two boxes appear: type `hole` in the one that says 5 mm, the diameter, and tap **OK**. The hole goes right through.",
        kind: .task(done: { model in
            guard let hole = TutorialFacts(model).tagHole else { return false }
            return TutorialFacts.uses(hole.value.diameter, "hole")
        }),
        hint: { model in
            if TutorialFacts(model).tagHole != nil {
                return .next("Type `hole` in the box that says 5 mm (the diameter), then tap **OK**.")
            }
            if model.sketchSession != nil { return .next("Tap **Finish Sketch**, then choose Hole.") }
            return model.pendingTool == .hole
                ? .next("Now tap the top of the tag, a little way in from its left end.")
                : .next("Tap **Hole** in the toolbar.")
        },
        spotlight: { model in
            if TutorialFacts(model).tagHole != nil { return [] }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Hole"] : []
        },
        enter: { model in clearPanels(model); model.show(.home) },
        assist: { await drillHole($0) })

    // MARK: make it yours

    static let change = TutorialStep(
        id: "change", chapter: .tagChange,
        title: "Make it longer",
        text: "In the browser on the left, under **Parameters**, tap the value of `width`, type `75 mm` and tap **Return**; then do the same for `hole` with `6 mm`. The tag grows and the hole widens.",
        kind: .task(done: { model in ["width", "hole"].allSatisfy { TutorialFacts(model).isTagChanged($0) } }),
        hint: { model in
            let facts = TutorialFacts(model)
            return facts.isTagChanged("width")
                ? .next("Now tap the value under `hole`, type `6 mm` and tap **Return**.")
                : .next("Tap the value under `width`, type `75 mm` and tap **Return**.")
        },
        spotlight: { model in
            let facts = TutorialFacts(model)
            return Set(["width", "hole"].filter { !facts.isTagChanged($0) }.map { "parameter-\($0)" })
        },
        enter: { model in
            model.showInspector = false
            model.showSidebar = true
            model.parametersOpen = true
            model.show(.home)
        },
        assist: { await TutorialActions.resize($0, kind: .nameTag) })

    static let done = TutorialStep(
        id: "done", chapter: .tagChange,
        title: "You made a name tag",
        text: "You named your numbers, drew a tag, raised your name on it, drilled the hole and reshaped it with two values. Share it for printing with the export button at the top right, then thread a ring through the hole. Your keys will never be lonely again.",
        kind: .read(button: "Finish"))

    // MARK: shared hints

    /// The session, when it is the name's sketch that is open.
    private static func nameSession(_ model: DocumentModel) -> SketchSession? {
        guard let session = model.sketchSession, session.featureID == TutorialFacts(model).wallSketch?.id else { return nil }
        return session
    }

    /// What to do next in the tag's outline step, from how far along the drawing is.
    private static func outlineHint(_ model: DocumentModel, sketch: TutorialFacts.Found<SketchFeature>,
                                    outline: TutorialFacts.Outline) -> TutorialHint? {
        switch outline {
        case .plainNumbers:
            return .problem("That rectangle uses plain numbers, so it won't follow your parameters. Tap **Undo** and type `width` and `depth` instead.")
        case .missingParameters(let missing):
            let names = missing.map { "`\($0)`" }.joined(separator: " and ")
            return .problem("The tag should be sized by `width` and `depth`, but \(names) isn't used. Tap a size in the sketch and type \(missing.count == 1 ? "it" : "them") there.")
        case .offOrigin:
            return .problem("The tag should start at the origin and grow up and to the right. Tap **Undo**, then tap the origin, the point in the middle of the grid.")
        case .missing, .good:
            break
        }
        guard let session = model.sketchSession, session.featureID == sketch.id else {
            return .next("Double-tap the sketch in the browser to open it again.")
        }
        if session.tool != .roundedRectangle {
            return .next("Choose **Rounded Rectangle** from the rectangle tools in the toolbar.")
        }
        if session.clicks.isEmpty { return .next("Tap the origin, the point in the middle of the grid.") }
        if session.typed[.width] != nil, session.typed[.height] != nil {
            return .next("Tap **OK** on the number pad, then **OK** again at the bottom of the view to place the tag.")
        }
        return .next("Type `width`, `depth` and `depth / 4` in the three boxes. On the number pad, **param** lists your parameters and the arrow goes to the next box.")
    }

    // MARK: doing it for the user

    /// The tag's rounded rectangle, drawn like a finger would: the tool, a tap on the origin, then the three sizes typed.
    static func drawTag(_ model: DocumentModel) async {
        guard let base = TutorialFacts(model).baseSketch else { return }
        if model.sketchSession?.featureID != base.id {
            model.cancelTool()
            model.editSketch(base.id)
            await TutorialActions.settle(model)
        }
        guard let session = model.sketchSession, session.featureID == base.id else { return }
        if !session.sketch.curves.isEmpty {
            model.mutate("Clear Sketch") { doc in
                guard let i = doc.index(of: base.id), case .sketch(var sf) = doc.features[i].kind else { return }
                sf.sketch = Sketch()
                doc.features[i].kind = .sketch(sf)
            }
            await TutorialActions.settle(model)
        }
        model.setSketchTool(.roundedRectangle)
        tap(model, .zero)
        _ = model.sketchMouse(SketchMouse(phase: .moved, uv: SIMD2(12, 12), pick: nil))
        session.setTyped(.width, "width")
        session.setTyped(.height, "depth")
        session.setTyped(.radius, "depth / 4")
        model.commitSketchTyped()
        await TutorialActions.settle(model)
    }

    private static func tap(_ model: DocumentModel, _ uv: SIMD2<Double>) {
        for phase in [SketchMouse.Phase.moved, .down, .up] { _ = model.sketchMouse(SketchMouse(phase: phase, uv: uv, pick: nil)) }
    }

    /// Where the name starts: a third of the way along the tag, with the letters (10 mm tall) halfway up.
    private static func nameStart(_ model: DocumentModel) -> SIMD2<Double> {
        let p = model.parameterValues
        let width = (try? p.value(of: "width", kind: .length)) ?? 60, depth = (try? p.value(of: "depth", kind: .length)) ?? 25
        return SIMD2(width / 3, (depth - 10) / 2)
    }

    /// The name, typed on the tag with the text tool.
    static func addName(_ model: DocumentModel) async {
        guard let sketch = TutorialFacts(model).wallSketch else { return }
        if model.sketchSession?.featureID != sketch.id {
            model.cancelTool()
            model.editSketch(sketch.id)
            await TutorialActions.settle(model)
        }
        guard let session = model.sketchSession, session.featureID == sketch.id else { return }
        // Words that are there already (a first attempt) are replaced, not doubled.
        if !session.sketch.texts.isEmpty {
            model.mutate("Clear Sketch") { doc in
                guard let i = doc.index(of: sketch.id), case .sketch(var sf) = doc.features[i].kind else { return }
                sf.sketch = Sketch()
                doc.features[i].kind = .sketch(sf)
            }
            await TutorialActions.settle(model)
        }
        model.setSketchTool(.text)
        tap(model, nameStart(model))
        let words = sampleName
        model.sketchCommand { $0.placeText(words) }
        await TutorialActions.settle(model)
    }

    /// The letters raised by `relief`, joined to the tag.
    static func extrudeName(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        guard let sketch = facts.wallSketch else { return }
        if let pulled = facts.facePull {
            model.finishFeatureEdit()
            model.deleteFeature(pulled.id)
            await TutorialActions.settle(model)
        }
        if let ex = TutorialFacts(model).wallExtrude {
            if ex.value.operation == .newBody {
                model.updateFeature(ex.id, "Change Operation") { f in
                    if case .extrude(var e) = f.kind { e.operation = .join; f.kind = .extrude(e) }
                }
                await TutorialActions.settle(model)
            }
            model.commitHandle("relief", for: ex.id)
            await TutorialActions.settle(model)
            model.finishFeatureEdit()
            return
        }
        await TutorialActions.extrude(sketch.id, size: "relief", model)
    }

    /// A hole through the left end of the tag, as a tap there with the Hole tool would make it, then its diameter.
    static func drillHole(_ model: DocumentModel) async {
        let facts = TutorialFacts(model)
        guard let tag = facts.baseExtrude else { return }
        if let existing = facts.tagHole {
            model.commitHandle("hole", for: existing.id, slot: 1)
            await TutorialActions.settle(model)
            model.finishFeatureEdit()
            return
        }
        if model.sketchSession != nil { model.finishSketch(); await TutorialActions.settle(model) }
        model.cancelTool()
        model.clearSelection()
        model.run(.hole)
        guard let index = model.meshes.firstIndex(where: { $0.id == tag.id }),
              let face = model.meshes[index].mesh.faceNames.firstIndex(where: { $0 == "\(tag.id).end" })
                ?? model.meshes[index].mesh.faceNames.firstIndex(where: { $0.hasSuffix(".end") }) else { return }
        // A tap from straight above, a hole's width in from the left end and halfway up.
        let p = model.parameterValues
        let depth = (try? p.value(of: "depth", kind: .length)) ?? 25, thick = (try? p.value(of: "thick", kind: .length)) ?? 3
        model.clickRay = (SIMD3(depth / 3, depth / 2, thick + 50), SIMD3(0, 0, -1))
        model.click(PickID(body: index, face: face), additive: false)
        await TutorialActions.settle(model)
        guard let hole = TutorialFacts(model).tagHole else { return }
        model.commitHandle("hole", for: hole.id, slot: 1)
        await TutorialActions.settle(model)
        model.finishFeatureEdit()
    }
}

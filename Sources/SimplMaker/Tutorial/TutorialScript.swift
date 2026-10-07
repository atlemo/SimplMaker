// The tutorial: a phone stand, in 15 steps.
//
// A few named numbers (width, depth, thickness, backrest, lean) drive a sketch and an extrude for the base,
// then a plane that leans by `lean`, a second sketch on it and an extrude for the backrest. The last step
// changes `width` and watches a phone stand turn into a tablet stand.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

@MainActor
enum TutorialScript {
    /// ", or press **E**" for a tool that has a shortcut now (the user can change them, or remove one).
    private static func orPress(_ tool: DesignTool) -> String {
        Shortcuts.label(.tool(tool)).map { ", or press **\($0)**" } ?? ""
    }

    static let steps: [TutorialStep] = [
        welcome, look, parameters,
        sketchPlane, baseRectangle, finishBase, extrudeBase,
        plane, tilt, backSketch, backRectangle, finishBack, extrudeBack,
        change, done,
    ]

    static func step(_ id: String) -> TutorialStep? { steps.first { $0.id == id } }

    // MARK: get started

    static let welcome = TutorialStep(
        id: "welcome", chapter: .start,
        title: "Make a phone stand",
        text: "We'll build one together, a step at a time. It takes about five minutes, and you can leave whenever you like.",
        kind: .read(button: "Let's start"))

    static let look = TutorialStep(
        id: "look", chapter: .start,
        title: "Find your way around",
        text: "**Drag** on empty space to orbit, **pinch** or use the wheel to zoom, **scroll** with two fingers to pan. The cube in the corner jumps to standard views. The **browser** on the left lists everything in your part, and the **inspector** on the right shows what you select.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["browser", "inspector"] },
        enter: { $0.showSidebar = true; $0.showInspector = true })

    static let parameters = TutorialStep(
        id: "parameters", chapter: .start,
        title: "Name your numbers",
        text: "A **parameter** is a number with a name. Five are now in the browser: `width`, `depth`, `thickness`, `backrest` and `lean`. Use a name instead of a number and the whole part follows when you change it. That is what makes a model *parametric*.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["parameters"] },
        enter: { model in
            model.showSidebar = true
            TutorialActions.seedParameters(model)
        })

    // MARK: the base

    static let sketchPlane = TutorialStep(
        id: "sketch-plane", chapter: .base,
        title: "Start with a sketch",
        text: "Every solid begins as a flat drawing. Click **Sketch** in the toolbar, then choose where to draw: the square labelled **XY** is the floor.",
        kind: .task(done: { TutorialFacts($0).baseSketch != nil }),
        hint: { model in
            if TutorialFacts(model).misplacedSketch != nil {
                return .problem("That sketch is on the wrong plane. Press ⌘Z to undo it, then pick the square labelled **XY**.")
            }
            return model.isPickingSketchPlane
                ? .next("Now click the square labelled **XY**.")
                : .next("Click **Sketch** in the toolbar.")
        },
        spotlight: { model in model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"] },
        assist: { await TutorialActions.startBaseSketch($0) })

    static let baseRectangle = TutorialStep(
        id: "base-rectangle", chapter: .base,
        title: "Draw the base",
        text: "The phone will sit on this. The **rectangle** tool is ready: click the **origin**, the point in the middle of the grid, then move the mouse **down and to the right**. Press **Tab**, type `width`, press **Tab** again, type `depth` and press **Return**. Typing a name instead of a number is the trick.",
        kind: .task(done: { model in
            guard let base = TutorialFacts(model).baseSketch else { return false }
            return TutorialFacts.baseOutline(of: base.value.sketch) == .good
        }),
        hint: { model in
            guard let base = TutorialFacts(model).baseSketch else { return nil }
            return rectangleHint(model, sketch: base, outline: TutorialFacts.baseOutline(of: base.value.sketch),
                                 across: "width", along: "depth", direction: "down and to the right")
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { model in
            guard let base = TutorialFacts(model).baseSketch else { return }
            await TutorialActions.drawRectangle(in: base.id, across: "width", along: "depth", growing: .rightDown, model)
        })

    static let finishBase = TutorialStep(
        id: "finish-base", chapter: .base,
        title: "Finish the sketch",
        text: "Press **Return**, or click **Finish Sketch**, to leave sketch mode. The rectangle is now a profile that can be extruded.",
        // Done once the base's sketch isn't being edited: sketching the backrest later must not bring this step back.
        kind: .task(done: { model in model.sketchSession?.featureID != TutorialFacts(model).baseSketch?.id }),
        hint: { _ in .next("Press **Return** or click **Finish Sketch**.") },
        spotlight: { _ in ["Finish Sketch"] },
        assist: { $0.finishSketch() },
        rewind: { model in
            guard let base = TutorialFacts(model).baseSketch else { return }
            model.editSketch(base.id)
            await TutorialActions.settle(model)
        })

    static let extrudeBase = TutorialStep(
        id: "extrude-base", chapter: .base,
        title: "Pull it up",
        text: "**Extrude** turns a flat profile into a solid. Click **Extrude**, then click inside the rectangle. An orange arrow appears: type `thickness` in the field beside it and press **Return**.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).baseExtrude, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "thickness")
        }),
        hint: { model in
            if TutorialFacts(model).baseExtrude != nil {
                return .next("Type `thickness` in the field beside the orange arrow, then press **Return**.")
            }
            // Sketch mode has no Extrude button (and E is Extend there): the sketch has to be finished first.
            if model.sketchSession != nil { return .next("Press **Return** or click **Finish Sketch**, then choose Extrude.") }
            return model.pendingTool == .extrude
                ? .next("Now click inside the rectangle.")
                : .next("Click **Extrude** in the toolbar\(orPress(.extrude)).")
        },
        spotlight: { model in
            if TutorialFacts(model).baseExtrude != nil { return [] }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Extrude"] : []
        },
        assist: { model in
            guard let base = TutorialFacts(model).baseSketch else { return }
            if let ex = TutorialFacts(model).baseExtrude {
                model.commitHandle("thickness", for: ex.id)
                await TutorialActions.settle(model)
                model.finishFeatureEdit()
            } else {
                await TutorialActions.extrude(base.id, size: "thickness", model)
            }
        })

    // MARK: the backrest

    static let plane = TutorialStep(
        id: "plane", chapter: .backrest,
        title: "Add a plane",
        text: "The backrest has to lean back, and a sketch can only lean if it sits on a plane that does. Make one: click **Plane**, click the **XY** square, then press **Return** to keep the 10 mm offset.",
        kind: .task(done: { TutorialFacts($0).planeIsSettled }),
        hint: { model in
            if TutorialFacts(model).plane != nil { return .next("Press **Return** to keep the offset.") }
            return model.pendingTool == .plane
                ? .next("Click the square labelled **XY**.")
                : .next("Click **Plane** in the toolbar\(orPress(.plane)).")
        },
        spotlight: { model in model.pendingTool == nil && TutorialFacts(model).plane == nil ? ["Plane"] : [] },
        enter: { $0.show(.home) },
        assist: { await TutorialActions.makePlane($0) })

    static let tilt = TutorialStep(
        id: "tilt", chapter: .backrest,
        title: "Make it lean",
        text: "The new plane is selected. In the inspector, type `lean` in the **Angle** field and press **Return**. The plane tilts, and changing `lean` later will tilt it again.",
        kind: .task(done: { TutorialFacts($0).planeLeans }),
        hint: { model in
            guard let plane = TutorialFacts(model).plane else { return nil }
            if model.newFeature == plane.id { return .next("Press **Return** to keep the offset first.") }
            if model.selectedFeature != plane.id { return .next("Select the plane: click **\(model.featureName(plane.id))** in the browser.") }
            if !TutorialFacts.uses(plane.value.angle, "lean"), plane.value.angle != "0 deg" {
                return .problem("The angle is a plain number, so `lean` won't change it. Type `lean` in the **Angle** field instead.")
            }
            return .next("Type `lean` in the **Angle** field in the inspector, then press **Return**.")
        },
        spotlight: { model in
            guard let plane = TutorialFacts(model).plane, model.selectedFeature == plane.id, model.newFeature != plane.id else { return ["browser"] }
            return ["inspector"]
        },
        // Selected for the user: the inspector then has its Angle field ready.
        enter: { model in
            model.showInspector = true
            model.showSidebar = true
            if let plane = TutorialFacts(model).plane, model.newFeature != plane.id {
                model.selection = []
                model.selectedFeature = plane.id
            }
        },
        assist: { await TutorialActions.tiltPlane($0) })

    static let backSketch = TutorialStep(
        id: "back-sketch", chapter: .backrest,
        title: "Sketch on the plane",
        text: "A sketch starts on the plane that is selected, and the leaning plane still is. Click **Sketch**. (If it isn't, click the plane, or its name in the browser, first.)",
        kind: .task(done: { TutorialFacts($0).backSketch != nil }),
        hint: { model in
            if TutorialFacts(model).misplacedBackSketch != nil {
                return .problem("That sketch isn't on the leaning plane. Press ⌘Z to undo it, then click the plane and click **Sketch**.")
            }
            if model.isPickingSketchPlane { return .next("Click the leaning plane, the tilted square standing over the base.") }
            guard let plane = TutorialFacts(model).plane else { return nil }
            return model.selectedFeature == plane.id
                ? .next("Click **Sketch** in the toolbar.")
                : .next("Select the leaning plane: click it, or click **\(model.featureName(plane.id))** in the browser.")
        },
        spotlight: { model in
            guard let plane = TutorialFacts(model).plane, model.selectedFeature == plane.id else { return [] }
            return model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"]
        },
        assist: { await TutorialActions.startBackSketch($0) })

    static let backRectangle = TutorialStep(
        id: "back-rectangle", chapter: .backrest,
        title: "Draw the backrest",
        text: "Click the **origin**, then move the mouse **up and to the right**. Press **Tab**, type `width`, press **Tab**, type `backrest` and press **Return**. Using `width` again keeps the backrest as wide as the base.",
        kind: .task(done: { model in
            guard let back = TutorialFacts(model).backSketch else { return false }
            return TutorialFacts.backOutline(of: back.value.sketch) == .good
        }),
        hint: { model in
            guard let back = TutorialFacts(model).backSketch else { return nil }
            return rectangleHint(model, sketch: back, outline: TutorialFacts.backOutline(of: back.value.sketch),
                                 across: "width", along: "backrest", direction: "up and to the right")
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { model in
            guard let back = TutorialFacts(model).backSketch else { return }
            await TutorialActions.drawRectangle(in: back.id, across: "width", along: "backrest", growing: .rightUp, model)
        })

    static let finishBack = TutorialStep(
        id: "finish-back", chapter: .backrest,
        title: "Finish the sketch",
        text: "Press **Return**, or click **Finish Sketch**, once more.",
        kind: .task(done: { model in model.sketchSession?.featureID != TutorialFacts(model).backSketch?.id }),
        hint: { _ in .next("Press **Return** or click **Finish Sketch**.") },
        spotlight: { _ in ["Finish Sketch"] },
        assist: { $0.finishSketch() },
        rewind: { model in
            guard let back = TutorialFacts(model).backSketch else { return }
            model.editSketch(back.id)
            await TutorialActions.settle(model)
        })

    static let extrudeBack = TutorialStep(
        id: "extrude-back", chapter: .backrest,
        title: "Give it thickness",
        text: "Click **Extrude** and click inside the new rectangle. Type `thickness` again. It joins the base, so the stand is one piece.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).backExtrude, ex.value.operation != .newBody, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "thickness")
        }),
        hint: { model in
            if let ex = TutorialFacts(model).backExtrude {
                if ex.value.operation == .newBody {
                    return .problem("Set **Operation** to **Join** in the inspector, so the backrest is one piece with the base.")
                }
                return .next("Type `thickness` in the field beside the orange arrow, then press **Return**.")
            }
            if model.sketchSession != nil { return .next("Press **Return** or click **Finish Sketch**, then choose Extrude.") }
            return model.pendingTool == .extrude
                ? .next("Now click inside the new rectangle.")
                : .next("Click **Extrude** in the toolbar\(orPress(.extrude)).")
        },
        spotlight: { model in
            if let ex = TutorialFacts(model).backExtrude { return ex.value.operation == .newBody ? ["inspector"] : [] }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Extrude"] : []
        },
        enter: { $0.showInspector = true },
        assist: { model in
            guard let back = TutorialFacts(model).backSketch else { return }
            if let ex = TutorialFacts(model).backExtrude {
                if ex.value.operation == .newBody {
                    model.updateFeature(ex.id, "Change Operation") { f in
                        if case .extrude(var e) = f.kind { e.operation = .join; f.kind = .extrude(e) }
                    }
                    await TutorialActions.settle(model)
                }
                model.commitHandle("thickness", for: ex.id)
                await TutorialActions.settle(model)
                model.finishFeatureEdit()
            } else {
                await TutorialActions.extrude(back.id, size: "thickness", model)
            }
        })

    // MARK: make it yours

    static let change = TutorialStep(
        id: "change", chapter: .change,
        title: "Now make it a tablet stand",
        text: "In the browser, under **Parameters**, change `width` to `190 mm` and press **Return**. The whole stand follows, and your phone stand is now wide enough for a tablet. Try `lean` and `backrest` too.",
        kind: .task(done: { TutorialFacts($0).parametersChanged }),
        hint: { _ in .next("Click the value under `width`, type `190 mm` and press **Return**.") },
        spotlight: { _ in ["parameter-width"] },
        enter: { $0.showSidebar = true; $0.show(.home) },
        assist: { await TutorialActions.widen($0) })

    static let done = TutorialStep(
        id: "done", chapter: .change,
        title: "You made a phone stand",
        text: "You sketched with parameters, extruded, tilted a plane and reshaped the whole part with one number. Save it with **⌘S**, or export it for printing with **File ▸ Export STL**. Next, try a **Fillet** on the edges, or a **Hole** for a charging cable.",
        kind: .read(button: "Finish"))

    // MARK: shared hints

    /// What to do next in a rectangle step, from how far along the drawing is.
    private static func rectangleHint(_ model: DocumentModel, sketch: TutorialFacts.Found<SketchFeature>, outline: TutorialFacts.Outline,
                                      across: String, along: String, direction: String) -> TutorialHint? {
        switch outline {
        case .plainNumbers:
            return .problem("That rectangle uses plain numbers, so it won't follow your parameters. Press ⌘Z and type `\(across)` and `\(along)` instead.")
        case .missingParameters(let missing):
            let names = missing.map { "`\($0)`" }.joined(separator: " and ")
            return .problem("The rectangle should be sized by `\(across)` and `\(along)`, but \(names) isn't used. Click a size in the sketch and type \(missing.count == 1 ? "it" : "them") there.")
        case .offOrigin:
            return .problem("The rectangle should start at the origin and grow \(direction). Press ⌘Z, click the origin, then move the mouse \(direction) before you press **Tab**.")
        case .missing, .good:
            break
        }
        guard let session = model.sketchSession, session.featureID == sketch.id else {
            return .next("Double-click the sketch in the browser to open it again.")
        }
        if session.tool != .rectangle {
            return .next("Choose the rectangle: \(SketchTool.rectangle.keyLabel.map { "press **\($0)** until" } ?? "pick it in the toolbar until") the status bar says *Click two opposite corners*.")
        }
        if session.clicks.isEmpty { return .next("Click the origin, the point in the middle of the grid.") }
        return .next("Move the mouse \(direction), press **Tab**, type `\(across)`, press **Tab**, type `\(along)`, then press **Return**.")
    }
}

// The tutorial: a box with a lid, in 17 steps.
//
// A few named numbers (width, depth, height, wall) drive a sketch, an extrude and a shell for the
// box, then a plane, a second sketch and extrude for the lid, which gets a fillet, a hole and an M6
// thread. The last step changes `width` and watches everything follow.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

@MainActor
enum TutorialScript {
    static let steps: [TutorialStep] = [
        welcome, look, parameters,
        sketchPlane, boxRectangle, finishSketch, extrudeBox, shell,
        plane, lidSketch, lidRectangle, extrudeLid,
        fillet, hole, thread,
        change, done,
    ]

    static func step(_ id: String) -> TutorialStep? { steps.first { $0.id == id } }

    // MARK: get started

    static let welcome = TutorialStep(
        id: "welcome", chapter: .start,
        title: "Make a box with a lid",
        text: "We'll build it together, a step at a time: sketch an outline, pull it up into a solid, hollow it out, round it, drill a hole and cut a screw thread. A few named numbers keep it all adjustable. It takes about ten minutes, and you can leave whenever you like.",
        kind: .read(button: "Let's start"))

    static let look = TutorialStep(
        id: "look", chapter: .start,
        title: "Find your way around",
        text: "**Drag** on empty space to orbit the view, **pinch** or use the mouse wheel to zoom, and **scroll** with two fingers to pan. The cube in the corner jumps to standard views. The **browser** on the left lists everything in your part, and the **inspector** on the right shows the details of whatever you select.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["browser", "inspector"] },
        enter: { $0.showSidebar = true; $0.showInspector = true })

    static let parameters = TutorialStep(
        id: "parameters", chapter: .start,
        title: "Name your numbers",
        text: "A **parameter** is a number with a name. Four are now in the browser: `width`, `depth`, `height` and `wall`. Instead of typing 60 you'll type `width`, so changing it later reshapes the whole part. That is what makes a model *parametric*.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["parameters"] },
        enter: { model in
            model.showSidebar = true
            TutorialActions.seedParameters(model)
        })

    // MARK: the box

    static let sketchPlane = TutorialStep(
        id: "sketch-plane", chapter: .box,
        title: "Start with a sketch",
        text: "Every solid begins as a flat drawing. Click **Sketch** in the toolbar, then choose where to draw: the square labelled **XY** is the floor.",
        kind: .task(done: { TutorialFacts($0).boxSketch != nil }),
        hint: { model in
            if TutorialFacts(model).misplacedSketch != nil {
                return .problem("That sketch is on the wrong plane. Press ⌘Z to undo it, then pick the square labelled **XY**.")
            }
            return model.isPickingSketchPlane
                ? .next("Now click the square labelled **XY**.")
                : .next("Click **Sketch** in the toolbar.")
        },
        spotlight: { model in model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"] },
        assist: { await TutorialActions.startBoxSketch($0) })

    static let boxRectangle = TutorialStep(
        id: "box-rectangle", chapter: .box,
        title: "Draw the outline",
        text: "The **center rectangle** tool is ready. Click the **origin**, the point in the middle of the grid, to set the center. Then press **Tab**, type `width`, press **Tab** again, type `depth` and press **Return**. Typing a name instead of a number is the trick.",
        kind: .task(done: { model in
            guard let box = TutorialFacts(model).boxSketch else { return false }
            return TutorialFacts.outline(of: box.value.sketch) == .good
        }),
        hint: { model in
            guard let box = TutorialFacts(model).boxSketch else { return nil }
            return rectangleHint(model, sketch: box)
        },
        enter: { $0.setSketchTool(.centerRectangle) },
        assist: { model in
            guard let box = TutorialFacts(model).boxSketch else { return }
            await TutorialActions.drawRectangle(in: box.id, model)
        })

    static let finishSketch = TutorialStep(
        id: "finish-sketch", chapter: .box,
        title: "Finish the sketch",
        text: "Press **Return**, or click **Finish Sketch**, to leave sketch mode. The rectangle is now a profile that can be extruded.",
        // Done once the box's sketch isn't being edited: drawing the lid's sketch later must not bring this step back.
        kind: .task(done: { model in model.sketchSession?.featureID != TutorialFacts(model).boxSketch?.id }),
        hint: { _ in .next("Press **Return** or click **Finish Sketch**.") },
        spotlight: { _ in ["Finish Sketch"] },
        assist: { $0.finishSketch() })

    static let extrudeBox = TutorialStep(
        id: "extrude-box", chapter: .box,
        title: "Pull it up",
        text: "**Extrude** turns a flat profile into a solid. Click **Extrude**, then click inside the rectangle. An orange arrow appears: type `height` in the field beside it and press **Return**.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).boxExtrude, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "height")
        }),
        hint: { model in
            if TutorialFacts(model).boxExtrude != nil {
                return .next("Type `height` in the field beside the orange arrow, then press **Return**.")
            }
            return model.pendingTool == .extrude
                ? .next("Now click inside the rectangle.")
                : .next("Click **Extrude** in the toolbar, or press **E**.")
        },
        spotlight: { model in model.pendingTool == nil && TutorialFacts(model).boxExtrude == nil ? ["Extrude"] : [] },
        enter: { $0.show(.home) },
        assist: { model in
            guard let box = TutorialFacts(model).boxSketch else { return }
            if let ex = TutorialFacts(model).boxExtrude {
                model.commitHandle("height", for: ex.id)
                await TutorialActions.settle(model)
                model.finishFeatureEdit()
            } else {
                await TutorialActions.extrude(box.id, size: "height", newBody: false, model)
            }
        })

    static let shell = TutorialStep(
        id: "shell", chapter: .box,
        title: "Hollow it out",
        text: "**Shell** turns a solid into a thin-walled shape. Click **Shell**, click the **top face** (the one facing up) and press **Return**. Then type `wall` as the thickness.",
        kind: .task(done: { model in
            let facts = TutorialFacts(model)
            guard let shell = facts.shell, let top = facts.boxTopFace, shell.value.faces.contains(top) else { return false }
            return TutorialFacts.uses(shell.value.thickness, "wall")
        }),
        hint: { model in
            let facts = TutorialFacts(model)
            if let shell = facts.shell {
                if let top = facts.boxTopFace, !shell.value.faces.contains(top) {
                    return .problem("That opened a side, not the top. Press ⌘Z and click the top face instead.")
                }
                return .next("Type `wall` in the thickness field, then press **Return**.")
            }
            if model.pendingTool == .shell {
                return model.selection.contains(where: \.isFace)
                    ? .next("Press **Return** to hollow it out.")
                    : .next("Click the top face of the box.")
            }
            return .next("Click **Shell** in the toolbar, or press **S**.")
        },
        spotlight: { model in model.pendingTool == nil && TutorialFacts(model).shell == nil ? ["Shell"] : [] },
        assist: { await TutorialActions.shell($0) })

    // MARK: the lid

    static let plane = TutorialStep(
        id: "plane", chapter: .lid,
        title: "A plane for the lid",
        text: "The lid will rest on top of the box, and a sketch needs a flat surface to draw on. Make one: click **Plane**, click the **XY** square, then type `height` as the offset so it floats exactly at the rim.",
        kind: .task(done: { model in
            guard let plane = TutorialFacts(model).plane else { return false }
            return TutorialFacts.uses(plane.value.offset, "height")
        }),
        hint: { model in
            if TutorialFacts(model).plane != nil {
                return .next("Type `height` in the offset field, then press **Return**.")
            }
            return model.pendingTool == .plane
                ? .next("Click the square labelled **XY**.")
                : .next("Click **Plane** in the toolbar, or press **N**.")
        },
        spotlight: { model in model.pendingTool == nil && TutorialFacts(model).plane == nil ? ["Plane"] : [] },
        assist: { await TutorialActions.plane($0) })

    static let lidSketch = TutorialStep(
        id: "lid-sketch", chapter: .lid,
        title: "Sketch on the plane",
        text: "Click **Sketch** again, then click the new plane, the thin square at the top of the box.",
        kind: .task(done: { TutorialFacts($0).lidSketch != nil }),
        hint: { model in
            model.isPickingSketchPlane
                ? .next("Click the plane at the top of the box.")
                : .next("Click **Sketch** in the toolbar.")
        },
        spotlight: { model in model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"] },
        assist: { await TutorialActions.startLidSketch($0) })

    static let lidRectangle = TutorialStep(
        id: "lid-rectangle", chapter: .lid,
        title: "Draw the lid",
        text: "The same again: click the **origin**, press **Tab**, type `width`, **Tab**, `depth`, then **Return**. Using the same names keeps the lid exactly the size of the box.",
        kind: .task(done: { model in
            guard let lid = TutorialFacts(model).lidSketch else { return false }
            return TutorialFacts.outline(of: lid.value.sketch) == .good
        }),
        hint: { model in
            guard let lid = TutorialFacts(model).lidSketch else { return nil }
            return rectangleHint(model, sketch: lid)
        },
        enter: { $0.setSketchTool(.centerRectangle) },
        assist: { model in
            guard let lid = TutorialFacts(model).lidSketch else { return }
            await TutorialActions.drawRectangle(in: lid.id, model)
        })

    static let extrudeLid = TutorialStep(
        id: "extrude-lid", chapter: .lid,
        title: "Give the lid some thickness",
        text: "Finish the sketch, click **Extrude** and click inside the new rectangle. Type `wall * 2` as the distance: a parameter can be part of a sum. Then choose **New** beside the field (or **Operation ▸ New Body** in the inspector), so the lid stays a part of its own instead of fusing with the box.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).lidExtrude, ex.value.operation == .newBody,
                  let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "wall")
        }),
        hint: { model in
            if let ex = TutorialFacts(model).lidExtrude {
                if ex.value.operation != .newBody {
                    return .problem("Choose **New** beside the size field, or set **Operation** to **New Body** in the inspector, so the lid is separate from the box.")
                }
                return .next("Type `wall * 2` in the field beside the orange arrow, then press **Return**.")
            }
            // Sketch mode has no Extrude button (and E is Extend there): the sketch has to be finished first.
            if model.sketchSession != nil { return .next("Press **Return** or click **Finish Sketch**, then choose Extrude.") }
            return model.pendingTool == .extrude
                ? .next("Now click inside the new rectangle.")
                : .next("Click **Extrude** in the toolbar, or press **E**.")
        },
        spotlight: { model in
            if let ex = TutorialFacts(model).lidExtrude { return ex.value.operation == .newBody ? [] : ["inspector"] }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Extrude"] : []
        },
        enter: { $0.showInspector = true },
        assist: { model in
            guard let lid = TutorialFacts(model).lidSketch else { return }
            if let ex = TutorialFacts(model).lidExtrude {
                model.updateFeature(ex.id, "Change Operation") { f in
                    if case .extrude(var e) = f.kind { e.operation = .newBody; f.kind = .extrude(e) }
                }
                await TutorialActions.settle(model)
                model.commitHandle("wall * 2", for: ex.id)
                await TutorialActions.settle(model)
                model.finishFeatureEdit()
            } else {
                await TutorialActions.extrude(lid.id, size: "wall * 2", newBody: true, model)
            }
        })

    // MARK: the details

    static let fillet = TutorialStep(
        id: "fillet", chapter: .details,
        title: "Round the lid",
        text: "**Fillet** rounds sharp edges. Click **Fillet**, click the lid's **top face** to pick every edge around it, and press **Return**. Type `wall` as the radius.",
        kind: .task(done: { model in
            guard let fillet = TutorialFacts(model).lidFillet, model.result?.errors[fillet.id] == nil else { return false }
            return DocumentModel.isParametric(fillet.value.size)
        }),
        hint: { model in
            let facts = TutorialFacts(model)
            if let fillet = facts.lidFillet {
                if let error = model.result?.errors[fillet.id] {
                    return .problem("That radius doesn't fit: \(error) Try `wall`, or something smaller.")
                }
                return .next("Type `wall` in the radius field, then press **Return**.")
            }
            if model.pendingTool == .fillet {
                return model.selection.isEmpty ? .next("Click the top face of the lid.") : .next("Press **Return** to round the edges.")
            }
            return .next("Click **Fillet** in the toolbar, or press **F**.")
        },
        spotlight: { model in model.pendingTool == nil && TutorialFacts(model).lidFillet == nil ? ["Fillet"] : [] },
        enter: { $0.show(.home) },
        assist: { await TutorialActions.fillet($0) })

    static let hole = TutorialStep(
        id: "hole", chapter: .details,
        title: "Drill a hole",
        text: "Click **Hole**, then click the middle of the lid's top face: it snaps to the center. The hole is 5 mm across, the right size to tap an **M6** thread.",
        kind: .task(done: { TutorialFacts($0).lidHole != nil }),
        hint: { model in
            model.pendingTool == .hole
                ? .next("Click the middle of the lid's top face.")
                : .next("Click **Hole** in the toolbar, or press **H**.")
        },
        spotlight: { model in model.pendingTool == nil ? ["Hole"] : [] },
        assist: { await TutorialActions.hole($0) })

    static let thread = TutorialStep(
        id: "thread", chapter: .details,
        title: "Cut a thread",
        text: "Click **Thread**, then click the lid's top face right next to the hole. The hole's wall lights up as you point at it. SimplMaker picks the size that fits: M6.",
        kind: .task(done: { TutorialFacts($0).lidThread != nil }),
        hint: { model in
            if model.toolMissed { return .problem("That wasn't the hole. Click the top face closer to it.") }
            return model.pendingTool == .thread
                ? .next("Click the lid's top face, close to the hole.")
                : .next("Click **Thread** in the toolbar, or press **D**.")
        },
        spotlight: { model in model.pendingTool == nil ? ["Thread"] : [] },
        assist: { await TutorialActions.thread($0) })

    // MARK: make it yours

    static let change = TutorialStep(
        id: "change", chapter: .change,
        title: "Change your mind",
        text: "Here is the payoff. In the browser, under **Parameters**, change `width` to `80 mm` and press **Return**. The box, the lid, the hole and the thread all follow. Try `height` or `wall` too.",
        kind: .task(done: { TutorialFacts($0).parametersChanged }),
        hint: { _ in .next("Click the value under `width`, type `80 mm` and press **Return**.") },
        spotlight: { _ in ["parameter-width"] },
        enter: { $0.showSidebar = true },
        assist: { await TutorialActions.widen($0) })

    static let done = TutorialStep(
        id: "done", chapter: .change,
        title: "You made a box with a lid",
        text: "You sketched with parameters, extruded, shelled, filleted, drilled and threaded, and you changed the whole part with one number. Save it with **⌘S**, or export it for printing with **File ▸ Export STL**. Next, try a **Pattern** to repeat the hole, or a **Chamfer** on the box.",
        kind: .read(button: "Finish"))

    // MARK: shared hints

    /// What to do next in the rectangle steps, from how far along the drawing is.
    private static func rectangleHint(_ model: DocumentModel, sketch: TutorialFacts.Found<SketchFeature>) -> TutorialHint? {
        switch TutorialFacts.outline(of: sketch.value.sketch) {
        case .plainNumbers:
            return .problem("That rectangle uses plain numbers, so it won't follow your parameters. Press ⌘Z and type `width` and `depth` instead.")
        case .missingParameters(let missing):
            let names = missing.map { "`\($0)`" }.joined(separator: " and ")
            return .problem("The rectangle should be sized by `width` and `depth`, but \(names) isn't used. Click a size in the sketch and type \(missing.count == 1 ? "it" : "them") there.")
        case .offCenter:
            return .problem("That rectangle isn't centered on the origin. Press ⌘Z, then click the origin first.")
        case .missing, .good:
            break
        }
        guard let session = model.sketchSession, session.featureID == sketch.id else {
            return .next("Double-click the sketch in the browser to open it again.")
        }
        if session.tool != .centerRectangle {
            return .next("Choose the center rectangle: press **R** until the status bar says *Click the center*.")
        }
        if session.clicks.isEmpty { return .next("Click the origin, the point in the middle of the grid.") }
        return .next("Press **Tab**, type `width`, press **Tab**, type `depth`, then press **Return**.")
    }
}

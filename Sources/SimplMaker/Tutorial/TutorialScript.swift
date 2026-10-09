// The tutorial: a desk organizer, in 18 steps.
//
// A few named numbers (width, depth, height, wall, front) drive a sketch and an extrude for the floor. A second
// sketch on top of the floor traces its outline, insets it by the wall thickness as a guide, and hangs three
// sections from the guide's corners with sizes typed as expressions. Extruding the thin
// wall that is left raises the walls. The last step changes `width` and `depth` and watches everything follow.
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
        wallSketch, outline, inset, guide, frontSection, backLeft, backRight, finishWalls, extrudeWalls,
        change, done,
    ]

    static func step(_ id: String) -> TutorialStep? { steps.first { $0.id == id } }

    // MARK: get started

    static let welcome = TutorialStep(
        id: "welcome", chapter: .start,
        title: "Make a desk organizer",
        text: "We'll build one together, a step at a time. It takes about ten minutes, and you can leave whenever you like.",
        kind: .read(button: "Let's start"))

    static let look = TutorialStep(
        id: "look", chapter: .start,
        title: "Find your way around",
        text: "**Drag** on empty space to orbit, **pinch** or use the wheel to zoom, **scroll** with two fingers to pan. The cube in the corner jumps to standard views. The **browser** on the left lists everything in your part, and the **inspector** on the right shows what you select.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["browser", "inspector"] },
        enter: { $0.showSidebar = true; $0.browserOpen = true; $0.showInspector = true })

    static let parameters = TutorialStep(
        id: "parameters", chapter: .start,
        title: "Name your numbers",
        text: "A **parameter** is a number with a name. Five are now in the browser: `width`, `depth`, `height`, `wall` and `front`. Use a name instead of a number and the whole part follows when you change it. That is what makes a model *parametric*.",
        kind: .read(button: "Next"),
        spotlight: { _ in ["parameters"] },
        enter: { model in
            model.showSidebar = true
            model.parametersOpen = true
            TutorialActions.seedParameters(model)
        })

    // MARK: the floor

    static let sketchPlane = TutorialStep(
        id: "sketch-plane", chapter: .floor,
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
        id: "base-rectangle", chapter: .floor,
        title: "Draw the floor",
        text: "The organizer stands on this. The **rectangle** tool is ready: click the **origin**, the point in the middle of the grid, then move the mouse **up and to the right**. Press **Tab**, type `width`, press **Tab** again, type `depth` and press **Return**. Typing a name instead of a number is the trick.",
        kind: .task(done: { model in
            guard let base = TutorialFacts(model).baseSketch else { return false }
            return TutorialFacts.baseOutline(of: base.value.sketch) == .good
        }),
        hint: { model in
            guard let base = TutorialFacts(model).baseSketch else { return nil }
            return baseRectangleHint(model, sketch: base, outline: TutorialFacts.baseOutline(of: base.value.sketch))
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { model in
            guard let base = TutorialFacts(model).baseSketch else { return }
            await TutorialActions.drawBaseRectangle(in: base.id, model)
        })

    static let finishBase = TutorialStep(
        id: "finish-base", chapter: .floor,
        title: "Finish the sketch",
        text: "Press **Return**, or click **Finish Sketch**, to leave sketch mode. The rectangle is now a profile that can be extruded.",
        // Done once the floor's sketch isn't being edited: sketching on top of it later must not bring this step back.
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
        id: "extrude-base", chapter: .floor,
        title: "Pull it up",
        text: "**Extrude** turns a flat profile into a solid. Click **Extrude**, then click inside the rectangle. An orange arrow appears: type `wall` in the field beside it and press **Return**. The floor is as thick as the walls will be.",
        kind: .task(done: { model in
            guard let ex = TutorialFacts(model).baseExtrude, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "wall")
        }),
        hint: { model in
            if TutorialFacts(model).baseExtrude != nil {
                return .next("Type `wall` in the field beside the orange arrow, then press **Return**.")
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
                model.commitHandle("wall", for: ex.id)
                await TutorialActions.settle(model)
                model.finishFeatureEdit()
            } else {
                await TutorialActions.extrude(base.id, size: "wall", model)
            }
        })

    // MARK: the walls and sections

    static let wallSketch = TutorialStep(
        id: "wall-sketch", chapter: .walls,
        title: "Sketch on the floor",
        text: "The walls and sections start as a drawing on top of the floor. Click **Sketch**, then click the top of the floor.",
        kind: .task(done: { TutorialFacts($0).wallSketch != nil }),
        hint: { model in
            if TutorialFacts(model).misplacedWallSketch != nil {
                return .problem("That sketch isn't on top of the floor. Press ⌘Z to undo it, click **Sketch**, then click the floor's top face.")
            }
            return model.isPickingSketchPlane
                ? .next("Now click the top of the floor.")
                : .next("Click **Sketch** in the toolbar.")
        },
        spotlight: { model in model.isPickingSketchPlane || model.sketchSession != nil ? [] : ["Sketch"] },
        enter: { $0.show(.home) },
        assist: { await TutorialActions.startWallSketch($0) })

    static let outline = TutorialStep(
        id: "outline", chapter: .walls,
        title: "Trace the floor",
        text: "The rectangle tool is ready. Click two opposite corners of the floor: a corner lights up when the mouse is on it. The outline is now tied to the floor, so it grows and shrinks with it.",
        kind: .task(done: { model in TutorialFacts(model).walls?.outline == .good }),
        hint: { model in
            guard let session = wallSession(model) else { return reopenOrNil(model) }
            if let problem = layoutProblem(model) { return problem }
            if let walls = TutorialFacts(model).walls {
                switch walls.outline {
                case .plainNumbers, .missingParameters:
                    return .problem("That outline has a fixed size, so it won't follow the floor. Press ⌘Z and click two opposite corners of the floor instead.")
                case .missing where !walls.solid.isEmpty:
                    return .problem("That rectangle isn't on the floor's corners. Press ⌘Z, then click two opposite corners of the floor: they light up when the mouse is on them.")
                case .missing, .good:
                    break
                }
            }
            if session.tool != .rectangle { return .next(chooseRectangle) }
            return session.clicks.isEmpty ? .next("Click one corner of the floor.") : .next("Now click the opposite corner of the floor.")
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { await TutorialActions.traceOutline($0) })

    static let inset = TutorialStep(
        id: "inset", chapter: .walls,
        title: "Draw a guide inside it",
        text: "The walls are `wall` thick, so draw a guide that far inside the outline. Double-click one of its lines to select all four, click **Offset**, press **Tab**, type `-wall` (the minus makes it go inwards) and press **Return**.",
        kind: .task(done: { model in
            guard let guide = TutorialFacts(model).walls?.guide else { return false }
            return guide == .solid || guide == .construction
        }),
        hint: { model in
            guard let session = wallSession(model) else { return reopenOrNil(model) }
            if let problem = layoutProblem(model) { return problem }
            guard let walls = TutorialFacts(model).walls else { return nil }
            switch walls.guide {
            case .outward:
                return .problem("That guide grew outwards. Press ⌘Z, click **Offset** again and type `-wall`, with the minus.")
            case .plainNumber:
                return .problem("That guide uses a plain number, so it won't follow `wall`. Press ⌘Z, click **Offset** again and type `-wall`.")
            default:
                break
            }
            if session.isOffsetting { return .next("Press **Tab**, type `-wall` in the field, then press **Return**.") }
            guard let outline = walls.match(walls.layout.outline, in: walls.solid) else { return nil }
            if Set(session.selection) == Set(outline.lines) { return .next("Click **Offset** in the toolbar.") }
            return session.tool == .select
                ? .next("Double-click one line of the outline to select all four.")
                : .next("Choose **Select**\(selectKey), then double-click one line of the outline to select all four.")
        },
        spotlight: { model in
            guard let session = wallSession(model), !session.isOffsetting, let walls = TutorialFacts(model).walls,
                  let outline = walls.match(walls.layout.outline, in: walls.solid), Set(session.selection) == Set(outline.lines) else { return [] }
            return ["Offset"]
        },
        enter: { $0.setSketchTool(.select) },
        assist: { await TutorialActions.insetOutline($0) })

    static let guide = TutorialStep(
        id: "guide", chapter: .walls,
        title: "Make it a guide",
        text: "The four new lines are selected. Click **Construction**: they turn dashed, and from now on they only guide what you draw.",
        kind: .task(done: { model in TutorialFacts(model).walls?.guide == .construction }),
        hint: { model in
            guard let session = wallSession(model) else { return reopenOrNil(model) }
            guard let walls = TutorialFacts(model).walls, let guide = walls.guideBox else { return nil }
            return Set(session.selection) == Set(guide.lines)
                ? .next("Click **Construction** in the toolbar.")
                : .next("Select the four new lines: double-click one of them. Then click **Construction**.")
        },
        spotlight: { model in
            guard let session = wallSession(model), let guide = TutorialFacts(model).walls?.guideBox,
                  Set(session.selection) == Set(guide.lines) else { return [] }
            return ["Construction"]
        },
        enter: { $0.setSketchTool(.select) },
        assist: { await TutorialActions.makeGuide($0) })

    static let frontSection = TutorialStep(
        id: "front-section", chapter: .walls,
        title: "The front section",
        text: "The sections hang from the guide's corners. With the rectangle tool, click the **bottom-left corner** of the dashed square and move the mouse **up and to the right**. Press **Tab**, type `width - 2 * wall`, press **Tab**, type `front` and press **Return**.",
        kind: .task(done: { model in TutorialFacts(model).walls?.frontSection == .good }),
        hint: { model in
            sectionHint(model, name: "front section", corner: "bottom-left corner", direction: "up and to the right",
                        typing: "press **Tab**, type `width - 2 * wall`, press **Tab**, type `front`, then press **Return**.") { $0.frontSection }
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { await TutorialActions.frontSection($0) })

    static let backLeft = TutorialStep(
        id: "back-left", chapter: .walls,
        title: "The left section",
        text: "Click the **top-left corner** of the dashed square and move the mouse **down and to the right**. Press **Tab**, type `(width - 3 * wall) / 2`, press **Tab**, type `depth - 3 * wall - front` and press **Return**. That is half of the width left once the three walls are taken out.",
        kind: .task(done: { model in TutorialFacts(model).walls?.backLeft == .good }),
        hint: { model in
            sectionHint(model, name: "left section", corner: "top-left corner", direction: "down and to the right",
                        typing: "press **Tab**, type `(width - 3 * wall) / 2`, press **Tab**, type `depth - 3 * wall - front`, then press **Return**.") { $0.backLeft }
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { await TutorialActions.backLeftSection($0) })

    static let backRight = TutorialStep(
        id: "back-right", chapter: .walls,
        title: "The right section",
        text: "Click the **top-right corner** of the dashed square and move the mouse **down and to the left**. Press **Tab**, type `(width - 3 * wall) / 2`, press **Tab**, type `depth - 3 * wall - front` and press **Return**. The same sizes as the left section, so the two stay equally deep whatever you do to the parameters.",
        kind: .task(done: { model in TutorialFacts(model).walls?.backRight == .good }),
        hint: { model in
            sectionHint(model, name: "right section", corner: "top-right corner", direction: "down and to the left",
                        typing: "press **Tab**, type `(width - 3 * wall) / 2`, press **Tab**, type `depth - 3 * wall - front`, then press **Return**.") { $0.backRight }
        },
        enter: { $0.setSketchTool(.rectangle) },
        assist: { await TutorialActions.backRightSection($0) })

    static let finishWalls = TutorialStep(
        id: "finish-walls", chapter: .walls,
        title: "Finish the sketch",
        text: "Press **Return**, or click **Finish Sketch**, once more.",
        kind: .task(done: { model in model.sketchSession?.featureID != TutorialFacts(model).wallSketch?.id }),
        hint: { _ in .next("Press **Return** or click **Finish Sketch**.") },
        spotlight: { _ in ["Finish Sketch"] },
        assist: { $0.finishSketch() },
        rewind: { model in
            guard let wall = TutorialFacts(model).wallSketch else { return }
            model.editSketch(wall.id)
            await TutorialActions.settle(model)
        })

    static let extrudeWalls = TutorialStep(
        id: "extrude-walls", chapter: .walls,
        title: "Raise the walls",
        text: "Click **Extrude**, then click the thin wall that is left round and between the sections: it lights up when the mouse is on it. Type `height` in the field beside the orange arrow. The walls join the floor, so the organizer is one piece.",
        kind: .task(done: { model in
            let facts = TutorialFacts(model)
            guard let ex = facts.wallExtrude, ex.value.operation != .newBody, let size = ex.value.extent.size else { return false }
            return TutorialFacts.uses(size, "height") && facts.extrudesTheWall(ex.value)
        }),
        hint: { model in
            let facts = TutorialFacts(model)
            if facts.facePull != nil {
                return .problem("That pulled the whole top of the floor up. Press ⌘Z, then click the thin wall round and between the sections.")
            }
            if let ex = facts.wallExtrude {
                if !facts.extrudesTheWall(ex.value) {
                    return .problem("That filled a section instead of the wall. Press ⌘Z, then click the thin wall round and between the sections.")
                }
                if ex.value.operation == .newBody {
                    return .problem("Set **Operation** to **Join** in the inspector, so the walls are one piece with the floor.")
                }
                return .next("Type `height` in the field beside the orange arrow, then press **Return**.")
            }
            if model.sketchSession != nil { return .next("Press **Return** or click **Finish Sketch**, then choose Extrude.") }
            return model.pendingTool == .extrude
                ? .next("Now click the thin wall, round and between the sections.")
                : .next("Click **Extrude** in the toolbar\(orPress(.extrude)).")
        },
        spotlight: { model in
            let facts = TutorialFacts(model)
            if let ex = facts.wallExtrude {
                if !facts.extrudesTheWall(ex.value) { return [] }
                return ex.value.operation == .newBody ? ["inspector"] : []
            }
            if model.sketchSession != nil { return ["Finish Sketch"] }
            return model.pendingTool == nil ? ["Extrude"] : []
        },
        // From above, the thin wall is as wide on screen as it can be.
        enter: { model in model.showInspector = true; model.show(.top) },
        assist: { await TutorialActions.extrudeWalls($0) })

    // MARK: make it yours

    static let change = TutorialStep(
        id: "change", chapter: .change,
        title: "Make it bigger",
        text: "In the browser, under **Parameters**, change `width` to `190 mm` and `depth` to `120 mm`, pressing **Return** after each. The walls and all three sections follow.",
        kind: .task(done: { TutorialFacts($0).parametersChanged }),
        hint: { model in
            TutorialFacts(model).isChanged("width")
                ? .next("Now click the value under `depth`, type `120 mm` and press **Return**.")
                : .next("Click the value under `width`, type `190 mm` and press **Return**.")
        },
        spotlight: { model in
            let facts = TutorialFacts(model)
            return Set(["width", "depth"].filter { !facts.isChanged($0) }.map { "parameter-\($0)" })
        },
        enter: { $0.showSidebar = true; $0.parametersOpen = true; $0.show(.home) },
        assist: { await TutorialActions.resize($0) })

    static let done = TutorialStep(
        id: "done", chapter: .change,
        title: "You made a desk organizer",
        text: "You named your numbers, sketched with dimensions and a constraint, and reshaped the whole part with two values. Save it with **⌘S**, or export it for printing with **File ▸ Export STL**. Next, try a **Fillet** on the outer corners, or add a fourth section.",
        kind: .read(button: "Finish"))

    // MARK: shared hints

    private static var chooseRectangle: String {
        "Choose the rectangle: \(SketchTool.rectangle.keyLabel.map { "press **\($0)** until" } ?? "pick it in the toolbar until") the status bar says *Click two opposite corners*."
    }

    private static var selectKey: String { SketchTool.select.keyLabel.map { " (press **\($0)**)" } ?? "" }

    /// The session, when it is the walls' sketch that is open.
    private static func wallSession(_ model: DocumentModel) -> SketchSession? {
        guard let session = model.sketchSession, session.featureID == TutorialFacts(model).wallSketch?.id else { return nil }
        return session
    }

    /// What to say when the walls' sketch isn't open: nothing before it exists, else how to open it again.
    private static func reopenOrNil(_ model: DocumentModel) -> TutorialHint? {
        TutorialFacts(model).wallSketch == nil ? nil : .next("Double-click the sketch in the browser to open it again.")
    }

    /// The sizes the sections hang on are missing or leave no room.
    private static func layoutProblem(_ model: DocumentModel) -> TutorialHint? {
        TutorialFacts(model).layout == nil
            ? .problem("The parameters `width`, `depth`, `wall` and `front` need to be there, with room for three sections. **Do it for me** puts them back.")
            : nil
    }

    /// What to do next in a section step, from how far along the drawing is.
    private static func sectionHint(_ model: DocumentModel, name: String, corner: String, direction: String, typing: String,
                                    status: (TutorialFacts.Walls) -> TutorialFacts.Walls.Status) -> TutorialHint? {
        guard let session = wallSession(model) else { return reopenOrNil(model) }
        if let problem = layoutProblem(model) { return problem }
        if let walls = TutorialFacts(model).walls {
            switch status(walls) {
            case .plainNumbers:
                return .problem("That section uses plain numbers, so it won't follow your parameters. Press ⌘Z and type the sizes as shown instead.")
            case .missingParameters(let missing):
                let names = missing.map { "`\($0)`" }.joined(separator: " and ")
                return .problem("The \(name) should be sized with the parameters, but \(names) isn't used. Click a size in the sketch and type \(missing.count == 1 ? "it" : "them") there.")
            case .missing, .good:
                break
            }
            if !walls.strays.isEmpty {
                return .problem("That rectangle isn't where the \(name) goes. Press ⌘Z, then start from the \(corner) of the dashed square.")
            }
        }
        if session.tool != .rectangle { return .next(chooseRectangle) }
        if session.clicks.isEmpty { return .next("Click the \(corner) of the dashed square.") }
        return .next("Move the mouse \(direction), \(typing)")
    }

    /// What to do next in the floor's rectangle step, from how far along the drawing is.
    private static func baseRectangleHint(_ model: DocumentModel, sketch: TutorialFacts.Found<SketchFeature>,
                                          outline: TutorialFacts.Outline) -> TutorialHint? {
        switch outline {
        case .plainNumbers:
            return .problem("That rectangle uses plain numbers, so it won't follow your parameters. Press ⌘Z and type `width` and `depth` instead.")
        case .missingParameters(let missing):
            let names = missing.map { "`\($0)`" }.joined(separator: " and ")
            return .problem("The rectangle should be sized by `width` and `depth`, but \(names) isn't used. Click a size in the sketch and type \(missing.count == 1 ? "it" : "them") there.")
        case .offOrigin:
            return .problem("The rectangle should start at the origin and grow up and to the right. Press ⌘Z, click the origin, then move the mouse up and to the right before you press **Tab**.")
        case .missing, .good:
            break
        }
        guard let session = model.sketchSession, session.featureID == sketch.id else {
            return .next("Double-click the sketch in the browser to open it again.")
        }
        if session.tool != .rectangle { return .next(chooseRectangle) }
        if session.clicks.isEmpty { return .next("Click the origin, the point in the middle of the grid.") }
        return .next("Move the mouse up and to the right, press **Tab**, type `width`, press **Tab**, type `depth`, then press **Return**.")
    }
}

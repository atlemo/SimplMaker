// The Design toolbar's tools: what each one needs, how it asks for it, and the feature it creates.
//
// A tool runs straight away when the selection already has what it needs. Otherwise it waits
// (`pendingTool`): the cursor says what to pick, clicks go to the tool, Return accepts defaults
// (a revolve's axis, a loft's sections, fillet edges) and Esc cancels.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd

enum DesignTool: String, CaseIterable, Identifiable, Sendable {
    case extrude = "Extrude", revolve = "Revolve", sweep = "Sweep", loft = "Loft", rib = "Rib", hole = "Hole"
    case box = "Box", cylinder = "Cylinder", sphere = "Sphere", torus = "Torus", coil = "Coil", pipe = "Pipe"
    case fillet = "Fillet", chamfer = "Chamfer", thread = "Thread", move = "Move", scale = "Scale", combine = "Combine", split = "Split Body"
    case plane = "Plane", mirror = "Mirror", pattern = "Pattern", shell = "Shell", draft = "Draft", canvas = "Canvas"
    case project = "Project"
    case measure = "Measure"

    var id: String { rawValue }

    /// Toolbar and menu groups: shapes built from sketches, ready-made primitives, and tools that
    /// change an existing body.
    static let shapes: [DesignTool] = [.extrude, .revolve, .sweep, .loft, .rib, .pipe]
    static let primitives: [DesignTool] = [.box, .cylinder, .sphere, .torus, .coil]
    static let modifiers: [DesignTool] = [.fillet, .chamfer, .hole, .thread, .shell, .draft, .project, .move, .scale, .combine, .split]
    /// Construction planes, copies of bodies, and reference images.
    static let construct: [DesignTool] = [.plane, .mirror, .pattern, .canvas]
    /// Tools that read the model without changing it.
    static let inspect: [DesignTool] = [.measure]

    /// A glyph name from the macOS Design System's icon set (see IconGlyphs.swift), not an SF Symbol.
    var symbol: String {
        switch self {
        case .extrude: return "extrude"
        case .revolve: return "revolve"
        case .sweep: return "spline"
        case .loft: return "layers-2"
        case .rib: return "square-split-horizontal"
        case .hole: return "hole"
        case .box: return "cuboid"
        case .cylinder: return "cylinder"
        case .sphere: return "globe"
        case .torus: return "torus"
        case .coil: return "orbit"
        case .pipe: return "waypoints"
        case .fillet: return "fillet"
        case .chamfer: return "chamfer"
        case .thread: return "thread"
        case .move: return "move"
        case .scale: return "scaling"
        case .combine: return "combine"
        case .split: return "split-body"
        case .plane: return "plane"
        case .mirror: return "flip-horizontal-2"
        case .pattern: return "pattern"
        case .shell: return "shell"
        case .draft: return "draft"
        case .canvas: return "image"
        case .project: return "square-dashed"
        case .measure: return "ruler"
        }
    }

    /// The single-letter shortcut in the Create and Modify menus (as in Fusion: E extrude, F fillet,
    /// H hole, M move). While sketching, the letters pick sketch tools instead. The user can change it
    /// (see Shortcuts.swift); this is what it starts as.
    var defaultKey: Character {
        switch self {
        case .extrude: return "e"
        case .revolve: return "r"
        case .sweep: return "w"
        case .loft: return "l"
        case .rib: return "b"
        case .pipe: return "p"
        case .box: return "x"
        case .cylinder: return "y"
        case .sphere: return "g"
        case .torus: return "u"
        case .coil: return "k"
        case .fillet: return "f"
        case .chamfer: return "c"
        case .thread: return "d"
        case .hole: return "h"
        case .shell: return "s"
        case .draft: return "d"  // with ⇧ (see defaultModifiers): every plain letter is taken
        case .move: return "m"
        case .scale: return "z"
        case .combine: return "j"
        case .split: return "s"  // with ⇧ (see defaultModifiers): every plain letter is taken
        case .plane: return "n"
        case .mirror: return "q"
        case .pattern: return "t"
        case .canvas: return "v"
        case .project: return "o"
        case .measure: return "i"
        }
    }

    /// Held with the letter by default. Every plain letter has a tool (or Appearance), so a tool added since has ⇧ with one.
    var defaultModifiers: KeyChord.Modifiers { self == .draft || self == .split ? .shift : [] }

    /// The tooltip: the name, its current shortcut, and what the tool does.
    var help: String {
        let name = Shortcuts.label(.tool(self)).map { "\(rawValue) (\($0))" } ?? rawValue
        return "\(name): \(summary)"
    }

    private var summary: String {
        switch self {
        case .extrude: return "push a profile into a solid"
        case .revolve: return "turn a profile around an axis"
        case .sweep: return "move a profile along a path"
        case .loft: return "blend between two or more profiles"
        case .rib: return "a thin wall from an open sketch line to the body"
        case .hole: return "drill a hole in a flat face"
        case .box: return "place a box on a plane or face"
        case .cylinder: return "place a cylinder on a plane or face"
        case .sphere: return "place a sphere on a plane or face"
        case .torus: return "place a torus on a plane or face"
        case .coil: return "place a coil spring on a plane or face"
        case .pipe: return "a round tube along sketch curves"
        case .fillet: return "round the selected edges, or every edge around a selected face"
        case .move: return "slide or turn bodies and sketches with the arrows, squares and rings, or type a distance or an angle"
        case .scale: return "make sketches bigger or smaller, about their origins"
        case .chamfer: return "bevel the selected edges, or every edge around a selected face"
        case .thread: return "cut a metric or inch screw thread on a shaft or in a hole"
        case .combine: return "join, cut or intersect bodies (e.g. cut text out of a plate)"
        case .split: return "divide bodies into new bodies along a plane, a face or a sketch profile"
        case .plane: return "a construction plane, offset or tilted from a plane or flat face, to sketch on or mirror across"
        case .mirror: return "copy bodies across a plane"
        case .pattern: return "copy bodies in a row or around an axis"
        case .shell: return "hollow a body, leaving the picked faces open"
        case .draft: return "lean the picked faces over by a draft angle, so a mould can let go of the part"
        case .canvas: return "place a reference image on a plane or flat face, to trace over; its opacity is adjustable"
        case .project: return "throw sketch profiles, like text, onto a body so they follow its surface, raised out of it or cut into it"
        case .measure: return "click a face, an edge or a body for its size, or two for the distance and angle between them"
        }
    }

    var primitive: PrimitiveKind? {
        switch self {
        case .box: return .box
        case .cylinder: return .cylinder
        case .sphere: return .sphere
        case .torus: return .torus
        case .coil: return .coil
        default: return nil
        }
    }

    /// Placed by clicking a plane or a flat face (the origin planes show while it waits).
    var needsPlane: Bool { primitive != nil || self == .plane || self == .canvas }

    /// A body picked in the browser counts too (a click in the viewport picks a face or an edge).
    var acceptsWholeBody: Bool { picksBodies || self == .measure }

    /// Shows the origin planes while it waits, to pick one (mirror across a plane).
    var showsPlanes: Bool { needsPlane || self == .mirror || self == .split }

    /// Works on whole bodies: a click on any face picks the body (and so does a body in the browser).
    var picksBodies: Bool {
        switch self {
        case .move, .combine, .split, .mirror, .pattern: return true
        default: return false
        }
    }

    /// What a click can pick while this tool waits.
    func accepts(_ kind: PickID.Kind) -> Bool {
        switch self {
        case .extrude: return kind == .region || kind == .face
        case .loft: return kind == .region
        case .revolve, .sweep: return kind == .region || kind == .sketchCurve
        case .rib, .pipe: return kind == .sketchCurve
        case .hole, .thread: return kind == .face
        case .box, .cylinder, .sphere, .torus, .coil: return kind == .plane || kind == .face
        case .fillet, .chamfer: return kind == .edge || kind == .face  // a face: every edge around it
        case .move: return kind == .face || kind == .edge || kind == .region || kind == .sketchCurve
        case .combine: return kind == .face || kind == .edge
        case .split: return kind == .face || kind == .plane || kind == .region  // the bodies, then the plane, profile or face
        case .scale: return kind == .region || kind == .sketchCurve
        case .plane, .canvas: return kind == .plane || kind == .face
        case .mirror: return kind == .face || kind == .edge || kind == .plane  // bodies, then the plane
        case .pattern: return kind == .face || kind == .edge  // bodies (faces), and a straight edge for the direction
        case .shell: return kind == .face  // the faces to leave open
        case .draft: return kind == .face  // the faces to lean
        case .project: return kind == .region || kind == .face  // the profiles, and the faces they land on
        case .measure: return kind == .face || kind == .edge  // and bodies, from the browser
        }
    }
}

extension DocumentModel {
    /// A toolbar button or menu item: run the tool now if the selection allows, or wait for picks.
    func run(_ tool: DesignTool) {
        if tool == .canvas, sketchSession != nil {  // a picture to trace over, on the sketch's own plane
            insertImageInSketch()
            return
        }
        if sketchSession != nil { finishSketch(keepingView: true) }
        cancelSketchPlanePick()
        if pendingTool == tool {  // pressing the waiting tool again finishes it, or cancels it
            let stage = splitBodies  // Split moves on to its tool instead of finishing
            if !perform(tool, confirmed: true), splitBodies == stage { cancelTool() }
            return
        }
        pendingTool = nil
        if !tool.acceptsWholeBody { selection.removeAll(where: \.isWholeBody) }  // a body from the browser isn't a face
        if tool == .measure { showAppearance = false }  // both float in the same corner
        if perform(tool) { return }
        pendingTool = tool
        if tool.showsPlanes { sketchPlaneSize = OriginPlane.displaySize(for: sceneBounds) }
        selection = selection.filter { tool.accepts($0.kind) && accepts($0) && (!$0.isWholeBody || tool.acceptsWholeBody) }
        if tool == .measure { selection = Array(selection.prefix(2)) }
        overlayRevision += 1
    }

    func cancelTool() {
        guard pendingTool != nil else { return }
        pendingTool = nil
        overlayRevision += 1
    }

    /// Return while a tool waits: create it with defaults for whatever wasn't picked.
    func confirmTool() {
        guard let tool = pendingTool else { return }
        if perform(tool, confirmed: true) { pendingTool = nil }
        overlayRevision += 1
    }

    /// A viewport click while a tool waits for input.
    func toolClick(_ tool: DesignTool, _ pick: PickID?, additive: Bool = false) {
        if tool == .measure {  // stays active: every click is a new measurement
            if pick?.isWholeBody != true || tool.acceptsWholeBody { measureClick(pick) }
            return
        }
        guard let pick, tool.accepts(pick.kind), !pick.isWholeBody || tool.picksBodies else { return }
        // Re-picking: only the feature's own sketch counts.
        if let id = reselecting, let source = profileSource(id) {
            let sketch = profile(of: pick)?.sketch ?? curve(of: pick)?.sketch
            guard sketch == source.sketch else { return }
        }
        if tool.needsPlane || tool == .hole {
            if place(tool, on: pick) { pendingTool = nil }
            return
        }
        if tool == .thread {
            threadClick(pick, additive: additive)
            overlayRevision += 1
            return
        }
        if tool == .split, let bodies = splitBodies {  // the bodies are chosen: this click is what divides them
            if !pick.isWholeBody, let cut = splitTool(for: pick) {
                add(Feature(name: document.nextName("Split"), .split(SplitFeature(bodies: bodies, tool: cut))))
            }
            overlayRevision += 1
            return
        }
        guard accepts(pick) else { return }
        if let i = selection.firstIndex(of: pick) { selection.remove(at: i) } else { selection.append(pick) }
        if perform(tool) { pendingTool = nil }
        overlayRevision += 1
    }

    /// The instruction next to the cursor while a tool waits.
    var toolPrompt: String? {
        guard let tool = pendingTool else { return nil }
        let profiles = selectedProfiles.count
        if let id = reselecting {
            let name = document.features.first { $0.id == id }?.name ?? tool.rawValue
            let axis = tool == .revolve ? " (and a line for the axis)" : ""
            return "Click the profiles for \(name)\(axis) · \(profiles) selected · Return to use them"
        }
        switch tool {
        case .extrude: return "Select a profile or a flat face to extrude"
        case .revolve:
            return profiles == 0 ? "Select a profile to revolve" : "Select a line as the axis · Return uses the sketch's vertical axis"
        case .sweep: return profiles == 0 ? "Select the profile to sweep" : "Select the path to sweep along"
        case .loft:
            return profiles < 2 ? "Select profiles in order (\(profiles) so far)" : "Select more profiles, or press Return to loft \(profiles)"
        case .rib: return "Select an open sketch curve for the rib"
        case .pipe: return "Select sketch curves for the pipe's path"
        case .hole: return "Click a flat face where the hole goes"
        case .thread:
            let n = selection.filter(\.isFace).count
            if toolMissed { return "That face isn't round · click the side of a shaft, the wall of a hole, or a face next to one" }
            return n == 0 ? "Click the side of a shaft or the wall of a hole to thread · ⇧-click to pick several"
                : "Click another round face to add it and thread, or press Return to thread \(n) picked"
        case .box, .cylinder, .sphere, .torus, .coil:
            return "Click a plane or flat face to place the \(tool.rawValue.lowercased())"
        case .move: return "Click the bodies or sketches to move or rotate"
        case .scale: return "Click the sketches to scale"
        case .plane: return "Click an origin plane, a construction plane or a flat face to start the new plane from"
        case .canvas: return "Click a plane or flat face to place the image on, then choose the image"
        case .mirror:
            return pickedBodies.isEmpty ? "Click the bodies to mirror" : "Click more bodies, or the plane to mirror across (\(pickedBodies.count) picked)"
        case .pattern:
            let n = faceBodies.count
            return n == 0 ? "Click the bodies to copy" : "Click more bodies, or a straight edge for the direction · Return makes the pattern (\(n) picked)"
        case .measure: return measurePrompt()
        case .project:
            if profiles == 0 { return "Select the profiles to project, like the letters of a text" }
            return result?.bodies.count == 1 ? "Click the face to project onto · Return projects onto the whole body"
                                             : "Click the face to project onto"
        case .shell:
            let n = selection.filter(\.isFace).count
            return n == 0 ? "Click the faces to leave open" : "Click more faces, or press Return to shell (\(n) open)"
        case .draft:
            let n = selection.filter(\.isFace).count
            return n == 0 ? "Click the faces to draft" : "Click more faces, or press Return to draft (\(n) picked)"
        case .split:
            if let bodies = splitBodies {
                return "Click the face, plane or profile to split \(bodies.count == 1 ? "the body" : "the \(bodies.count) bodies") with"
            }
            let n = pickedBodies.count
            return n == 0 ? "Click the bodies to split, then the plane or profile to split them with"
                : "Click more bodies, or the plane or profile to split with · Return to choose a face instead (\(n) picked)"
        case .combine:
            let n = pickedBodies.count
            return n == 0 ? "Click the body to cut from, join to or intersect with"
                : "Click the bodies to combine with it, then press Return (\(n - 1) picked)"
        case .fillet, .chamfer:
            let n = selectedEdgeCount, f = selection.filter(\.isFace).count
            if n + f == 0 { return "Select edges or faces to \(tool.rawValue.lowercased())" }
            let picked = [n > 0 ? "\(n) edge\(n == 1 ? "" : "s")" : nil, f > 0 ? "\(f) face\(f == 1 ? "" : "s")" : nil].compactMap { $0 }
            return "Select more, or press Return (\(picked.joined(separator: ", ")))"
        }
    }

    // MARK: creating features from the selection

    /// Creates the tool's feature from the selection. False if something is still missing;
    /// `confirmed` (Return) accepts defaults for optional inputs.
    @discardableResult
    func perform(_ tool: DesignTool, confirmed: Bool = false) -> Bool {
        if let id = reselecting { return finishReselect(id, confirmed: confirmed) }
        let profiles = selectedProfiles, curves = selectedCurves
        let waiting = pendingTool == tool && !confirmed
        let noBodies = result?.bodies.isEmpty ?? true
        switch tool {
        case .extrude:
            if profiles.isEmpty, selection.count == 1, let pick = selection.first, pick.isFace {
                // A flat face of a body: pull it out (or, with a negative distance, push it in).
                guard let ref = faceRef(pick), let body = result?.body(ref.body), (try? body.faceFrame(ref.face)) != nil else {
                    selection = []
                    alert = AlertInfo(title: "Only flat faces can be extruded", message: "Pick a flat face, or a profile in a sketch.")
                    return false
                }
                add(Feature(name: document.nextName("Extrude"), .extrude(ExtrudeFeature(face: ref, extent: newExtrudeExtent))))
                return true
            }
            guard let first = profiles.first else { return false }
            let refs = profiles.filter { $0.sketch == first.sketch }.map(\.ref)
            add(Feature(name: document.nextName("Extrude"), .extrude(ExtrudeFeature(
                sketch: first.sketch, profiles: refs, extent: newExtrudeExtent, operation: noBodies ? .newBody : .join))))
        case .revolve:
            guard let first = profiles.first else { return false }
            let line = curves.first { $0.sketch == first.sketch && isLine($0.curve, in: $0.sketch) }
            if line == nil && waiting { return false }  // ask for the axis first
            let refs = profiles.filter { $0.sketch == first.sketch }.map(\.ref)
            add(Feature(name: document.nextName("Revolve"), .revolve(RevolveFeature(
                sketch: first.sketch, profiles: refs, axis: line.map { .line($0.curve) } ?? defaultAxis(first.sketch),
                operation: noBodies ? .newBody : .join))))
        case .sweep:
            guard let first = profiles.first, let path = pathRef(curves.filter { $0.sketch != first.sketch } + curves) else {
                return false
            }
            let refs = profiles.filter { $0.sketch == first.sketch }.map(\.ref)
            add(Feature(name: document.nextName("Sweep"), .sweep(SweepFeature(
                sketch: first.sketch, profiles: refs, path: path, operation: noBodies ? .newBody : .join))))
        case .loft:
            var seen = Set<FeatureID>()
            let sections = profiles.filter { seen.insert($0.sketch).inserted }.map { LoftSection(sketch: $0.sketch, profile: $0.ref) }
            guard sections.count >= 2, !waiting else { return false }
            add(Feature(name: document.nextName("Loft"), .loft(LoftFeature(sections: sections, operation: noBodies ? .newBody : .join))))
        case .rib:
            guard !noBodies, let path = pathRef(curves) else { return false }
            add(Feature(name: document.nextName("Rib"), .rib(RibFeature(path: path, thickness: "2 mm"))))
        case .pipe:
            guard let path = pathRef(curves) else { return false }
            add(Feature(name: document.nextName("Pipe"), .pipe(PipeFeature(path: path, diameter: "5 mm"))))
        case .hole, .box, .cylinder, .sphere, .torus, .coil:
            // With a flat face already selected, place it at the face's centre.
            guard selection.count == 1, let pick = selection.first, pick.isFace else { return false }
            return place(tool, on: pick)
        case .thread:
            // Every picked face with a round face of its own to thread (a flat one standing for the hole beside it).
            let faces = selection.filter(\.isFace)
            return !faces.isEmpty && addThreads(on: faces)
        case .fillet, .chamfer:
            guard selectedEdgeCount + selection.filter(\.isFace).count > 0, !waiting else { return false }
            addEdgeFeature(fillet: tool == .fillet)
        case .move:
            // One manipulator slides and turns.
            var sketches: [FeatureID] = []
            for s in profiles.map(\.sketch) + curves.map(\.sketch) where !sketches.contains(s) { sketches.append(s) }
            let bodies = pickedBodies
            guard !bodies.isEmpty || !sketches.isEmpty else { return false }
            add(Feature(name: document.nextName(tool.rawValue), .move(MoveFeature(
                bodies: bodies, sketches: sketches, arrow: .x, rotating: false))))
        case .scale:
            var sketches: [FeatureID] = []
            for s in profiles.map(\.sketch) + curves.map(\.sketch) where !sketches.contains(s) { sketches.append(s) }
            // A sketch selected in the browser counts too.
            if sketches.isEmpty, let id = selectedFeature, case .sketch? = document.features.first(where: { $0.id == id })?.kind {
                sketches = [id]
            }
            guard !sketches.isEmpty else { return false }
            add(Feature(name: document.nextName(tool.rawValue), .scale(ScaleFeature(sketches: sketches))))
        case .plane, .canvas:
            guard selection.count == 1, let pick = selection.first else { return false }
            return place(tool, on: pick)
        case .mirror:
            // Bodies from face and edge picks; the plane from a plane pick.
            let bodies = pickedBodies
            guard !bodies.isEmpty, let plane = selection.lazy.filter({ $0.kind == .plane }).compactMap({ self.planeRef(of: $0) }).first
            else { return false }
            add(Feature(name: document.nextName("Mirror"), .mirror(MirrorFeature(bodies: bodies, plane: plane))))
        case .pattern:
            let bodies = faceBodies
            guard !bodies.isEmpty, !waiting else { return false }
            let edge = selection.first(where: \.isEdge).flatMap { pick -> EdgeRef? in
                guard let m = meshes[safe: pick.body], let name = self.name(of: pick) else { return nil }
                return EdgeRef(body: m.id, edge: name)
            }
            add(Feature(name: document.nextName("Pattern"), .pattern(PatternFeature(kind: .linear, bodies: bodies,
                                                                                    axis: edge.map { .edge($0) } ?? .x))))
        case .shell:
            let faces = selection.compactMap { faceRef($0) }
            guard let body = faces.first?.body, !waiting else { return false }
            add(Feature(name: document.nextName("Shell"), .shell(ShellFeature(body: body, faces: faces.filter { $0.body == body }))))
        case .draft:
            let faces = selection.compactMap { faceRef($0) }
            guard let body = faces.first?.body, !waiting else { return false }
            let drafted = faces.filter { $0.body == body }
            guard let fixed = draftFixedFace(for: drafted) else {
                alert = AlertInfo(title: "Draft needs a flat face that stays put",
                                  message: "The faces lean away from a flat face of the body, like the bottom of a mould. "
                                      + "Pick faces that stand square to one: the sides of a box, or the wall of a hole.")
                return false
            }
            add(Feature(name: document.nextName("Draft"), .draft(DraftFeature(body: body, faces: drafted, fixed: fixed))))
        case .project:
            guard let first = profiles.first else { return false }
            let faces = selection.compactMap { faceRef($0) }
            // The body of the face picked; with none, Return takes the only body there is.
            var target = faces.first?.body
            if target == nil, confirmed, result?.bodies.count == 1 { target = result?.bodies.first?.id }
            guard let target else {
                if confirmed { alert = AlertInfo(title: "Pick a face to project onto", message: "Click a face of the body the profiles should land on.") }
                return false
            }
            let refs = profiles.filter { $0.sketch == first.sketch }.map(\.ref)
            add(Feature(name: document.nextName("Project"), .project(ProjectFeature(
                sketch: first.sketch, profiles: refs, target: target, faces: faces.filter { $0.body == target },
                flipped: projectsAgainstNormal(sketch: first.sketch, onto: target)))))
        case .combine:
            // The first body picked is the target; the rest are the tools. Return combines them.
            let bodies = pickedBodies
            guard bodies.count >= 2, !waiting else { return false }
            add(Feature(name: document.nextName(tool.rawValue),
                        .combine(CombineFeature(target: bodies[0], tools: Array(bodies.dropFirst())))))
        case .split:
            guard splitBodies == nil else { return false }  // the next click is the tool (see toolClick)
            // With one body in the model there is no need to pick it first.
            var bodies = pickedBodies
            if bodies.isEmpty, result?.bodies.count == 1, let only = result?.bodies.first?.id { bodies = [only] }
            if let pick = selection.last(where: { $0.kind == .plane || $0.kind == .region }) {
                guard !bodies.isEmpty, let cut = splitTool(for: pick) else {
                    selection.removeAll { $0.kind == .plane || $0.kind == .region }
                    return false
                }
                add(Feature(name: document.nextName("Split"), .split(SplitFeature(bodies: bodies, tool: cut))))
                return true
            }
            // Return with bodies picked moves on to choosing a face to split with.
            guard confirmed, !bodies.isEmpty else { return false }
            splitBodies = bodies
            selection = bodies.compactMap { id in meshes.firstIndex { $0.id == id }.map { PickID(wholeBody: $0) } }
            return false
        case .measure:
            return false  // reads the picks without making a feature, and stays until Esc
        }
        return true
    }

    /// What a click on a plane, a profile or a face splits with.
    func splitTool(for pick: PickID) -> SplitFeature.Tool? {
        switch pick.kind {
        case .plane: return planeRef(of: pick).map { .plane($0) }
        case .region: return profile(of: pick).map { .profile($0.sketch) }
        case .face: return faceRef(pick).map { .face($0) }
        default: return nil
        }
    }

    /// The flat face a draft of these faces pivots about, when none was picked: a flat face of the body that the
    /// faces stand square to (a box's top or bottom for its sides; for a round wall, a face square to its axis),
    /// preferring one next to the first face, then the lowest. Nil if the body has none.
    func draftFixedFace(for faces: [FaceRef]) -> FaceRef? {
        guard let first = faces.first, let body = result?.body(first.body) else { return nil }
        let picked = Set(faces.map(\.face))
        // What each face stands square to: a flat face's normal (the fixed face's normal lies in it), or a round
        // face's axis (the fixed face's normal runs along it).
        enum Lean { case flat(SIMD3<Double>), round(SIMD3<Double>) }
        var leans: [Lean] = []
        for f in faces where f.body == first.body {
            if let frame = try? body.faceFrame(f.face) { leans.append(.flat(frame.normal)) }
            else if let cyl = try? body.faceCylinder(f.face) { leans.append(.round(cyl.direction)) }
            else { return nil }  // a face that is neither can't be drafted
        }
        func fits(_ name: String) -> (frame: Frame, height: Double)? {
            guard !picked.contains(name), let frame = try? body.faceFrame(name) else { return nil }
            for lean in leans {
                switch lean {
                case .flat(let n): if abs(simd_dot(n, frame.normal)) > 1e-3 { return nil }
                case .round(let axis): if abs(simd_dot(axis, frame.normal)) < 1 - 1e-6 { return nil }
                }
            }
            return (frame, ((try? body.faceOutlineCenter(name)) ?? frame.origin).z)
        }
        var neighbours: [String] = []
        for edge in (try? body.faceEdges(first.face)) ?? [] {
            for face in (try? body.edgeFaces(edge)) ?? [] where face != first.face && !neighbours.contains(face) { neighbours.append(face) }
        }
        for pool in [neighbours, body.faceNames] {
            let candidates = pool.compactMap { name in fits(name).map { (name: name, height: $0.height) } }
            if let best = candidates.min(by: { ($0.height, $0.name) < ($1.height, $1.name) }) {
                return FaceRef(body: first.body, face: best.name)
            }
        }
        return nil
    }

    /// Whether a projection of this sketch should run against its normal to reach the body: when the body is on the
    /// side the normal points away from, or the sketch passes through its middle (within half a millimetre; the normal
    /// points at the viewer who looks at the sketch, so against it is into the screen).
    func projectsAgainstNormal(sketch: FeatureID, onto target: FeatureID) -> Bool {
        guard let frame = result?.sketches[sketch]?.frame, let box = result?.body(target)?.bounds else { return true }
        return simd_dot((box.min + box.max) / 2 - frame.origin, frame.normal) <= 0.5
    }

    // MARK: picking a feature's profiles again

    /// The sketch and profiles of a feature built from sketch profiles, with the tool that makes it.
    func profileSource(_ id: FeatureID) -> (sketch: FeatureID, profiles: [ProfileRef], tool: DesignTool)? {
        switch document.features.first(where: { $0.id == id })?.kind {
        case .extrude(let e)? where e.face == nil: return (e.sketch, e.profiles, .extrude)
        case .revolve(let r)?: return (r.sketch, r.profiles, .revolve)
        case .sweep(let s)?: return (s.sketch, s.profiles, .sweep)
        case .project(let p)?: return (p.sketch, p.profiles, .project)
        default: return nil
        }
    }

    /// Shows the feature's sketch with the profiles that still exist selected; clicks add or remove
    /// profiles, Return stores them in the feature, Esc leaves it as it was.
    func reselectProfiles(_ id: FeatureID) {
        guard let source = profileSource(id) else { return }
        if sketchSession != nil { finishSketch(keepingView: true) }
        cancelSketchPlanePick()
        pendingTool = source.tool
        reselecting = id
        selectedFeature = id
        selection = []
        if let slot = sketchSlots.firstIndex(of: source.sketch), let sk = result?.sketches[source.sketch] {
            for ref in source.profiles {
                guard let region = Regenerator.region(ref, in: sk),
                      let i = sk.regions.firstIndex(where: { $0.index == region.index }) else { continue }
                selection.append(PickID(region: i, slot: slot + 1))
            }
        }
        overlayRevision += 1
    }

    /// Return while re-picking: store the picked profiles (and, for a revolve, a picked line as its axis).
    private func finishReselect(_ id: FeatureID, confirmed: Bool) -> Bool {
        guard confirmed, let source = profileSource(id) else { return false }
        let refs = selectedProfiles.filter { $0.sketch == source.sketch }.map(\.ref)
        guard !refs.isEmpty else {
            alert = AlertInfo(title: "Pick at least one profile", message: "Click the shapes in the sketch to use, then press Return.")
            return false
        }
        let axis = selectedCurves.first { $0.sketch == source.sketch && isLine($0.curve, in: $0.sketch) }?.curve
        updateFeature(id, "Reselect Profiles") { f in
            switch f.kind {
            case .extrude(var e): e.profiles = refs; f.kind = .extrude(e)
            case .revolve(var r): r.profiles = refs; if let axis { r.axis = .line(axis) }; f.kind = .revolve(r)
            case .sweep(var s): s.profiles = refs; f.kind = .sweep(s)
            case .project(var p): p.profiles = refs; f.kind = .project(p)
            default: break
            }
        }
        reselecting = nil
        selection = []
        selectedFeature = id
        return true
    }

    /// Moves whole sketches or bodies (from the browser or a right-click), with a drag handle to set how far.
    func move(sketches: [FeatureID] = [], bodies: [FeatureID] = []) {
        guard !sketches.isEmpty || !bodies.isEmpty else { return }
        if sketchSession != nil { finishSketch(keepingView: true) }
        pendingTool = nil
        add(Feature(name: document.nextName(DesignTool.move.rawValue), .move(MoveFeature(
            bodies: bodies, sketches: sketches, arrow: .x, rotating: false))))
    }

    /// Scales whole sketches (from the browser or a right-click), with a drag handle to set the factor.
    func scale(sketches: [FeatureID]) {
        guard !sketches.isEmpty else { return }
        if sketchSession != nil { finishSketch(keepingView: true) }
        pendingTool = nil
        add(Feature(name: document.nextName(DesignTool.scale.rawValue), .scale(ScaleFeature(sketches: sketches))))
    }

    /// Places a hole or primitive on a picked origin plane or flat face, where the user clicked
    /// (or at the face's centre when there was no click).
    @discardableResult
    func place(_ tool: DesignTool, on pick: PickID) -> Bool {
        let plane: PlaneRef, frame: Frame, target: FeatureID?
        if let origin = OriginPlane(pick: pick) {
            plane = origin.planeRef; frame = origin.frame; target = nil
        } else if let id = constructionPlane(of: pick), let f = result?.planes[id] {
            plane = .plane(id); frame = f; target = nil
        } else if let ref = faceRef(pick), let body = result?.body(ref.body), let f = try? body.faceFrame(ref.face) {
            plane = .face(ref); frame = f; target = ref.body
        } else {
            if pick.isFace { alert = AlertInfo(title: "That face isn't flat", message: "Pick a flat face or one of the origin planes.") }
            return false
        }
        if tool == .plane {
            add(Feature(name: document.nextName("Plane"), .plane(PlaneFeature(base: plane))))
            return true
        }
        if tool == .canvas {
            clickRay = nil; clickRayNext = nil
            let centre = faceRef(pick).flatMap { ref in
                (try? result?.body(ref.body)?.faceOutlineCenter(ref.face)).map { Self.uv(of: $0, on: frame) }
            } ?? (pick.isFace ? faceCenter(pick, on: frame) : nil) ?? .zero
            return insertImage(on: plane, at: centre)
        }
        // The middle of a face's outline, or a plane's origin; a click within 10 points of it (or of a line through
        // it) lands on it, and with no click the thing goes there.
        let center = faceRef(pick).flatMap { ref in
            (try? result?.body(ref.body)?.faceOutlineCenter(ref.face)).map { Self.uv(of: $0, on: frame) }
        } ?? (pick.isFace ? faceCenter(pick, on: frame) : nil) ?? .zero
        var uv = center
        if let ray = clickRay, let hit = Self.intersect(ray: ray, with: frame) {
            uv = hit
            if let next = clickRayNext, let beside = Self.intersect(ray: next, with: frame) {
                uv = Self.snap(hit, to: center, tolerance: 10 * simd_length(beside - hit))
            }
        }
        let u = formatDimension(uv.x, kind: .length), v = formatDimension(uv.y, kind: .length)
        clickRay = nil
        clickRayNext = nil
        if tool == .hole {
            guard case .face(let ref) = plane else { return false }
            add(Feature(name: document.nextName("Hole"), .hole(HoleFeature(face: ref, u: u, v: v))))
            return true
        }
        guard let kind = tool.primitive else { return false }
        let size = defaultPrimitiveSize
        var p = PrimitiveFeature(kind: kind, plane: plane, u: u, v: v, operation: target == nil ? .newBody : .join, target: target)
        p.width = size; p.length = size; p.height = size; p.diameter = size
        if kind == .coil {
            p.diameter = size; p.tube = formatDimension(parse(size) / 5, kind: .length)
            p.pitch = formatDimension(parse(size) / 3, kind: .length)
        }
        if kind == .torus { p.tube = formatDimension(parse(size) / 4, kind: .length) }
        add(Feature(name: document.nextName(kind.rawValue), .primitive(p)))
        return true
    }

    /// A click while the Thread tool waits: threads that face, along with any already picked. ⇧-click
    /// (or ⌘) only picks it, or takes it out again, to thread several together with Return.
    private func threadClick(_ pick: PickID, additive: Bool) {
        defer { clickRay = nil; clickRayNext = nil }
        toolMissed = false
        guard let ref = roundFace(pick), let index = meshes.firstIndex(where: { $0.id == ref.body }),
              let element = meshes[index].mesh.faceNames.firstIndex(of: ref.face) else {
            toolMissed = true
            return
        }
        // Picked as the round face itself, so a flat face's neighbour stays the one that was meant.
        let round = PickID(body: index, face: element)
        if additive {
            if let i = selection.firstIndex(of: round) { selection.remove(at: i) } else { selection.append(round) }
        } else if !selection.contains(round) {
            selection.append(round)
        }
        guard !additive else { return }
        if addThreads(on: selection.filter(\.isFace)) { pendingTool = nil } else { toolMissed = true }
    }

    /// Threads a picked round face, in the size that suits it (see ThreadSize.best). False if the
    /// face isn't round and doesn't border a round face (see roundFace).
    @discardableResult
    func addThread(on pick: PickID) -> Bool { addThreads(on: [pick]) }

    /// Threads the round faces behind these picks. Faces that suit the same size share one Thread
    /// feature (a plate of identical holes); others each get their own. False if none is round.
    @discardableResult
    func addThreads(on picks: [PickID]) -> Bool {
        defer { clickRay = nil; clickRayNext = nil }
        var groups: [(standard: ThreadStandard, size: ThreadSize, faces: [FaceRef])] = []
        for pick in picks {
            guard let ref = roundFace(pick), let cyl = try? result?.body(ref.body)?.faceCylinder(ref.face),
                  let (standard, size) = ThreadSize.best(forDiameter: 2 * cyl.radius, hole: cyl.isHole) else { continue }
            if let g = groups.firstIndex(where: { $0.standard == standard && $0.size.name == size.name }) {
                if !groups[g].faces.contains(ref) { groups[g].faces.append(ref) }
            } else {
                groups.append((standard, size, [ref]))
            }
        }
        guard !groups.isEmpty else { return false }
        for g in groups {
            add(Feature(name: document.nextName("Thread"), .thread(ThreadFeature(
                face: g.faces[0], moreFaces: Array(g.faces.dropFirst()), standard: g.standard, size: g.size.name))))
        }
        return true
    }

    /// The round face to thread for a picked face: the face itself, or for a flat face (a shaft's end,
    /// a face with a hole in it) the round face next to it, the one nearest the pointer's `ray` (by
    /// default the click's) when there are several.
    func roundFace(_ pick: PickID, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)? = nil) -> FaceRef? {
        guard let ref = faceRef(pick), let body = result?.body(ref.body) else { return nil }
        let round: [(face: String, cylinder: KCylinder)]
        if let known = roundNeighbors[ref] {
            round = known
        } else if let c = try? body.faceCylinder(ref.face) {
            round = [(ref.face, c)]
            roundNeighbors[ref] = round
        } else {
            var found: [(face: String, cylinder: KCylinder)] = []
            for edge in (try? body.faceEdges(ref.face)) ?? [] {
                for face in (try? body.edgeFaces(edge)) ?? [] where face != ref.face && !found.contains(where: { $0.face == face }) {
                    if let c = try? body.faceCylinder(face) { found.append((face, c)) }
                }
            }
            round = found
            roundNeighbors[ref] = found
        }
        guard round.count > 1 else { return round.first.map { FaceRef(body: ref.body, face: $0.face) } }
        // Several (a plate with holes): the one whose axis passes nearest the pointer on the face.
        guard let ray = ray ?? clickRay, let frame = try? body.faceFrame(ref.face), let uv = Self.intersect(ray: ray, with: frame)
        else { return nil }
        let p = frame.point(uv.x, uv.y)
        func distance(_ c: KCylinder) -> Double {
            let d = p - c.start
            return simd_length(d - simd_dot(d, c.direction) * c.direction)
        }
        return round.min { distance($0.cylinder) < distance($1.cylinder) }.map { FaceRef(body: ref.body, face: $0.face) }
    }

    /// What shows in blue for a feature being edited: while the Thread tool waits, the round face a
    /// click would thread; while a feature is selected, the faces it made (kernel faces are named
    /// after the feature that created them). Moves, turns, scales, combines and sketches make none.
    var threadHighlight: [UInt32] {
        guard sketchSession == nil else { return [] }
        if pendingTool == .thread {
            guard let h = hovered, h.isFace, let ref = roundFace(h, ray: hoverRay) else { return [] }
            return facePicks { $0.id == ref.body ? $1 == ref.face : false }
        }
        guard pendingTool == nil, let id = selectedFeature, let f = document.features.first(where: { $0.id == id }),
              !f.suppressed else { return [] }
        switch f.kind {
        case .sketch, .plane, .move, .rotate, .scale, .combine: return []
        default: break
        }
        if case .draft(let d) = f.kind {  // a draft makes no faces of its own: it shows the ones it leans
            return facePicks { m, name in m.id == d.body && d.faces.contains { $0.face == name } }
        }
        let prefix = "\(id)."
        return facePicks { _, name in name.hasPrefix(prefix) }
    }

    /// Pick IDs of the faces (on shown bodies) that pass the test.
    private func facePicks(_ test: (BodyMesh, String) -> Bool) -> [UInt32] {
        visibleMeshes.flatMap { m in
            m.mesh.faceNames.enumerated().filter { test(m, $0.element) }.map { PickID(body: m.index, face: $0.offset).raw }
        }
    }

    // MARK: helpers

    /// Bodies with a picked face, in the order they were picked (edges are left for other uses).
    var faceBodies: [FeatureID] {
        var bodies: [FeatureID] = []
        for pick in selection where pick.isFace {
            if let id = meshes[safe: pick.body]?.id, !bodies.contains(id) { bodies.append(id) }
        }
        return bodies
    }

    /// Bodies with a picked face or edge, in the order they were picked.
    var pickedBodies: [FeatureID] {
        var bodies: [FeatureID] = []
        for pick in selection where pick.isFace || pick.isEdge {
            if let id = meshes[safe: pick.body]?.id, !bodies.contains(id) { bodies.append(id) }
        }
        return bodies
    }

    /// A size that suits the model on screen: 20 mm, or about a fifth of the model.
    private var defaultPrimitiveSize: String {
        guard let b = sceneBounds else { return "20 mm" }
        let extent = Double(simd_reduce_max(b.max - b.min))
        let nice = [5.0, 10, 20, 25, 50, 100, 200, 250, 500].min { abs($0 - extent / 5) < abs($1 - extent / 5) } ?? 20
        return formatDimension(max(nice, 5), kind: .length)
    }

    private func parse(_ text: String) -> Double { (try? parameterValues.value(of: text, kind: .length)) ?? 20 }

    /// Where the latest click's ray meets a plane, in the plane's (u, v).
    /// The centre of a face's triangles, in the plane's (u, v).
    private func faceCenter(_ pick: PickID, on frame: Frame) -> SIMD2<Double>? {
        guard pick.isFace, let m = meshes[safe: pick.body]?.mesh else { return nil }
        var sum = SIMD3<Double>.zero, n = 0.0
        for (t, face) in m.triangleFace.enumerated() where Int(face) == pick.element {
            for k in 0..<3 {
                let v = Int(m.indices[t * 3 + k]) * 3
                sum += SIMD3(Double(m.positions[v]), Double(m.positions[v + 1]), Double(m.positions[v + 2]))
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let p = sum / n - frame.origin
        return SIMD2(simd_dot(p, frame.xAxis), simd_dot(p, frame.yAxis))
    }

    private func isLine(_ curve: EntityID, in sketch: FeatureID) -> Bool {
        if case .line? = result?.sketches[sketch]?.solved.curve(curve)?.geometry { return true }
        return false
    }

    /// A revolve axis when none was picked: the sketch's first construction line, else its vertical axis.
    private func defaultAxis(_ sketch: FeatureID) -> AxisRef {
        let s = result?.sketches[sketch]?.solved
        if let line = s?.curves.first(where: { c in
            if case .line = c.geometry { return c.construction }
            return false
        }) { return .line(line.id) }
        return .sketchY
    }

    /// A path from picked curves: those picked in the first curve's sketch, or, when only one was
    /// picked, the chain of curves joined end to end with it.
    func pathRef(_ curves: [(sketch: FeatureID, curve: EntityID)]) -> CurveRef? {
        guard let first = curves.first else { return nil }
        var ids: [EntityID] = []
        for c in curves where c.sketch == first.sketch && !ids.contains(c.curve) { ids.append(c.curve) }
        if ids.count == 1, let s = result?.sketches[first.sketch]?.solved { ids = Self.chain(from: ids[0], in: s) }
        return CurveRef(sketch: first.sketch, curves: ids)
    }

    /// Curves joined end to end with `seed`, following each end while exactly two curves meet there.
    static func chain(from seed: EntityID, in s: Sketch) -> [EntityID] {
        func ends(_ id: EntityID) -> [SIMD2<Double>] {
            switch s.curve(id)?.geometry {
            case .line(let a, let b)?, .arc(_, let a, let b)?, .bezier(let a, _, _, let b)?: return [a, b].compactMap { s.position($0) }
            default: return []
            }
        }
        let candidates = s.curves.filter { !$0.construction || $0.id == seed }.map(\.id)
        func near(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Bool { simd_length(p - q) < 1e-6 }
        var chain = [seed]
        var frontier = ends(seed)
        while let p = frontier.popLast() {
            let touching = candidates.filter { id in ends(id).contains { near($0, p) } }
            guard touching.count == 2, let next = touching.first(where: { !chain.contains($0) }) else { continue }
            chain.append(next)
            frontier += ends(next).filter { !near($0, p) }
        }
        return chain
    }
}

extension ChamferMode {
    /// A glyph name from IconGlyphs.swift.
    var symbol: String {
        switch self {
        case .equalDistance: return "chamfer-equal"
        case .distanceAngle: return "chamfer-angle"
        case .twoDistances: return "chamfer-two"
        }
    }

    /// The tooltip: what it does, and how it is worked.
    var help: String {
        let how = "bevel the selected edges, or every edge around a selected face"
        switch self {
        case .equalDistance: return "\(title) (C): \(how), the same distance on both faces"
        case .distanceAngle: return "\(title) (C): \(how), by a distance on one face and the angle to it"
        case .twoDistances: return "\(title) (C): \(how), with a distance on each face"
        }
    }
}

extension ExtrudeMode {
    /// A glyph name from IconGlyphs.swift.
    var symbol: String {
        switch self {
        case .oneDirection: return "extrude"
        case .twoDirections: return "extrude-two"
        case .mirrored: return "extrude-mirrored"
        }
    }

    /// The tooltip: what it does, and how it is worked.
    var help: String {
        let how = "push a profile or a flat face into a solid"
        switch self {
        case .oneDirection: return "\(title) (E): \(how), one distance to one side"
        case .twoDirections: return "\(title) (E): \(how), a distance to each side of it"
        case .mirrored: return "\(title) (E): \(how), the same distance to both sides, half each way"
        }
    }
}

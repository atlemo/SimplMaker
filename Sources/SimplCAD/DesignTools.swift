// The Design toolbar's tools: what each one needs, how it asks for it, and the feature it creates.
//
// A tool runs straight away when the selection already has what it needs. Otherwise it waits
// (`pendingTool`): the cursor says what to pick, clicks go to the tool, Return accepts defaults
// (a revolve's axis, a loft's sections, fillet edges) and Esc cancels.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

enum DesignTool: String, CaseIterable, Identifiable, Sendable {
    case extrude = "Extrude", revolve = "Revolve", sweep = "Sweep", loft = "Loft", rib = "Rib", hole = "Hole"
    case box = "Box", cylinder = "Cylinder", sphere = "Sphere", torus = "Torus", coil = "Coil", pipe = "Pipe"
    case fillet = "Fillet", chamfer = "Chamfer", move = "Move", rotate = "Rotate", combine = "Combine"

    var id: String { rawValue }

    /// Toolbar and menu groups: shapes built from sketches, ready-made primitives, and tools that
    /// change an existing body.
    static let shapes: [DesignTool] = [.extrude, .revolve, .sweep, .loft, .rib, .pipe]
    static let primitives: [DesignTool] = [.box, .cylinder, .sphere, .torus, .coil]
    static let modifiers: [DesignTool] = [.fillet, .chamfer, .hole, .move, .rotate, .combine]

    /// A glyph name from the macOS Design System's icon set (see IconGlyphs.swift), not an SF Symbol.
    var symbol: String {
        switch self {
        case .extrude: return "layers"
        case .revolve: return "rotate-3d"
        case .sweep: return "spline"
        case .loft: return "layers-2"
        case .rib: return "square-split-horizontal"
        case .hole: return "circle-dot"
        case .box: return "cuboid"
        case .cylinder: return "cylinder"
        case .sphere: return "globe"
        case .torus: return "torus"
        case .coil: return "orbit"
        case .pipe: return "waypoints"
        case .fillet: return "radius"
        case .chamfer: return "triangle"
        case .move: return "move"
        case .rotate: return "rotate-cw"
        case .combine: return "combine"
        }
    }

    var help: String {
        switch self {
        case .extrude: return "Extrude (E): push a profile into a solid"
        case .revolve: return "Revolve: turn a profile around an axis"
        case .sweep: return "Sweep: move a profile along a path"
        case .loft: return "Loft: blend between two or more profiles"
        case .rib: return "Rib: a thin wall from an open sketch line to the body"
        case .hole: return "Hole: drill a hole in a flat face"
        case .box: return "Box: place a box on a plane or face"
        case .cylinder: return "Cylinder: place a cylinder on a plane or face"
        case .sphere: return "Sphere: place a sphere on a plane or face"
        case .torus: return "Torus: place a torus on a plane or face"
        case .coil: return "Coil: place a coil spring on a plane or face"
        case .pipe: return "Pipe: a round tube along sketch curves"
        case .fillet: return "Fillet: round the selected edges"
        case .move: return "Move: slide bodies or sketches along X, Y or Z"
        case .rotate: return "Rotate: turn a body about an X, Y or Z axis"
        case .chamfer: return "Chamfer: bevel the selected edges"
        case .combine: return "Combine: join, cut or intersect bodies (e.g. cut text out of a plate)"
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

    /// Placed by clicking a plane or a flat face.
    var needsPlane: Bool { primitive != nil }

    /// What a click can pick while this tool waits.
    func accepts(_ kind: PickID.Kind) -> Bool {
        switch self {
        case .extrude: return kind == .region || kind == .face
        case .loft: return kind == .region
        case .revolve, .sweep: return kind == .region || kind == .sketchCurve
        case .rib, .pipe: return kind == .sketchCurve
        case .hole: return kind == .face
        case .box, .cylinder, .sphere, .torus, .coil: return kind == .plane || kind == .face
        case .fillet, .chamfer: return kind == .edge
        case .move: return kind == .face || kind == .edge || kind == .region || kind == .sketchCurve
        case .rotate, .combine: return kind == .face || kind == .edge
        }
    }
}

extension DocumentModel {
    /// A toolbar button or menu item: run the tool now if the selection allows, or wait for picks.
    func run(_ tool: DesignTool) {
        if sketchSession != nil { finishSketch() }
        cancelSketchPlanePick()
        if pendingTool == tool {  // pressing the waiting tool again finishes it, or cancels it
            if !perform(tool, confirmed: true) { cancelTool() }
            return
        }
        pendingTool = nil
        if perform(tool) { return }
        pendingTool = tool
        if tool.needsPlane { sketchPlaneSize = OriginPlane.displaySize(for: sceneBounds) }
        selection = selection.filter { tool.accepts($0.kind) && accepts($0) }
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
    func toolClick(_ tool: DesignTool, _ pick: PickID?) {
        guard let pick, tool.accepts(pick.kind) else { return }
        if tool.needsPlane || tool == .hole {
            if place(tool, on: pick) { pendingTool = nil }
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
        case .box, .cylinder, .sphere, .torus, .coil:
            return "Click a plane or flat face to place the \(tool.rawValue.lowercased())"
        case .move: return "Click the bodies or sketches to move"
        case .rotate: return "Click the body to rotate"
        case .combine:
            let n = pickedBodies.count
            return n == 0 ? "Click the body to cut from, join to or intersect with"
                : "Click the bodies to combine with it, then press Return (\(n - 1) picked)"
        case .fillet, .chamfer:
            let n = selectedEdgeCount
            return n == 0 ? "Select edges to \(tool.rawValue.lowercased())" : "Select more edges, or press Return (\(n) selected)"
        }
    }

    // MARK: creating features from the selection

    /// Creates the tool's feature from the selection. False if something is still missing;
    /// `confirmed` (Return) accepts defaults for optional inputs.
    @discardableResult
    func perform(_ tool: DesignTool, confirmed: Bool = false) -> Bool {
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
                add(Feature(name: document.nextName("Extrude"), .extrude(ExtrudeFeature(face: ref))))
                return true
            }
            guard let first = profiles.first else { return false }
            let refs = profiles.filter { $0.sketch == first.sketch }.map(\.ref)
            add(Feature(name: document.nextName("Extrude"), .extrude(ExtrudeFeature(
                sketch: first.sketch, profiles: refs, extent: .distance("10 mm"), operation: noBodies ? .newBody : .join))))
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
        case .fillet, .chamfer:
            guard selectedEdgeCount > 0, !waiting else { return false }
            addEdgeFeature(fillet: tool == .fillet)
        case .move:
            var sketches: [FeatureID] = []
            for s in profiles.map(\.sketch) + curves.map(\.sketch) where !sketches.contains(s) { sketches.append(s) }
            let bodies = pickedBodies
            guard !bodies.isEmpty || !sketches.isEmpty else { return false }
            add(Feature(name: document.nextName(tool.rawValue), .move(MoveFeature(bodies: bodies, sketches: sketches))))
        case .rotate:
            let bodies = pickedBodies
            guard !bodies.isEmpty else { return false }
            add(Feature(name: document.nextName(tool.rawValue), .rotate(RotateFeature(bodies: bodies))))
        case .combine:
            // The first body picked is the target; the rest are the tools. Return combines them.
            let bodies = pickedBodies
            guard bodies.count >= 2, !waiting else { return false }
            add(Feature(name: document.nextName(tool.rawValue),
                        .combine(CombineFeature(target: bodies[0], tools: Array(bodies.dropFirst())))))
        }
        return true
    }

    /// Moves whole sketches or bodies (from the browser or a right-click), with a drag handle to set how far.
    func move(sketches: [FeatureID] = [], bodies: [FeatureID] = []) {
        guard !sketches.isEmpty || !bodies.isEmpty else { return }
        if sketchSession != nil { finishSketch() }
        pendingTool = nil
        add(Feature(name: document.nextName(DesignTool.move.rawValue), .move(MoveFeature(bodies: bodies, sketches: sketches))))
    }

    /// Places a hole or primitive on a picked origin plane or flat face, where the user clicked
    /// (or at the face's centre when there was no click).
    @discardableResult
    func place(_ tool: DesignTool, on pick: PickID) -> Bool {
        let plane: PlaneRef, frame: Frame, target: FeatureID?
        if let origin = OriginPlane(pick: pick) {
            plane = origin.planeRef; frame = origin.frame; target = nil
        } else if let ref = faceRef(pick), let body = result?.body(ref.body), let f = try? body.faceFrame(ref.face) {
            plane = .face(ref); frame = f; target = ref.body
        } else {
            if pick.isFace { alert = AlertInfo(title: "That face isn't flat", message: "Pick a flat face or one of the origin planes.") }
            return false
        }
        let uv = clickPoint(on: frame) ?? faceCenter(pick, on: frame) ?? .zero
        let u = formatDimension(uv.x, kind: .length), v = formatDimension(uv.y, kind: .length)
        clickRay = nil
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

    // MARK: helpers

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
    private func clickPoint(on frame: Frame) -> SIMD2<Double>? {
        guard let ray = clickRay else { return nil }
        let denom = simd_dot(ray.direction, frame.normal)
        guard abs(denom) > 1e-9 else { return nil }
        let t = simd_dot(frame.origin - ray.origin, frame.normal) / denom
        let p = ray.origin + t * ray.direction - frame.origin
        return SIMD2(simd_dot(p, frame.xAxis), simd_dot(p, frame.yAxis))
    }

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

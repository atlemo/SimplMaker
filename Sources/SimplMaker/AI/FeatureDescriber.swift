// Tells an AI what a feature is made of: its settings by name, with each size as the expression typed and the value
// it comes to. The names are the ones the interface and the file format use, in snake_case.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

struct FeatureDescriber {
    let values: ParameterValues

    // MARK: fields

    func length(_ e: String) -> FeatureField { .quantity(expression: e, value: try? values.value(of: e, kind: .length), unit: "mm") }
    func angle(_ e: String) -> FeatureField {
        .quantity(expression: e, value: (try? values.value(of: e, kind: .angle)).map { $0 * 180 / .pi }, unit: "deg")
    }
    func number(_ e: String) -> FeatureField { .quantity(expression: e, value: try? values.value(of: e, kind: .none), unit: "") }

    private func faces(_ list: [FaceRef]) -> FeatureField { .list(list.map { AIEntityRef.face($0).string }) }
    private func profiles(_ list: [ProfileRef], in sketch: FeatureID) -> FeatureField {
        .list(list.map { AIEntityRef.profile(sketch: sketch, curves: $0.curves, copy: 0).string })
    }
    private func path(_ p: CurveRef) -> FeatureField { .list(p.curves.map { AIEntityRef.curve(sketch: p.sketch, id: $0).string }) }

    func plane(_ p: PlaneRef) -> FeatureField { .text(AIEntityRef.text(for: p)) }

    func fields(of feature: Feature) -> [String: FeatureField] {
        var out: [String: FeatureField] = [:]
        func target(_ id: FeatureID?) { if let id { out["target"] = .text(id) } }
        func operation(_ o: BodyOperation) { out["operation"] = .text(Self.snake(o.rawValue)) }
        switch feature.kind {
        case .sketch(let f):
            out["plane"] = plane(f.plane)
        case .extrude(let f):
            if let face = f.face { out["face"] = faces([face]) } else {
                out["sketch"] = .text(f.sketch)
                out["profiles"] = profiles(f.profiles, in: f.sketch)
            }
            switch f.extent {
            case .distance(let d): out["extent"] = .text("distance"); out["distance"] = length(d)
            case .symmetric(let d): out["extent"] = .text("symmetric"); out["distance"] = length(d)
            case .twoSides(let d, let b): out["extent"] = .text("two_sides"); out["distance"] = length(d); out["back_distance"] = length(b)
            case .throughAll: out["extent"] = .text("through_all")
            case .toFace(let face): out["extent"] = .text("to_face"); out["to_face"] = faces([face])
            }
            if let taper = f.taper { out["taper"] = angle(taper) }
            if let start = f.start { out["start_face"] = faces([start]) }
            out["flipped"] = .flag(f.flipped)
            operation(f.operation); target(f.target)
        case .fillet(let f), .chamfer(let f):
            out["size"] = length(f.size)
            if case .chamfer = feature.kind {
                out["mode"] = .text(EdgeFinishOperation.modeName(f.mode))
                if let kind = f.mode.secondKind, !f.second.isEmpty { out["second"] = kind == .angle ? angle(f.second) : length(f.second) }
            }
            out["edges"] = .list(f.edges.map { AIEntityRef.edge($0).string })
            if !f.faces.isEmpty { out["faces"] = faces(f.faces) }
            out["flipped"] = .flag(f.flipped)
        case .revolve(let f):
            out["sketch"] = .text(f.sketch); out["profiles"] = profiles(f.profiles, in: f.sketch)
            out["angle"] = angle(f.angle)
            switch f.axis {
            case .x: out["axis"] = .text("x")
            case .y: out["axis"] = .text("y")
            case .z: out["axis"] = .text("z")
            case .sketchX: out["axis"] = .text("sketch_x")
            case .sketchY: out["axis"] = .text("sketch_y")
            case .line(let id): out["axis"] = .text(AIEntityRef.curve(sketch: f.sketch, id: id).string)
            }
            operation(f.operation); target(f.target)
        case .sweep(let f):
            out["sketch"] = .text(f.sketch); out["profiles"] = profiles(f.profiles, in: f.sketch)
            out["path"] = path(f.path); operation(f.operation); target(f.target)
        case .loft(let f):
            out["sections"] = .list(f.sections.map { AIEntityRef.profile(sketch: $0.sketch, curves: $0.profile.curves, copy: 0).string })
            out["ruled"] = .flag(f.ruled); operation(f.operation); target(f.target)
        case .rib(let f):
            out["path"] = path(f.path); out["thickness"] = length(f.thickness); target(f.target)
        case .hole(let f):
            out["kind"] = .text(Self.snake(f.kind.rawValue))
            out["face"] = faces([f.face])
            out["u"] = length(f.u); out["v"] = length(f.v)
            out["diameter"] = length(f.diameter)
            if let depth = f.depth { out["depth"] = length(depth) } else { out["depth"] = .text("through_all") }
            out["tip_angle"] = angle(f.tipAngle)
            if f.kind != .simple {
                out["head_diameter"] = length(f.headDiameter); out["head_depth"] = length(f.headDepth)
                if f.kind == .countersink { out["head_angle"] = angle(f.headAngle) }
            }
        case .thread(let f):
            out["faces"] = faces(f.faces)
            out["standard"] = .text(f.standard.rawValue); out["size"] = .text(f.size)
            if let l = f.length { out["length"] = length(l) }
            out["flipped"] = .flag(f.flipped); out["left_handed"] = .flag(f.leftHanded)
            if let t = f.tolerance { out["tolerance"] = f.toleranceUnit == .percent ? number(t) : length(t) }
        case .primitive(let f):
            out["kind"] = .text(f.kind.rawValue.lowercased())
            out["plane"] = plane(f.plane)
            out["u"] = length(f.u); out["v"] = length(f.v)
            switch f.kind {
            case .box: out["width"] = length(f.width); out["length"] = length(f.length); out["height"] = length(f.height)
            case .cylinder: out["diameter"] = length(f.diameter); out["height"] = length(f.height)
            case .sphere: out["diameter"] = length(f.diameter)
            case .torus: out["diameter"] = length(f.diameter); out["tube"] = length(f.tube)
            case .coil:
                out["diameter"] = length(f.diameter); out["tube"] = length(f.tube)
                out["pitch"] = length(f.pitch); out["turns"] = number(f.turns)
            }
            operation(f.operation); target(f.target)
        case .pipe(let f):
            out["path"] = path(f.path); out["diameter"] = length(f.diameter)
            if let wall = f.wall { out["wall"] = length(wall) }
            operation(f.operation); target(f.target)
        case .move(let f):
            out["bodies"] = .list(f.bodies)
            if !f.sketches.isEmpty { out["sketches"] = .list(f.sketches) }
            out["dx"] = length(f.dx); out["dy"] = length(f.dy); out["dz"] = length(f.dz)
            out["rx"] = angle(f.rx); out["ry"] = angle(f.ry); out["rz"] = angle(f.rz)
        case .rotate(let f):
            out["bodies"] = .list(f.bodies); out["axis"] = .text(f.axis.rawValue.lowercased()); out["angle"] = angle(f.angle)
        case .scale(let f):
            if !f.bodies.isEmpty { out["bodies"] = .list(f.bodies) }
            if !f.sketches.isEmpty { out["sketches"] = .list(f.sketches) }
            out["factor"] = number(f.factor)
        case .combine(let f):
            out["target"] = .text(f.target); out["tools"] = .list(f.tools)
            out["operation"] = .text(Self.snake(f.operation.rawValue)); out["keep_tools"] = .flag(f.keepTools)
        case .split(let f):
            out["bodies"] = .list(f.bodies)
            switch f.tool {
            case .plane(let p): out["tool"] = plane(p)
            case .face(let face): out["tool"] = faces([face])
            case .profile(let sketch): out["tool"] = .text(sketch)
            }
        case .layOnFloor(let f):
            out["face"] = faces([f.face])
        case .plane(let f):
            out["base"] = plane(f.base); out["offset"] = length(f.offset); out["angle"] = angle(f.angle)
            out["axis"] = .text(f.axis.rawValue.lowercased())
        case .mirror(let f):
            out["bodies"] = .list(f.bodies); operation(f.operation)
            switch f.line {
            case nil: out["plane"] = plane(f.plane)
            case .x?: out["line"] = .text("x")
            case .y?: out["line"] = .text("y")
            case .z?: out["line"] = .text("z")
            case .edge(let e)?: out["line"] = .text(AIEntityRef.edge(e).string)
            }
        case .pattern(let f):
            out["kind"] = .text(f.kind.rawValue.lowercased()); out["bodies"] = .list(f.bodies)
            switch f.axis {
            case .x: out["axis"] = .text("x")
            case .y: out["axis"] = .text("y")
            case .z: out["axis"] = .text("z")
            case .edge(let e): out["axis"] = .text(AIEntityRef.edge(e).string)
            }
            out["count"] = number(f.count)
            out["spacing"] = f.kind == .linear ? length(f.spacing) : angle(f.spacing)
            operation(f.operation)
        case .shell(let f):
            out["body"] = .text(f.body); out["open_faces"] = faces(f.faces)
            out["thickness"] = length(f.thickness); out["inside"] = .flag(f.inside)
        case .draft(let f):
            out["body"] = .text(f.body); out["faces"] = faces(f.faces)
            if let fixed = f.fixed { out["fixed_face"] = faces([fixed]) }
            out["angle"] = angle(f.angle)
        case .project(let f):
            out["sketch"] = .text(f.sketch); out["profiles"] = profiles(f.profiles, in: f.sketch)
            out["target"] = .text(f.target)
            if !f.faces.isEmpty { out["faces"] = faces(f.faces) }
            out["mode"] = .text(f.mode.rawValue.lowercased()); out["height"] = length(f.height); out["flipped"] = .flag(f.flipped)
        case .importBody(let f):
            out["file_name"] = .text(f.fileName)
        case .image(let f):
            out["plane"] = plane(f.plane); out["file_name"] = .text(f.fileName)
            out["u"] = length(f.u); out["v"] = length(f.v); out["width"] = length(f.width); out["angle"] = angle(f.angle)
            out["opacity"] = .quantity(expression: String(f.opacity), value: f.opacity, unit: "")
        }
        return out
    }

    /// "New Body" → "new_body".
    static func snake(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "_") }

    // MARK: sketches

    func dimensionKind(_ k: SketchDimension.Kind) -> String {
        switch k {
        case .distance: return "distance"
        case .horizontalDistance: return "horizontal_distance"
        case .verticalDistance: return "vertical_distance"
        case .pointLineDistance: return "point_line_distance"
        case .length: return "length"
        case .radius: return "radius"
        case .diameter: return "diameter"
        case .angle: return "angle"
        case .lineAngle: return "line_angle"
        case .radialOffset: return "radial_offset"
        case .gap: return "gap"
        }
    }

    func dimensions(of sketch: Sketch) -> [DimensionInfo] {
        sketch.dimensions.map { d in
            DimensionInfo(id: d.id, kind: dimensionKind(d.kind), refs: Sketch.references(d.kind),
                          field: d.unitKind == .angle ? angle(d.expression) : length(d.expression))
        }
    }
}

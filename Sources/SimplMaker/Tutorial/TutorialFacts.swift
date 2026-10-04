// What the tutorial reads off the part: which feature is the box, which is the lid, and whether
// they were made the way the tutorial asks (centered on the origin, sized by parameters).
//
// Everything is found by what a feature is and what it refers to, not by its place in the timeline or
// its name, so a user who renames things, reorders them or does a step twice still gets sensible hints.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

/// The numbers the tutorial names. They're added to the part at the "Name your numbers" step.
enum TutorialPart {
    static let parameters: [Parameter] = [
        Parameter("width", "60 mm", comment: "How wide the box is"),
        Parameter("depth", "40 mm", comment: "How deep the box is"),
        Parameter("height", "25 mm", comment: "How tall the box is"),
        Parameter("wall", "2 mm", comment: "How thick the walls are"),
    ]
}

@MainActor
struct TutorialFacts {
    let model: DocumentModel

    init(_ model: DocumentModel) { self.model = model }

    private var features: [Feature] { model.document.features }

    // MARK: finding the box and the lid

    typealias Found<T> = (id: FeatureID, value: T)

    private func sketches() -> [Found<SketchFeature>] {
        features.compactMap { f in if case .sketch(let s) = f.kind { return (f.id, s) } else { return nil } }
    }

    private func extrudes() -> [Found<ExtrudeFeature>] {
        features.compactMap { f in if case .extrude(let e) = f.kind, !f.suppressed { return (f.id, e) } else { return nil } }
    }

    /// The box's sketch: the first one on the XY plane (the floor).
    var boxSketch: Found<SketchFeature>? { sketches().first { $0.value.plane == .xy } }

    /// Sketches that aren't where the tutorial wants them, before the box sketch exists.
    var misplacedSketch: Found<SketchFeature>? {
        boxSketch == nil ? sketches().first { $0.value.plane != .xy } : nil
    }

    var boxExtrude: Found<ExtrudeFeature>? {
        guard let box = boxSketch else { return nil }
        return extrudes().first { $0.value.sketch == box.id && $0.value.face == nil }
    }

    /// The face the box is opened through: the end of its extrude, the top.
    var boxTopFace: FaceRef? { boxExtrude.map { FaceRef(body: $0.id, face: "\($0.id).end") } }

    var shell: Found<ShellFeature>? {
        guard let box = boxExtrude else { return nil }
        return features.compactMap { f -> Found<ShellFeature>? in
            if case .shell(let s) = f.kind, s.body == box.id { return (f.id, s) } else { return nil }
        }.first
    }

    /// The construction plane the lid sits on: one built on the XY plane.
    var plane: Found<PlaneFeature>? {
        features.compactMap { f -> Found<PlaneFeature>? in
            if case .plane(let p) = f.kind, p.base == .xy { return (f.id, p) } else { return nil }
        }.first
    }

    var lidSketch: Found<SketchFeature>? {
        guard let plane else { return nil }
        return sketches().first { $0.value.plane == .plane(plane.id) }
    }

    var lidExtrude: Found<ExtrudeFeature>? {
        guard let lid = lidSketch else { return nil }
        return extrudes().first { $0.value.sketch == lid.id && $0.value.face == nil }
    }

    var lidTopFace: FaceRef? { lidExtrude.map { FaceRef(body: $0.id, face: "\($0.id).end") } }

    var lidFillet: Found<EdgeFeature>? {
        guard let lid = lidExtrude else { return nil }
        return features.compactMap { f -> Found<EdgeFeature>? in
            guard case .fillet(let e) = f.kind, !f.suppressed,
                  e.faces.contains(where: { $0.body == lid.id }) || e.edges.contains(where: { $0.body == lid.id }) else { return nil }
            return (f.id, e)
        }.first
    }

    var lidHole: Found<HoleFeature>? {
        guard let lid = lidExtrude else { return nil }
        return features.compactMap { f -> Found<HoleFeature>? in
            if case .hole(let h) = f.kind, !f.suppressed, h.face.body == lid.id { return (f.id, h) } else { return nil }
        }.first
    }

    var lidThread: Found<ThreadFeature>? {
        guard let lid = lidExtrude else { return nil }
        return features.compactMap { f -> Found<ThreadFeature>? in
            if case .thread(let t) = f.kind, !f.suppressed, t.faces.contains(where: { $0.body == lid.id }) { return (f.id, t) } else { return nil }
        }.first
    }

    // MARK: parameters

    /// Whether an expression uses the parameter ("wall * 2" uses "wall").
    static func uses(_ expression: String, _ parameter: String) -> Bool {
        (try? Expressions.parse(expression))?.references.contains(parameter) ?? false
    }

    var hasTutorialParameters: Bool {
        TutorialPart.parameters.allSatisfy { p in model.document.parameters.contains { $0.name == p.name } }
    }

    /// A parameter has been given another value than the tutorial started it with.
    var parametersChanged: Bool {
        TutorialPart.parameters.contains { start in
            model.document.parameters.first { $0.name == start.name }.map { $0.expression != start.expression } ?? false
        }
    }

    // MARK: the outline

    enum Outline: Equatable {
        case missing
        /// A rectangle sized with plain numbers only: it wouldn't follow any parameter.
        case plainNumbers
        /// A rectangle sized by parameters, but not by these ones (`width` and `depth`): the lid wouldn't match the box.
        case missingParameters([String])
        /// A rectangle that isn't centered on the sketch's origin, so the lid wouldn't sit squarely on the box.
        case offCenter
        case good
    }

    /// Whether a sketch holds the rectangle the tutorial draws: four lines, sized by `width` and `depth`, centered on the origin.
    static func outline(of sketch: Sketch) -> Outline {
        var corners: [EntityID] = []
        var lines = 0
        for curve in sketch.curves where !curve.construction {
            if case .line(let a, let b) = curve.geometry { lines += 1; corners += [a, b] }
        }
        guard lines >= 4 else { return .missing }
        let used = Set(sketch.dimensions.flatMap { d in (try? Expressions.parse(d.expression))?.references ?? [] })
        guard !used.isEmpty else { return .plainNumbers }
        let missing = ["width", "depth"].filter { !used.contains($0) }
        guard missing.isEmpty else { return .missingParameters(missing) }
        let points = Set(corners).compactMap { sketch.point($0) }
        guard let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
              let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return .missing }
        return abs(x0 + x1) < 1e-3 && abs(y0 + y1) < 1e-3 ? .good : .offCenter
    }
}

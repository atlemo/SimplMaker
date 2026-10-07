// What the tutorial reads off the part: which feature is the base, which is the backrest, and whether
// they were made the way the tutorial asks (a corner on the origin, sized by parameters).
//
// Everything is found by what a feature is and what it refers to, not by its place in the timeline or
// its name, so a user who renames things, reorders them or does a step twice still gets sensible hints.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation

/// The numbers the tutorial names. They're added to the part at the "Name your numbers" step.
enum TutorialPart {
    static let parameters: [Parameter] = [
        Parameter("width", "80 mm", comment: "How wide the stand is: a phone, or a tablet"),
        Parameter("depth", "60 mm", comment: "How deep the base is"),
        Parameter("thickness", "4 mm", comment: "How thick the base and the backrest are"),
        Parameter("backrest", "70 mm", comment: "How long the backrest is"),
        Parameter("lean", "70 deg", unit: .angle, comment: "How steeply the backrest stands"),
    ]

    /// What "Do it for me" changes at the end: a stand wide enough for a tablet.
    static let tabletWidth = "190 mm"
}

@MainActor
struct TutorialFacts {
    let model: DocumentModel

    init(_ model: DocumentModel) { self.model = model }

    private var features: [Feature] { model.document.features }

    // MARK: finding the base and the backrest

    typealias Found<T> = (id: FeatureID, value: T)

    private func sketches() -> [Found<SketchFeature>] {
        features.compactMap { f in if case .sketch(let s) = f.kind { return (f.id, s) } else { return nil } }
    }

    private func extrudes() -> [Found<ExtrudeFeature>] {
        features.compactMap { f in if case .extrude(let e) = f.kind, !f.suppressed { return (f.id, e) } else { return nil } }
    }

    /// The base's sketch: the first one on the XY plane (the floor).
    var baseSketch: Found<SketchFeature>? { sketches().first { $0.value.plane == .xy } }

    /// Sketches that aren't where the tutorial wants them, before the base sketch exists.
    var misplacedSketch: Found<SketchFeature>? {
        baseSketch == nil ? sketches().first { $0.value.plane != .xy } : nil
    }

    var baseExtrude: Found<ExtrudeFeature>? {
        guard let base = baseSketch else { return nil }
        return extrudes().first { $0.value.sketch == base.id && $0.value.face == nil }
    }

    /// The construction plane the backrest leans on: one built on the XY plane.
    var plane: Found<PlaneFeature>? {
        features.compactMap { f -> Found<PlaneFeature>? in
            if case .plane(let p) = f.kind, p.base == .xy { return (f.id, p) } else { return nil }
        }.first
    }

    /// The plane is made and its offset settled: the field that comes with a new plane is closed.
    var planeIsSettled: Bool { plane.map { model.newFeature != $0.id } ?? false }

    /// The plane leans by a parameter, so changing `lean` tilts the backrest.
    var planeLeans: Bool { plane.map { Self.uses($0.value.angle, "lean") } ?? false }

    var backSketch: Found<SketchFeature>? {
        guard let plane else { return nil }
        return sketches().first { $0.value.plane == .plane(plane.id) }
    }

    /// A sketch started on something else once the plane is there: not where the backrest goes.
    var misplacedBackSketch: Found<SketchFeature>? {
        guard plane != nil, backSketch == nil else { return nil }
        return sketches().first { $0.id != baseSketch?.id }
    }

    var backExtrude: Found<ExtrudeFeature>? {
        guard let back = backSketch else { return nil }
        return extrudes().first { $0.value.sketch == back.id && $0.value.face == nil }
    }

    // MARK: parameters

    /// Whether an expression uses the parameter ("thickness / 3" uses "thickness").
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

    // MARK: the outlines

    enum Outline: Equatable {
        case missing
        /// A rectangle sized with plain numbers only: it wouldn't follow any parameter.
        case plainNumbers
        /// A rectangle sized by parameters, but not by these ones: it wouldn't follow them.
        case missingParameters([String])
        /// A rectangle that doesn't grow the right way from the sketch's origin.
        case offOrigin
        case good
    }

    /// Which way a rectangle grows from the origin: the base goes toward the viewer (down in the top view), so the
    /// backrest, which leans the other way, can rise from the base's back edge; the backrest goes up.
    enum Growth { case rightDown, rightUp }

    /// Whether a sketch holds the rectangle the tutorial draws: four lines, sized by the two parameters, with a
    /// corner on the origin and growing the way asked.
    static func outline(of sketch: Sketch, sizedBy names: [String], growing growth: Growth) -> Outline {
        var corners: [EntityID] = []
        var lines = 0
        for curve in sketch.curves where !curve.construction {
            if case .line(let a, let b) = curve.geometry { lines += 1; corners += [a, b] }
        }
        guard lines >= 4 else { return .missing }
        let used = Set(sketch.dimensions.flatMap { d in (try? Expressions.parse(d.expression))?.references ?? [] })
        guard !used.isEmpty else { return .plainNumbers }
        let missing = names.filter { !used.contains($0) }
        guard missing.isEmpty else { return .missingParameters(missing) }
        let points = Set(corners).compactMap { sketch.point($0) }
        guard let x0 = points.map(\.x).min(), let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return .missing }
        let yEdge = growth == .rightDown ? y1 : y0
        return abs(x0) < 1e-3 && abs(yEdge) < 1e-3 ? .good : .offOrigin
    }

    static func baseOutline(of sketch: Sketch) -> Outline { outline(of: sketch, sizedBy: ["width", "depth"], growing: .rightDown) }
    static func backOutline(of sketch: Sketch) -> Outline { outline(of: sketch, sizedBy: ["width", "backrest"], growing: .rightUp) }
}

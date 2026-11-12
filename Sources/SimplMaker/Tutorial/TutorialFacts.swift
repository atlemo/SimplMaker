// What the tutorial reads off the part: which feature is the floor, which sketch holds the sections,
// and whether they were made the way the tutorial asks (corners on the floor's corners, sizes given by
// parameters, one constraint between the two back sections).
//
// Everything is found by what a feature is and what it refers to, not by its place in the timeline or
// its name, so a user who renames things, reorders them or does a step twice still gets sensible hints.
// The sections' geometry is read from the sketch as the kernel last solved it, for the parameters now,
// so a step stays done when the last step changes `width` and `depth`.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation

/// The numbers the tutorial names. They're added to the part at the "Name your numbers" step.
enum TutorialPart {
    static let parameters: [Parameter] = [
        Parameter("width", "150 mm", comment: "How wide the organizer is"),
        Parameter("depth", "90 mm", comment: "How deep it is, front to back"),
        Parameter("height", "30 mm", comment: "How tall the walls stand above the floor"),
        Parameter("wall", "3 mm", comment: "How thick the walls and the floor are"),
        Parameter("front", "25 mm", comment: "How deep the front section is"),
    ]

    /// What "Do it for me" changes at the end: a bigger organizer.
    static let resized: [(name: String, expression: String)] = [("width", "190 mm"), ("depth", "120 mm")]

    /// The name tag's numbers: how long and deep the tag is, how thick, the ring hole's diameter and how far the letters stand up.
    /// (None is the start of another's name: Return completes a half-typed name.)
    static let tagParameters: [Parameter] = [
        Parameter("width", "60 mm", comment: "How long the tag is"),
        Parameter("depth", "25 mm", comment: "How deep it is, top to bottom"),
        Parameter("thick", "3 mm", comment: "How thick the tag is"),
        Parameter("hole", "5 mm", comment: "How wide the hole for the key ring is"),
        Parameter("relief", "1 mm", comment: "How far the letters stand up from the tag"),
    ]

    /// What "Do it for me" changes at the end of the name tag: a longer tag with a wider hole.
    static let tagResized: [(name: String, expression: String)] = [("width", "75 mm"), ("hole", "6 mm")]
}

/// Which tutorial a window runs: each is a script, the numbers it names, and the changes its last task makes.
enum TutorialKind: Sendable {
    case deskOrganizer, nameTag

    /// The Mac builds a desk organizer with a mouse; the iPad a name tag keyring with a finger.
    static var platform: TutorialKind {
#if os(iOS)
        .nameTag
#else
        .deskOrganizer
#endif
    }

    @MainActor var steps: [TutorialStep] {
        switch self {
        case .deskOrganizer: return TutorialScript.steps
        case .nameTag: return NameTagScript.steps
        }
    }

    var parameters: [Parameter] { self == .nameTag ? TutorialPart.tagParameters : TutorialPart.parameters }
    var resized: [(name: String, expression: String)] { self == .nameTag ? TutorialPart.tagResized : TutorialPart.resized }
    var title: String { self == .nameTag ? "Name Tag Keyring" : "Desk Organizer" }
}

@MainActor
struct TutorialFacts {
    let model: DocumentModel

    init(_ model: DocumentModel) { self.model = model }

    private var features: [Feature] { model.document.features }

    // MARK: finding the floor and the sketch on top of it

    typealias Found<T> = (id: FeatureID, value: T)

    private func sketches() -> [Found<SketchFeature>] {
        features.compactMap { f in if case .sketch(let s) = f.kind { return (f.id, s) } else { return nil } }
    }

    private func extrudes() -> [Found<ExtrudeFeature>] {
        features.compactMap { f in if case .extrude(let e) = f.kind, !f.suppressed { return (f.id, e) } else { return nil } }
    }

    /// The floor's sketch: the first one on the XY plane.
    var baseSketch: Found<SketchFeature>? { sketches().first { $0.value.plane == .xy } }

    /// Sketches that aren't where the tutorial wants them, before the floor's sketch exists.
    var misplacedSketch: Found<SketchFeature>? {
        baseSketch == nil ? sketches().first { $0.value.plane != .xy } : nil
    }

    var baseExtrude: Found<ExtrudeFeature>? {
        guard let base = baseSketch else { return nil }
        return extrudes().first { $0.value.sketch == base.id && $0.value.face == nil }
    }

    /// The sketch for the walls and sections: the one on the floor's top face.
    var wallSketch: Found<SketchFeature>? {
        guard let floor = baseExtrude else { return nil }
        return sketches().first { s in
            if case .face(let ref) = s.value.plane { return ref.body == floor.id && ref.face.hasSuffix(".end") }
            return false
        }
    }

    /// A sketch started somewhere else once the floor is there: not where the walls go.
    var misplacedWallSketch: Found<SketchFeature>? {
        guard baseExtrude != nil, wallSketch == nil else { return nil }
        return sketches().first { $0.id != baseSketch?.id }
    }

    var wallExtrude: Found<ExtrudeFeature>? {
        guard let sketch = wallSketch else { return nil }
        return extrudes().first { $0.value.sketch == sketch.id && $0.value.face == nil }
    }

    /// The floor's whole top face pulled up (a click on the face rather than on the wall).
    var facePull: Found<ExtrudeFeature>? {
        guard let floor = baseExtrude else { return nil }
        return extrudes().first { $0.value.face?.body == floor.id }
    }

    /// The extrude fills the wall (the region round and between the sections), not a section.
    func extrudesTheWall(_ extrude: ExtrudeFeature) -> Bool {
        guard let walls, let outline = walls.match(walls.layout.outline, in: walls.solid) else { return true }
        return extrude.profiles.contains { Set($0.curves).isSuperset(of: outline.lines) }
    }

    // MARK: parameters

    /// Whether an expression uses the parameter ("wall * 2" uses "wall").
    static func uses(_ expression: String, _ parameter: String) -> Bool {
        (try? Expressions.parse(expression))?.references.contains(parameter) ?? false
    }

    var hasTutorialParameters: Bool {
        TutorialPart.parameters.allSatisfy { p in model.document.parameters.contains { $0.name == p.name } }
    }

    /// `width` and `depth` have both been given other values than the tutorial started them with.
    var parametersChanged: Bool {
        TutorialPart.parameters.filter { ["width", "depth"].contains($0.name) }.allSatisfy { start in
            model.document.parameters.first { $0.name == start.name }.map { $0.expression != start.expression } ?? false
        }
    }

    /// Whether one of `width` and `depth` has been changed yet.
    func isChanged(_ name: String) -> Bool {
        guard let start = TutorialPart.parameters.first(where: { $0.name == name }) else { return false }
        return model.document.parameters.first { $0.name == name }.map { $0.expression != start.expression } ?? false
    }

    /// Whether a parameter of the name tag has been given another value than it started with.
    func isTagChanged(_ name: String) -> Bool {
        guard let start = TutorialPart.tagParameters.first(where: { $0.name == name }) else { return false }
        return model.document.parameters.first { $0.name == name }.map { $0.expression != start.expression } ?? false
    }

    // MARK: the name tag

    /// The ring hole: a hole in the tag (any of its faces).
    var tagHole: Found<HoleFeature>? {
        guard let tag = baseExtrude else { return nil }
        return features.compactMap { f -> Found<HoleFeature>? in
            if case .hole(let h) = f.kind, !f.suppressed, h.face.body == tag.id { return (f.id, h) } else { return nil }
        }.first
    }

    /// The words typed on the tag: the first text in the sketch on its top face.
    var tagText: String? { wallSketch?.value.sketch.texts.first?.text }

    // MARK: the sections

    /// Where everything goes, from the parameters as they are now (millimetres, in the sketch's own axes: x across
    /// the width, y from the front edge to the back).
    struct Layout {
        typealias Rect = (min: SIMD2<Double>, max: SIMD2<Double>)
        var width: Double, depth: Double, wall: Double, front: Double

        /// The floor's top face.
        var outline: Rect { (.zero, SIMD2(width, depth)) }
        /// One wall thickness inside the outline: the guide the sections hang from.
        var guide: Rect { (SIMD2(wall, wall), SIMD2(width - wall, depth - wall)) }
        /// Just outside the outline, where an offset that went the wrong way ends up.
        var outsideGuide: Rect { (SIMD2(-wall, -wall), SIMD2(width + wall, depth + wall)) }
        var sectionWidth: Double { (width - 3 * wall) / 2 }
        var backBottom: Double { 2 * wall + front }
        var frontSection: Rect { (SIMD2(wall, wall), SIMD2(width - wall, wall + front)) }
        var backLeft: Rect { (SIMD2(wall, backBottom), SIMD2(wall + sectionWidth, depth - wall)) }
        var backRight: Rect { (SIMD2(width - wall - sectionWidth, backBottom), SIMD2(width - wall, depth - wall)) }
        /// The back-right section before it is made as wide as the left one: its depth is right, its width isn't known yet.
        var backRightDepth: Double { depth - wall - backBottom }

        /// Room for all three sections.
        var isUsable: Bool { sectionWidth > 0 && backRightDepth > 0 && front > 0 && wall > 0 }
    }

    var layout: Layout? {
        let p = model.parameterValues
        func length(_ name: String) -> Double? { try? p.value(of: name, kind: .length) }
        guard let w = length("width"), let d = length("depth"), let wall = length("wall"), let front = length("front") else { return nil }
        let layout = Layout(width: w, depth: d, wall: wall, front: front)
        return layout.isUsable ? layout : nil
    }

    /// A rectangle in a sketch: four lines, joined end to end, each along an axis.
    struct Box {
        var lines: [EntityID]
        var points: Set<EntityID>
        var min: SIMD2<Double>
        var max: SIMD2<Double>
        var isConstruction: Bool
        var width: Double { max.x - min.x }
        var depth: Double { max.y - min.y }
    }

    /// What the tutorial knows about the walls' sketch right now.
    struct Walls {
        var sketch: Found<SketchFeature>
        /// The sketch as the kernel last solved it, for the parameters now.
        var solved: Sketch
        var layout: Layout
        /// Every rectangle in it, drawn or guide.
        var boxes: [Box]
        /// Roots of points that are the same place (tied by coincident constraints).
        var roots: (EntityID) -> EntityID

        var solid: [Box] { boxes.filter { !$0.isConstruction } }
        var guides: [Box] { boxes.filter(\.isConstruction) }

        private static let tolerance = 1e-3

        private func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            abs(a.x - b.x) < Self.tolerance && abs(a.y - b.y) < Self.tolerance
        }

        func match(_ rect: Layout.Rect, in boxes: [Box]) -> Box? {
            boxes.first { near($0.min, rect.min) && near($0.max, rect.max) }
        }

        /// The names of the parameters that the dimensions on a box use.
        func parameters(of box: Box) -> Set<String> {
            let entities = Set(box.lines).union(box.points)
            var names = Set<String>()
            for d in solved.dimensions where Sketch.references(d.kind).contains(where: entities.contains) {
                names.formUnion((try? Expressions.parse(d.expression))?.references ?? [])
            }
            return names
        }

        /// Whether a corner of the box is a corner of the floor, which the sketch then follows.
        func followsFloor(_ box: Box) -> Bool {
            let projected = Set(solved.projections.flatMap(\.pointIDs).map(roots))
            return box.points.contains { projected.contains(roots($0)) }
        }

        // MARK: how well each part is made

        /// How far a part is along: not there, or there but not following the parameters, or done.
        enum Status: Equatable {
            case missing
            /// Sized with plain numbers only: it wouldn't follow any parameter.
            case plainNumbers
            /// Sized by parameters, but not by these ones.
            case missingParameters([String])
            case good
        }

        /// How far along a box is, given the parameters its dimensions must use.
        private func status(_ box: Box?, needing names: [String]) -> Status {
            guard let box else { return .missing }
            let used = parameters(of: box)
            guard !used.isEmpty else { return .plainNumbers }
            let missing = names.filter { !used.contains($0) }
            return missing.isEmpty ? .good : .missingParameters(missing)
        }

        /// The floor's outline, traced from its corners (or sized by `width` and `depth`).
        var outline: Status {
            guard let box = match(layout.outline, in: solid) else { return .missing }
            return followsFloor(box) ? .good : status(box, needing: ["width", "depth"])
        }

        var frontSection: Status { status(match(layout.frontSection, in: solid), needing: ["width", "front"]) }
        var backLeft: Status { status(match(layout.backLeft, in: solid), needing: ["width", "depth", "front"]) }

        var backRight: Status { status(match(layout.backRight, in: solid), needing: ["width", "depth", "front"]) }

        // MARK: the guide

        /// How the inset of the outline stands.
        enum Guide: Equatable {
            case missing
            /// It went outwards: the distance wasn't negative.
            case outward
            /// A guide in the right place, but its distance is a plain number.
            case plainNumber
            case solid
            case construction
        }

        var guide: Guide {
            if let box = match(layout.guide, in: boxes) {
                guard parameters(of: box).contains("wall") else { return .plainNumber }
                return box.isConstruction ? .construction : .solid
            }
            return match(layout.outsideGuide, in: boxes) != nil ? .outward : .missing
        }

        var guideBox: Box? { match(layout.guide, in: boxes) }

        /// An inset that went wrong: outwards, or by a plain number. It has to go before another is made.
        var wrongGuide: Box? {
            switch guide {
            case .outward: return match(layout.outsideGuide, in: boxes)
            case .plainNumber: return guideBox
            case .missing, .solid, .construction: return nil
            }
        }

        /// Rectangles that aren't the outline, the guide or a section: something drawn in the wrong place.
        var strays: [Box] {
            let expected = [layout.outline, layout.guide, layout.outsideGuide, layout.frontSection, layout.backLeft, layout.backRight]
            return solid.filter { box in !expected.contains { near(box.min, $0.min) && near(box.max, $0.max) } }
        }
    }

    /// The walls' sketch, once it exists and the kernel has solved it.
    var walls: Walls? {
        guard let sketch = wallSketch, let solved = model.result?.sketches[sketch.id]?.solved, let layout else { return nil }
        // Points tied by coincident constraints are one place.
        var parent: [EntityID: EntityID] = [:]
        func root(_ p: EntityID) -> EntityID {
            var r = p
            while let next = parent[r], next != r { r = next }
            return r
        }
        for c in solved.constraints {
            if case .coincident(let a, let b) = c.kind { let ra = root(a), rb = root(b); if ra != rb { parent[ra] = rb } }
        }
        return Walls(sketch: sketch, solved: solved, layout: layout, boxes: Self.boxes(in: solved, root: root), roots: root)
    }

    /// The rectangles in a solved sketch: groups of four lines joined end to end, all level or upright.
    static func boxes(in sketch: Sketch, root: (EntityID) -> EntityID) -> [Box] {
        let projected = Set(sketch.projections.flatMap(\.curveIDs))
        var lines: [(id: EntityID, a: EntityID, b: EntityID, construction: Bool)] = []
        for c in sketch.curves where !projected.contains(c.id) {
            if case .line(let a, let b) = c.geometry { lines.append((c.id, a, b, c.construction)) }
        }
        var boxes: [Box] = []
        for construction in [false, true] {
            var rest = lines.filter { $0.construction == construction }
            while let seed = rest.first {
                // Everything joined to the seed, end to end.
                var group = [seed]
                var frontier = [root(seed.a), root(seed.b)]
                var seen = Set(frontier)
                rest.removeFirst()
                while let p = frontier.popLast() {
                    for line in rest where root(line.a) == p || root(line.b) == p {
                        group.append(line)
                        rest.removeAll { $0.id == line.id }
                        for q in [root(line.a), root(line.b)] where seen.insert(q).inserted { frontier.append(q) }
                    }
                }
                guard group.count == 4 else { continue }
                let corners = group.flatMap { [root($0.a), root($0.b)] }
                guard Dictionary(grouping: corners, by: { $0 }).values.allSatisfy({ $0.count == 2 }) else { continue }
                let positions = group.compactMap { l in sketch.position(l.a).flatMap { a in sketch.position(l.b).map { (a, $0) } } }
                guard positions.count == 4, positions.allSatisfy({ abs($0.0.x - $0.1.x) < 1e-6 || abs($0.0.y - $0.1.y) < 1e-6 }) else { continue }
                let all = positions.flatMap { [$0.0, $0.1] }
                boxes.append(Box(lines: group.map(\.id), points: Set(group.flatMap { [$0.a, $0.b] }),
                                 min: SIMD2(all.map(\.x).min() ?? 0, all.map(\.y).min() ?? 0),
                                 max: SIMD2(all.map(\.x).max() ?? 0, all.map(\.y).max() ?? 0),
                                 isConstruction: construction))
            }
        }
        return boxes
    }

    // MARK: the floor's outline

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

    /// Whether a sketch holds the rectangle the tutorial draws: four lines, sized by `width` and `depth`, with a
    /// corner on the origin and growing up and to the right.
    static func baseOutline(of sketch: Sketch) -> Outline {
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
        guard let x0 = points.map(\.x).min(), let y0 = points.map(\.y).min() else { return .missing }
        return abs(x0) < 1e-3 && abs(y0) < 1e-3 ? .good : .offOrigin
    }
}

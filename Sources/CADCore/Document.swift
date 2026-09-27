// The parametric document: parameters + an ordered feature timeline.
// It stores design intent only; geometry is always regenerated from it.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public typealias FeatureID = String

/// Where a sketch lives.
public enum PlaneRef: Codable, Hashable, Sendable {
    case xy, xz, yz
    case face(FaceRef)
}

/// A face of a body, by persistent name ("plate.end"). `body` is the id of the feature that created the body.
public struct FaceRef: Codable, Hashable, Sendable {
    public var body: FeatureID
    public var face: String
    public init(body: FeatureID, face: String) { self.body = body; self.face = face }
}

/// An edge of a body, by persistent name ("plate.end|plate.side.L3").
public struct EdgeRef: Codable, Hashable, Sendable {
    public var body: FeatureID
    public var edge: String
    public init(body: FeatureID, edge: String) { self.body = body; self.edge = edge }
}

/// A closed sketch region, identified by the ids of the curves bounding it. `hint` (sketch u, v)
/// picks between regions bounded by the same curves, e.g. two halves of a circle split by a line.
public struct ProfileRef: Codable, Hashable, Sendable {
    public var curves: [EntityID]
    public var hintU: Double
    public var hintV: Double
    public init(curves: [EntityID], hintU: Double = 0, hintV: Double = 0) {
        self.curves = curves.sorted(); self.hintU = hintU; self.hintV = hintV
    }
    public var tagString: String { curves.joined(separator: ",") }
}

public struct SketchFeature: Codable, Hashable, Sendable {
    public var plane: PlaneRef
    public var sketch: Sketch
    public init(plane: PlaneRef, sketch: Sketch) { self.plane = plane; self.sketch = sketch }
}

public enum ExtrudeExtent: Codable, Hashable, Sendable {
    case distance(String)                      // one side
    case symmetric(String)                     // total length, centred on the sketch plane
    case twoSides(String, back: String)
}

public enum BodyOperation: String, Codable, Hashable, Sendable, CaseIterable {
    case newBody = "New Body", join = "Join", cut = "Cut", intersect = "Intersect"
}

public struct ExtrudeFeature: Codable, Hashable, Sendable {
    public var sketch: FeatureID
    public var profiles: [ProfileRef]
    public var extent: ExtrudeExtent
    /// Extrude against the sketch normal (into the material, for cuts on a face).
    public var flipped: Bool
    public var operation: BodyOperation
    /// Body to join/cut/intersect. Nil = the most recently created body.
    public var target: FeatureID?
    /// Extrude a flat face of a body instead of sketch profiles (press-pull); `sketch` is then empty.
    public var face: FaceRef?

    public init(sketch: FeatureID, profiles: [ProfileRef], extent: ExtrudeExtent, flipped: Bool = false,
                operation: BodyOperation = .newBody, target: FeatureID? = nil) {
        self.sketch = sketch; self.profiles = profiles; self.extent = extent
        self.flipped = flipped; self.operation = operation; self.target = target
    }

    /// Pulls a body's flat face out (join) or pushes it in (cut, with a negative distance).
    public init(face: FaceRef, extent: ExtrudeExtent = .distance("10 mm")) {
        self.init(sketch: "", profiles: [], extent: extent, operation: .join, target: face.body)
        self.face = face
    }
}

/// Connected sketch curves used as a path (sweep, pipe) or a rib's centre line.
public struct CurveRef: Codable, Hashable, Sendable {
    public var sketch: FeatureID
    public var curves: [EntityID]
    public init(sketch: FeatureID, curves: [EntityID]) { self.sketch = sketch; self.curves = curves }
}

/// A revolve axis: an origin axis, one of the sketch's own axes, or a line in the sketch.
public enum AxisRef: Codable, Hashable, Sendable {
    case x, y, z
    /// The sketch's horizontal / vertical axis through its origin.
    case sketchX, sketchY
    case line(EntityID)
}

public struct RevolveFeature: Codable, Hashable, Sendable {
    public var sketch: FeatureID
    public var profiles: [ProfileRef]
    public var axis: AxisRef
    public var angle: String
    public var operation: BodyOperation
    public var target: FeatureID?
    public init(sketch: FeatureID, profiles: [ProfileRef], axis: AxisRef, angle: String = "360 deg",
                operation: BodyOperation = .newBody, target: FeatureID? = nil) {
        self.sketch = sketch; self.profiles = profiles; self.axis = axis; self.angle = angle
        self.operation = operation; self.target = target
    }
}

public struct SweepFeature: Codable, Hashable, Sendable {
    public var sketch: FeatureID
    public var profiles: [ProfileRef]
    public var path: CurveRef
    public var operation: BodyOperation
    public var target: FeatureID?
    public init(sketch: FeatureID, profiles: [ProfileRef], path: CurveRef, operation: BodyOperation = .newBody,
                target: FeatureID? = nil) {
        self.sketch = sketch; self.profiles = profiles; self.path = path; self.operation = operation; self.target = target
    }
}

/// One cross-section of a loft: a profile in a sketch.
public struct LoftSection: Codable, Hashable, Sendable {
    public var sketch: FeatureID
    public var profile: ProfileRef
    public init(sketch: FeatureID, profile: ProfileRef) { self.sketch = sketch; self.profile = profile }
}

public struct LoftFeature: Codable, Hashable, Sendable {
    public var sections: [LoftSection]
    /// Straight sides between sections instead of smooth ones.
    public var ruled: Bool
    public var operation: BodyOperation
    public var target: FeatureID?
    public init(sections: [LoftSection], ruled: Bool = false, operation: BodyOperation = .newBody, target: FeatureID? = nil) {
        self.sections = sections; self.ruled = ruled; self.operation = operation; self.target = target
    }
}

/// A thin wall grown from an open sketch curve until it meets the body, thickened across the sketch plane.
public struct RibFeature: Codable, Hashable, Sendable {
    public var path: CurveRef
    public var thickness: String
    /// Body to add the rib to. Nil = the most recently created body.
    public var target: FeatureID?
    public init(path: CurveRef, thickness: String = "2 mm", target: FeatureID? = nil) {
        self.path = path; self.thickness = thickness; self.target = target
    }
}

public enum HoleKind: String, Codable, Hashable, Sendable, CaseIterable {
    case simple = "Simple", counterbore = "Counterbore", countersink = "Countersink"
}

/// A drilled hole on a flat face, at (u, v) in the face's plane frame.
public struct HoleFeature: Codable, Hashable, Sendable {
    public var face: FaceRef
    public var u: String
    public var v: String
    public var kind: HoleKind
    public var diameter: String
    /// Depth of the full diameter; nil = through all.
    public var depth: String?
    /// Drill point angle; "0 deg" = flat bottom.
    public var tipAngle: String
    public var headDiameter: String
    public var headDepth: String
    public var headAngle: String
    public init(face: FaceRef, u: String, v: String, kind: HoleKind = .simple, diameter: String = "5 mm",
                depth: String? = "10 mm", tipAngle: String = "118 deg", headDiameter: String = "9 mm",
                headDepth: String = "3 mm", headAngle: String = "90 deg") {
        self.face = face; self.u = u; self.v = v; self.kind = kind; self.diameter = diameter; self.depth = depth
        self.tipAngle = tipAngle; self.headDiameter = headDiameter; self.headDepth = headDepth; self.headAngle = headAngle
    }
}

public enum PrimitiveKind: String, Codable, Hashable, Sendable, CaseIterable {
    case box = "Box", cylinder = "Cylinder", sphere = "Sphere", torus = "Torus", coil = "Coil"
}

/// A box, cylinder, sphere, torus or coil standing on a plane, centred at (u, v) in the plane's frame.
/// Sizes each kind uses: box width, length, height · cylinder diameter, height · sphere diameter ·
/// torus diameter, tube · coil diameter, tube (section), pitch, turns.
public struct PrimitiveFeature: Codable, Hashable, Sendable {
    public var kind: PrimitiveKind
    public var plane: PlaneRef
    public var u: String
    public var v: String
    public var width: String
    public var length: String
    public var height: String
    public var diameter: String
    public var tube: String
    public var pitch: String
    public var turns: String
    public var operation: BodyOperation
    public var target: FeatureID?
    public init(kind: PrimitiveKind, plane: PlaneRef, u: String = "0 mm", v: String = "0 mm", width: String = "20 mm",
                length: String = "20 mm", height: String = "20 mm", diameter: String = "20 mm", tube: String = "4 mm",
                pitch: String = "6 mm", turns: String = "4", operation: BodyOperation = .newBody, target: FeatureID? = nil) {
        self.kind = kind; self.plane = plane; self.u = u; self.v = v; self.width = width; self.length = length
        self.height = height; self.diameter = diameter; self.tube = tube; self.pitch = pitch; self.turns = turns
        self.operation = operation; self.target = target
    }
}

/// A round pipe along a path; `wall` makes it hollow.
public struct PipeFeature: Codable, Hashable, Sendable {
    public var path: CurveRef
    public var diameter: String
    public var wall: String?
    public var operation: BodyOperation
    public var target: FeatureID?
    public init(path: CurveRef, diameter: String = "5 mm", wall: String? = nil, operation: BodyOperation = .newBody,
                target: FeatureID? = nil) {
        self.path = path; self.diameter = diameter; self.wall = wall; self.operation = operation; self.target = target
    }
}

public enum Axis3: String, Codable, Hashable, Sendable, CaseIterable {
    case x = "X", y = "Y", z = "Z"
}

/// Moves bodies and sketches by (dx, dy, dz). `arrow` is the direction the drag handle points along.
/// A moved sketch is moved for the features after this one.
public struct MoveFeature: Codable, Hashable, Sendable {
    public var bodies: [FeatureID]
    public var sketches: [FeatureID]
    public var dx: String
    public var dy: String
    public var dz: String
    public var arrow: Axis3
    public init(bodies: [FeatureID], sketches: [FeatureID] = [], dx: String = "0 mm", dy: String = "0 mm",
                dz: String = "0 mm", arrow: Axis3 = .x) {
        self.bodies = bodies; self.sketches = sketches; self.dx = dx; self.dy = dy; self.dz = dz; self.arrow = arrow
    }

    private enum CodingKeys: String, CodingKey { case bodies, sketches, dx, dy, dz, arrow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodies = try c.decode([FeatureID].self, forKey: .bodies)
        sketches = try c.decodeIfPresent([FeatureID].self, forKey: .sketches) ?? []  // older files move bodies only
        dx = try c.decode(String.self, forKey: .dx)
        dy = try c.decode(String.self, forKey: .dy)
        dz = try c.decode(String.self, forKey: .dz)
        arrow = try c.decode(Axis3.self, forKey: .arrow)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bodies, forKey: .bodies)
        if !sketches.isEmpty { try c.encode(sketches, forKey: .sketches) }
        try c.encode(dx, forKey: .dx)
        try c.encode(dy, forKey: .dy)
        try c.encode(dz, forKey: .dz)
        try c.encode(arrow, forKey: .arrow)
    }
}

/// Combines bodies: joins the tool bodies to the target, cuts them out of it, or keeps only where
/// they overlap. The tool bodies are used up unless `keepTools` is set.
public struct CombineFeature: Codable, Hashable, Sendable {
    public var target: FeatureID
    public var tools: [FeatureID]
    /// Join, Cut or Intersect (New Body isn't offered).
    public var operation: BodyOperation
    public var keepTools: Bool
    public init(target: FeatureID, tools: [FeatureID], operation: BodyOperation = .cut, keepTools: Bool = false) {
        self.target = target; self.tools = tools; self.operation = operation; self.keepTools = keepTools
    }
}

/// Rotates bodies about an axis (parallel to X, Y or Z) through the middle of their bounding box.
public struct RotateFeature: Codable, Hashable, Sendable {
    public var bodies: [FeatureID]
    public var axis: Axis3
    public var angle: String
    public init(bodies: [FeatureID], axis: Axis3 = .z, angle: String = "0 deg") {
        self.bodies = bodies; self.axis = axis; self.angle = angle
    }
}

/// Fillet (size = radius) or chamfer (size = distance) on a set of edges.
public struct EdgeFeature: Codable, Hashable, Sendable {
    public var edges: [EdgeRef]
    public var size: String
    public init(edges: [EdgeRef], size: String) { self.edges = edges; self.size = size }
}

public struct Feature: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        case sketch(SketchFeature)
        case extrude(ExtrudeFeature)
        case fillet(EdgeFeature)
        case chamfer(EdgeFeature)
        case revolve(RevolveFeature)
        case sweep(SweepFeature)
        case loft(LoftFeature)
        case rib(RibFeature)
        case hole(HoleFeature)
        case primitive(PrimitiveFeature)
        case pipe(PipeFeature)
        case move(MoveFeature)
        case rotate(RotateFeature)
        case combine(CombineFeature)
    }
    public var id: FeatureID
    public var name: String
    public var suppressed: Bool
    public var kind: Kind

    public init(id: FeatureID = IDs.make(), name: String, suppressed: Bool = false, _ kind: Kind) {
        self.id = id; self.name = name; self.suppressed = suppressed; self.kind = kind
    }

    public var typeName: String {
        switch kind {
        case .sketch: return "Sketch"
        case .extrude: return "Extrude"
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        case .revolve: return "Revolve"
        case .sweep: return "Sweep"
        case .loft: return "Loft"
        case .rib: return "Rib"
        case .hole: return "Hole"
        case .primitive(let p): return p.kind.rawValue
        case .pipe: return "Pipe"
        case .move: return "Move"
        case .rotate: return "Rotate"
        case .combine: return "Combine"
        }
    }

    /// Sketches this feature is built from (they are hidden once used, as in other CAD tools).
    public var sketchesUsed: [FeatureID] {
        switch kind {
        case .sketch, .fillet, .chamfer, .hole, .primitive, .move, .rotate, .combine: return []
        case .extrude(let e): return e.face == nil ? [e.sketch] : []
        case .revolve(let r): return [r.sketch]
        case .sweep(let s): return [s.sketch, s.path.sketch]
        case .loft(let l): return l.sections.map(\.sketch)
        case .rib(let r): return [r.path.sketch]
        case .pipe(let p): return [p.path.sketch]
        }
    }

    /// Whether the feature makes a new body (rather than changing an existing one).
    public var createsBody: Bool {
        switch kind {
        case .extrude(let e): return e.operation == .newBody
        case .revolve(let r): return r.operation == .newBody
        case .sweep(let s): return s.operation == .newBody
        case .loft(let l): return l.operation == .newBody
        case .primitive(let p): return p.operation == .newBody
        case .pipe(let p): return p.operation == .newBody
        case .sketch, .fillet, .chamfer, .rib, .hole, .move, .rotate, .combine: return false
        }
    }
}

public struct CADDocument: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public var version: Int = CADDocument.formatVersion
    public var parameters: [Parameter] = []
    public var features: [Feature] = []
    /// Timeline marker: only the first `rollback` features are regenerated. Nil = all.
    public var rollback: Int?
    /// Bodies and sketches hidden in the viewport, by the id of the feature that made them.
    public var hidden: Set<FeatureID> = []
    /// Names given to bodies, by the id of the feature that made them (others are "Body1", "Body2"…).
    public var bodyNames: [FeatureID: String] = [:]

    public init(parameters: [Parameter] = [], features: [Feature] = []) {
        self.parameters = parameters; self.features = features
    }

    private enum CodingKeys: String, CodingKey { case version, parameters, features, rollback, hidden, bodyNames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        parameters = try c.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        features = try c.decodeIfPresent([Feature].self, forKey: .features) ?? []
        rollback = try c.decodeIfPresent(Int.self, forKey: .rollback)
        hidden = try c.decodeIfPresent(Set<FeatureID>.self, forKey: .hidden) ?? []  // older files have none
        bodyNames = try c.decodeIfPresent([FeatureID: String].self, forKey: .bodyNames) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(features, forKey: .features)
        try c.encodeIfPresent(rollback, forKey: .rollback)
        if !hidden.isEmpty { try c.encode(hidden.sorted(), forKey: .hidden) }  // sorted: stable files
        if !bodyNames.isEmpty { try c.encode(bodyNames, forKey: .bodyNames) }  // sorted keys when encoded()
    }

    /// The same design with visibility and names ignored: changing those needs no rebuild.
    public var ignoringPresentation: CADDocument {
        var d = self
        d.hidden = []
        d.bodyNames = [:]
        for i in d.features.indices { d.features[i].name = "" }
        return d
    }

    public var activeFeatures: ArraySlice<Feature> { features.prefix(rollback ?? features.count) }

    public func index(of id: FeatureID) -> Int? { features.firstIndex { $0.id == id } }

    /// Next free "<base><n>" name, e.g. "Fillet3".
    public func nextName(_ base: String) -> String {
        var n = 1
        while features.contains(where: { $0.name == "\(base)\(n)" }) { n += 1 }
        return "\(base)\(n)"
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> CADDocument {
        let doc = try JSONDecoder().decode(CADDocument.self, from: data)
        guard doc.version <= formatVersion else {
            throw ExpressionError("this file was made by a newer SimplCAD (format \(doc.version))")
        }
        return doc
    }
}

// MARK: - Demo document

extension CADDocument {
    /// A plate with a centred hole, a pin hole cut from a sketch on its top face,
    /// two filleted corners and a chamfered top edge — all driven by parameters.
    public static func demo() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            Parameter("width", "60 mm"),
            Parameter("depth", "40 mm"),
            Parameter("thickness", "10 mm"),
            Parameter("hole_d", "depth / 4", comment: "follows depth"),
            Parameter("pin_d", "6 mm"),
            Parameter("corner_r", "5 mm"),
            Parameter("edge_chamfer", "1.5 mm"),
        ]

        // Sketch 1 on XY: rectangle anchored at the origin + centred hole.
        var s1 = Sketch()
        let rect = s1.addRectangle(0, 0, 60, 40, lineIDs: ["L0", "L1", "L2", "L3"])
        s1.constrain(.coincident(rect.corners[0], "origin"))
        s1.dimension(.length("L0"), "width")
        s1.dimension(.length("L1"), "depth")
        let c = s1.addPoint(30, 20)
        s1.addCircle(center: c, radius: 5, id: "C0")
        s1.dimension(.diameter("C0"), "hole_d")
        s1.dimension(.horizontalDistance("origin", c), "width / 2")
        s1.dimension(.verticalDistance("origin", c), "depth / 2")
        let base = Feature(id: "base", name: "Base Sketch", .sketch(SketchFeature(plane: .xy, sketch: s1)))

        let plate = Feature(id: "plate", name: "Plate", .extrude(ExtrudeFeature(
            sketch: "base", profiles: [ProfileRef(curves: ["C0", "L0", "L1", "L2", "L3"])],
            extent: .distance("thickness"))))

        // Sketch 2 on the plate's top face (persistent name "plate.end").
        var s2 = Sketch()
        let q = s2.addPoint(12, 20)
        s2.addCircle(center: q, radius: 3, id: "C1")
        s2.dimension(.diameter("C1"), "pin_d")
        s2.dimension(.horizontalDistance("origin", q), "width * 0.2")
        s2.dimension(.verticalDistance("origin", q), "depth / 2")
        let pinSketch = Feature(id: "pinsk", name: "Pin Sketch",
                                .sketch(SketchFeature(plane: .face(FaceRef(body: "plate", face: "plate.end")), sketch: s2)))

        let pin = Feature(id: "pin", name: "Pin Hole", .extrude(ExtrudeFeature(
            sketch: "pinsk", profiles: [ProfileRef(curves: ["C1"])], extent: .distance("2 * thickness"),
            flipped: true, operation: .cut, target: "plate")))

        let corners = Feature(id: "corners", name: "Corner Fillets", .fillet(EdgeFeature(
            edges: [EdgeRef(body: "plate", edge: "plate.side.L0|plate.side.L1"),
                    EdgeRef(body: "plate", edge: "plate.side.L2|plate.side.L3")],
            size: "corner_r")))

        let chamfer = Feature(id: "topedge", name: "Top Chamfer", .chamfer(EdgeFeature(
            edges: [EdgeRef(body: "plate", edge: "plate.end|plate.side.L3")], size: "edge_chamfer")))

        doc.features = [base, plate, pinSketch, pin, corners, chamfer]
        return doc
    }
}

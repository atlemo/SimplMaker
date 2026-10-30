// The parametric document: parameters + an ordered feature timeline.
// It stores design intent only; geometry is always regenerated from it.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

public typealias FeatureID = String

/// Where a sketch lives.
public enum PlaneRef: Codable, Hashable, Sendable {
    case xy, xz, yz
    case face(FaceRef)
    /// A construction plane, by the id of its Plane feature.
    case plane(FeatureID)

    /// A face or a construction plane, whose axes can point any way (not an origin plane).
    public var isFaceOrPlane: Bool {
        switch self {
        case .face, .plane: return true
        case .xy, .xz, .yz: return false
        }
    }
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
    /// On a face or construction plane: the sketch's x axis runs level and its y axis upward, as the
    /// view shows the plane (true: every new sketch), or the kernel's own axes for the face, which
    /// can point any way (nil: sketches from before; Straighten Axes in the inspector turns one
    /// upright). The origin planes' axes are upright already.
    public var uprightAxes: Bool?
    public init(plane: PlaneRef, sketch: Sketch, uprightAxes: Bool? = true) {
        self.plane = plane; self.sketch = sketch; self.uprightAxes = uprightAxes
    }
}

public enum ExtrudeExtent: Codable, Hashable, Sendable {
    case distance(String)                      // one side
    case symmetric(String)                     // total length, centred on the sketch plane
    case twoSides(String, back: String)
    /// Far enough to go through every body there is (for cuts, mostly).
    case throughAll
    /// Up to a flat face parallel to the sketch, wherever that face ends up.
    case toFace(FaceRef)
}

/// How far an extrude reaches from its sketch plane, the three ways with a typed size (the toolbar's choices).
public enum ExtrudeMode: String, Codable, CaseIterable, Sendable {
    /// One distance, to one side of the plane.
    case oneDirection
    /// A distance on each side of the plane.
    case twoDirections
    /// One length shared evenly: half to each side of the plane.
    case mirrored

    public var title: String {
        switch self {
        case .oneDirection: return "One Direction Extrude"
        case .twoDirections: return "Two Directions Extrude"
        case .mirrored: return "Mirrored Extrude"
        }
    }

    /// The title under its icon in the toolbar.
    public var shortTitle: String {
        switch self {
        case .oneDirection: return "One Direction"
        case .twoDirections: return "Two Directions"
        case .mirrored: return "Mirrored"
        }
    }
}

extension ExtrudeExtent {
    /// Which of the three sized ways this is; nil for Through All and To Face, which take no size.
    public var mode: ExtrudeMode? {
        switch self {
        case .distance: return .oneDirection
        case .twoSides: return .twoDirections
        case .symmetric: return .mirrored
        case .throughAll, .toFace: return nil
        }
    }

    /// The first (or only, or total) size typed, if the extent has one.
    public var size: String? {
        switch self {
        case .distance(let d), .symmetric(let d), .twoSides(let d, _): return d
        case .throughAll, .toFace: return nil
        }
    }

    /// The same size, reaching the way `new` says. The size carries over; a second side starts as
    /// long as the first.
    public func changed(to new: ExtrudeMode, fallback: String = "4 mm") -> ExtrudeExtent {
        let d = size ?? fallback
        switch new {
        case .oneDirection: return .distance(d)
        case .mirrored: return .symmetric(d)
        case .twoDirections:
            if case .twoSides = self { return self }
            return .twoSides(d, back: d)
        }
    }
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
    /// The bodies a Join, Cut or Intersect works on, picked in the Inspector; it wins over `target`. Nil = automatic:
    /// a cut goes through every body it reaches, a join or intersect works on `target` or else the newest body.
    /// A join with several bodies merges them into the first one.
    public var targets: [FeatureID]?
    /// Extrude a flat face of a body instead of sketch profiles (press-pull); `sketch` is then empty.
    public var face: FaceRef?
    /// How far the sides lean as they leave the sketch plane, an angle expression: positive leans out (the
    /// shape grows as it goes), negative leans in. Nil (and zero) is a straight extrude.
    public var taper: String?
    /// Start from this flat face (parallel to the sketch) instead of the sketch plane: the profile is carried to
    /// the face's plane and extruded from there. Nil = start on the sketch plane.
    public var start: FaceRef?

    public init(sketch: FeatureID, profiles: [ProfileRef], extent: ExtrudeExtent, flipped: Bool = false,
                operation: BodyOperation = .newBody, target: FeatureID? = nil) {
        self.sketch = sketch; self.profiles = profiles; self.extent = extent
        self.flipped = flipped; self.operation = operation; self.target = target
    }

    /// Pulls a body's flat face out (join) or pushes it in (cut, with a negative distance).
    public init(face: FaceRef, extent: ExtrudeExtent = .distance("4 mm")) {
        self.init(sketch: "", profiles: [], extent: extent, operation: .join, target: face.body)
        self.face = face
    }
}

/// How a projection meets the surface it lands on.
public enum ProjectMode: String, Codable, CaseIterable, Sendable {
    /// Stands out of the surface and joins the body (raised lettering).
    case emboss = "Emboss"
    /// Goes into the surface and is cut out of the body (engraved lettering).
    case deboss = "Deboss"
}

/// Sketch profiles (text, shapes) projected onto a body the way a projector throws them on a wall: along the
/// sketch's normal (or against it, flipped), landing on the faces that face the sketch. What lands follows the
/// surface, curved or flat, and is `height` thick along the surface's normals: raised (emboss) or cut in (deboss).
public struct ProjectFeature: Codable, Hashable, Sendable {
    public var sketch: FeatureID
    public var profiles: [ProfileRef]
    /// The body projected onto, by the id of the feature that made it.
    public var target: FeatureID
    /// The faces projected onto; none = every face of the body that faces the sketch.
    public var faces: [FaceRef]
    public var mode: ProjectMode
    /// How far it stands out of the surface or sinks into it (always more than zero; `mode` says which way).
    public var height: String
    /// Project against the sketch's normal, as for an extrude.
    public var flipped: Bool
    public init(sketch: FeatureID, profiles: [ProfileRef], target: FeatureID, faces: [FaceRef] = [], mode: ProjectMode = .emboss,
                height: String = "1 mm", flipped: Bool = false) {
        self.sketch = sketch; self.profiles = profiles; self.target = target; self.faces = faces
        self.mode = mode; self.height = height; self.flipped = flipped
    }

    /// Sets the height from a size as typed or dragged: a negative one sinks the profiles in (a deboss), a positive one
    /// stands them out (an emboss), so one size drags both ways. The mode follows the sign; the height stays positive.
    public mutating func setHeight(_ text: String) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let sinks = typed.hasPrefix("-")
        height = sinks ? String(typed.dropFirst()).trimmingCharacters(in: .whitespaces) : typed
        mode = sinks ? .deboss : .emboss
    }

    /// The height as a signed size: negative for a deboss, which is what a drag handle shows and sets.
    public var signedHeight: String { mode == .deboss ? "-(\(height))" : height }
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
    /// The bodies a Join, Cut or Intersect works on, picked in the Inspector; it wins over `target`. Nil = automatic,
    /// as for an extrude: a cut goes through every body it reaches, a join or intersect works on `target` or else the
    /// newest body. A join with several bodies merges them into the first one.
    public var targets: [FeatureID]?
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
    /// Body to add the rib to. Nil = the body the rib adds the most to (the newest one wins a tie).
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

/// Moves and turns bodies and sketches: first turned by (rx, ry, rz) about axes parallel to X, Y and Z
/// through the pivot (the middle of what moves, unless a pivot point is set), in that order, then moved by (dx, dy, dz). A moved sketch is moved
/// for the features after this one. `arrow` and `rotating` say which value the drag handle's typed
/// field sets: the distance along `arrow`, or, when `rotating`, the turn about it.
public struct MoveFeature: Codable, Hashable, Sendable {
    public var bodies: [FeatureID]
    public var sketches: [FeatureID]
    public var dx: String
    public var dy: String
    public var dz: String
    public var rx: String
    public var ry: String
    public var rz: String
    public var arrow: Axis3
    public var rotating: Bool
    /// The point (in world coordinates, before the move) the turns are about. All three or none: none means
    /// the middle of what moves.
    public var pivotX: String?
    public var pivotY: String?
    public var pivotZ: String?
    public init(bodies: [FeatureID], sketches: [FeatureID] = [], dx: String = "0 mm", dy: String = "0 mm",
                dz: String = "0 mm", rx: String = "0 deg", ry: String = "0 deg", rz: String = "0 deg",
                arrow: Axis3 = .x, rotating: Bool = false, pivot: [String]? = nil) {
        self.bodies = bodies; self.sketches = sketches; self.dx = dx; self.dy = dy; self.dz = dz
        self.rx = rx; self.ry = ry; self.rz = rz; self.arrow = arrow; self.rotating = rotating
        self.pivot = pivot
    }

    /// The pivot point as three expressions, or nil for the middle of what moves.
    public var pivot: [String]? {
        get { if let x = pivotX, let y = pivotY, let z = pivotZ { return [x, y, z] } else { return nil } }
        set { pivotX = newValue?[0]; pivotY = newValue?[1]; pivotZ = newValue?[2] }
    }

    private enum CodingKeys: String, CodingKey { case bodies, sketches, dx, dy, dz, rx, ry, rz, arrow, rotating, pivotX, pivotY, pivotZ }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodies = try c.decode([FeatureID].self, forKey: .bodies)
        sketches = try c.decodeIfPresent([FeatureID].self, forKey: .sketches) ?? []  // older files move bodies only
        dx = try c.decode(String.self, forKey: .dx)
        dy = try c.decode(String.self, forKey: .dy)
        dz = try c.decode(String.self, forKey: .dz)
        rx = try c.decodeIfPresent(String.self, forKey: .rx) ?? "0 deg"  // older files only move
        ry = try c.decodeIfPresent(String.self, forKey: .ry) ?? "0 deg"
        rz = try c.decodeIfPresent(String.self, forKey: .rz) ?? "0 deg"
        arrow = try c.decode(Axis3.self, forKey: .arrow)
        rotating = try c.decodeIfPresent(Bool.self, forKey: .rotating) ?? false
        pivotX = try c.decodeIfPresent(String.self, forKey: .pivotX)  // older files turn about the middle
        pivotY = try c.decodeIfPresent(String.self, forKey: .pivotY)
        pivotZ = try c.decodeIfPresent(String.self, forKey: .pivotZ)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bodies, forKey: .bodies)
        if !sketches.isEmpty { try c.encode(sketches, forKey: .sketches) }
        try c.encode(dx, forKey: .dx)
        try c.encode(dy, forKey: .dy)
        try c.encode(dz, forKey: .dz)
        // Older versions of the app read files that don't turn anything; keep them that way.
        if [rx, ry, rz] != ["0 deg", "0 deg", "0 deg"] { try c.encode(rx, forKey: .rx); try c.encode(ry, forKey: .ry); try c.encode(rz, forKey: .rz) }
        try c.encode(arrow, forKey: .arrow)
        if rotating { try c.encode(rotating, forKey: .rotating) }
        if let pivot { try c.encode(pivot[0], forKey: .pivotX); try c.encode(pivot[1], forKey: .pivotY); try c.encode(pivot[2], forKey: .pivotZ) }
    }

    /// The distance along an axis, or the turn about it, as stored.
    public func distance(_ a: Axis3) -> String { a == .x ? dx : a == .y ? dy : dz }
    public func turn(_ a: Axis3) -> String { a == .x ? rx : a == .y ? ry : rz }
}

/// Which of a plane's own axes (through its origin) a construction plane turns about.
public enum PlaneAxis: String, Codable, Hashable, Sendable, CaseIterable {
    case horizontal = "Horizontal", vertical = "Vertical"
}

/// How far a drawn construction plane reaches from its origin along its own axes, in mm. Only the
/// drawing: a plane is endless to everything that sketches on it or mirrors across it.
public struct PlaneExtent: Codable, Hashable, Sendable {
    public var uMin: Double, uMax: Double, vMin: Double, vMax: Double
    public init(uMin: Double, uMax: Double, vMin: Double, vMax: Double) {
        self.uMin = uMin; self.uMax = uMax; self.vMin = vMin; self.vMax = vMax
    }
    /// A square centred on the origin.
    public init(side: Double) { self.init(uMin: -side / 2, uMax: side / 2, vMin: -side / 2, vMax: side / 2) }
}

/// A construction plane: another plane (an origin plane, a flat face or another construction
/// plane) turned about one of its axes, then moved along its normal.
public struct PlaneFeature: Codable, Hashable, Sendable {
    public var base: PlaneRef
    public var offset: String
    public var angle: String
    public var axis: PlaneAxis
    /// The size it is drawn at, once an edge has been dragged; until then a square sized to the model.
    /// Changing it rebuilds nothing (see `CADDocument.ignoringPresentation`).
    public var extent: PlaneExtent?
    public init(base: PlaneRef, offset: String = "10 mm", angle: String = "0 deg", axis: PlaneAxis = .horizontal,
                extent: PlaneExtent? = nil) {
        self.base = base; self.offset = offset; self.angle = angle; self.axis = axis; self.extent = extent
    }
}

/// Mirrors bodies across a plane, or along a line: an origin axis or a straight edge. Along a line, the
/// mirror plane contains the line and stands square to the plane the line lies in (for an edge, its first
/// flat face; for the X and Y axes the floor; for the Z axis the XZ plane), so the copy is a true mirror
/// image. When `line` is set, `plane` is not used. Join adds each mirrored copy to its body; New Body keeps
/// the copies as a body of their own.
public struct MirrorFeature: Codable, Hashable, Sendable {
    public var bodies: [FeatureID]
    public var plane: PlaneRef
    public var operation: BodyOperation
    /// The axis or edge to mirror along instead of across `plane`.
    public var line: PatternAxis?
    public init(bodies: [FeatureID], plane: PlaneRef = .yz, operation: BodyOperation = .join, line: PatternAxis? = nil) {
        self.bodies = bodies; self.plane = plane; self.operation = operation; self.line = line
    }
}

/// A direction or axis for patterns: an origin axis, or a straight edge of a body.
public enum PatternAxis: Codable, Hashable, Sendable {
    case x, y, z
    case edge(EdgeRef)
}

public enum PatternKind: String, Codable, Hashable, Sendable, CaseIterable {
    case linear = "Linear", circular = "Circular"
}

/// Copies bodies in a row (linear: `spacing` apart along `axis`) or around an axis (circular:
/// spread over `spacing` degrees, 360 = all the way round). `count` includes the original.
public struct PatternFeature: Codable, Hashable, Sendable {
    public var kind: PatternKind
    public var bodies: [FeatureID]
    public var axis: PatternAxis
    public var count: String
    public var spacing: String
    public var operation: BodyOperation
    public init(kind: PatternKind, bodies: [FeatureID], axis: PatternAxis = .x, count: String = "3",
                spacing: String? = nil, operation: BodyOperation = .join) {
        self.kind = kind; self.bodies = bodies; self.axis = axis; self.count = count
        self.spacing = spacing ?? (kind == .linear ? "20 mm" : "360 deg"); self.operation = operation
    }
}

/// Hollows a body: the picked faces are removed (left open) and the rest becomes walls.
public struct ShellFeature: Codable, Hashable, Sendable {
    public var body: FeatureID
    public var faces: [FaceRef]
    public var thickness: String
    /// Walls grow into the body (true) or out of it.
    public var inside: Bool
    public init(body: FeatureID, faces: [FaceRef], thickness: String = "2 mm", inside: Bool = true) {
        self.body = body; self.faces = faces; self.thickness = thickness; self.inside = inside
    }
}

/// Leans faces over by a draft angle, as a mould needs: each picked face keeps the line where it meets the
/// `fixed` face (a flat face of the same body) and tilts away from it, so the body gets narrower the further
/// it goes from that face. A negative angle leans them the other way and widens it.
public struct DraftFeature: Codable, Hashable, Sendable {
    public var body: FeatureID
    /// The faces to lean.
    public var faces: [FaceRef]
    /// The flat face that stays put: its plane is the one the faces pivot about, and its inward normal is the pull
    /// direction. Nil when the model offered none (the feature then says what is missing).
    public var fixed: FaceRef?
    public var angle: String
    public init(body: FeatureID, faces: [FaceRef], fixed: FaceRef?, angle: String = "5 deg") {
        self.body = body; self.faces = faces; self.fixed = fixed; self.angle = angle
    }
}

/// Divides bodies into new bodies along a plane, a face or a sketch profile. A plane or a flat face cuts all the way
/// through (it runs on without end); a curved face cuts only where it is. A body the tool doesn't cross stays as it
/// is. The pieces of a body come in a fixed order: the first keeps the body's identity, the rest are bodies of
/// their own.
public struct SplitFeature: Codable, Hashable, Sendable {
    public enum Tool: Codable, Hashable, Sendable {
        /// An origin plane or a construction plane.
        case plane(PlaneRef)
        /// A face of a body: its plane when it is flat, the face itself when it is curved.
        case face(FaceRef)
        /// A profile of a sketch, by the id of the sketch: the plane the sketch lies on.
        case profile(FeatureID)
        /// No cut: each separate solid of the body becomes a body of its own (Split into Parts).
        case parts
    }
    public var bodies: [FeatureID]
    public var tool: Tool
    public init(bodies: [FeatureID], tool: Tool) { self.bodies = bodies; self.tool = tool }
}

/// Lays a body on the floor (the XY plane, z = 0, with Z up): turns it so the picked flat face looks straight down,
/// then lets it drop until that face sits flush. The face stays where it is sideways.
public struct LayOnFloorFeature: Codable, Hashable, Sendable {
    public var face: FaceRef
    public init(face: FaceRef) { self.face = face }
}

/// Combines bodies: joins the tool bodies to the target, cuts them out of it, or keeps only where
/// they overlap. The tool bodies are used up unless `keepTools` is set.
public struct CombineFeature: Codable, Hashable, Sendable {
    public var target: FeatureID
    public var tools: [FeatureID]
    /// Join, Cut or Intersect (New Body isn't offered).
    public var operation: BodyOperation
    public var keepTools: Bool
    public init(target: FeatureID, tools: [FeatureID], operation: BodyOperation = .join, keepTools: Bool = false) {
        self.target = target; self.tools = tools; self.operation = operation; self.keepTools = keepTools
    }
}

/// Scales sketches and bodies evenly. Sketches scale about their own origins; the features after it see the
/// scaled sketches, while a sketch itself stays as it was drawn, so its dimensions and this factor stay editable.
/// Bodies scale about the middle of their bounding box (all the bodies together, so their layout scales too).
public struct ScaleFeature: Codable, Hashable, Sendable {
    public var sketches: [FeatureID]
    public var bodies: [FeatureID]
    /// Plain number, or an expression: "2", "width / 40".
    public var factor: String
    public init(sketches: [FeatureID] = [], bodies: [FeatureID] = [], factor: String = "1") {
        self.sketches = sketches; self.bodies = bodies; self.factor = factor
    }

    private enum CodingKeys: String, CodingKey { case sketches, bodies, factor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sketches = try c.decode([FeatureID].self, forKey: .sketches)
        bodies = try c.decodeIfPresent([FeatureID].self, forKey: .bodies) ?? []  // older files scale sketches only
        factor = try c.decode(String.self, forKey: .factor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sketches, forKey: .sketches)
        if !bodies.isEmpty { try c.encode(bodies, forKey: .bodies) }
        try c.encode(factor, forKey: .factor)
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

/// How a chamfer is measured.
public enum ChamferMode: String, Codable, CaseIterable, Sendable {
    /// The same distance from the edge on both faces.
    case equalDistance
    /// A distance on one face, and the angle the chamfer makes with it.
    case distanceAngle
    /// A distance on each face.
    case twoDistances

    public var title: String {
        switch self {
        case .equalDistance: return "Equal Distance Chamfer"
        case .distanceAngle: return "Distance and Angle Chamfer"
        case .twoDistances: return "Two Distance Chamfer"
        }
    }

    /// The title under its icon in the toolbar.
    public var shortTitle: String {
        switch self {
        case .equalDistance: return "Equal Distance"
        case .distanceAngle: return "Distance and Angle"
        case .twoDistances: return "Two Distance"
        }
    }

    /// What the second value is: an angle, a length, or nothing.
    public var secondKind: UnitKind? {
        switch self {
        case .equalDistance: return nil
        case .distanceAngle: return .angle
        case .twoDistances: return .length
        }
    }
}

/// Fillet (size = radius) or chamfer (size = distance) on a set of edges, and on every edge
/// around a set of faces (found again at each rebuild, so they follow the face as it changes).
/// A chamfer can also be measured two ways (`mode`): `size` is then the distance on one face, and
/// `second` the distance on the other face or the angle to the first.
public struct EdgeFeature: Codable, Hashable, Sendable {
    public var edges: [EdgeRef]
    public var faces: [FaceRef]
    public var size: String
    public var mode: ChamferMode
    /// The chamfer's second distance or angle (see `mode`); empty for an equal-distance chamfer.
    public var second: String
    /// The first distance goes on the other of the edge's two faces. Without it: on the picked face when
    /// faces were picked, else on the face with the smaller name.
    public var flipped: Bool

    public init(edges: [EdgeRef], faces: [FaceRef] = [], size: String, mode: ChamferMode = .equalDistance, second: String = "",
                flipped: Bool = false) {
        self.edges = edges; self.faces = faces; self.size = size; self.mode = mode; self.second = second; self.flipped = flipped
    }

    /// Switches how the chamfer is measured. The second value starts afresh when what it measures changes
    /// (a length or an angle): the first distance again, or 45 degrees.
    public mutating func setMode(_ new: ChamferMode) {
        guard new != mode else { return }
        let changesKind = new.secondKind != mode.secondKind
        mode = new
        guard changesKind else { return }
        switch new {
        case .equalDistance: second = ""
        case .twoDistances: second = size
        case .distanceAngle: second = "45 deg"
        }
    }

    private enum CodingKeys: String, CodingKey { case edges, faces, size, mode, second, flipped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edges = try c.decode([EdgeRef].self, forKey: .edges)
        faces = try c.decodeIfPresent([FaceRef].self, forKey: .faces) ?? []  // older files: edges only
        size = try c.decode(String.self, forKey: .size)
        mode = try c.decodeIfPresent(ChamferMode.self, forKey: .mode) ?? .equalDistance
        second = try c.decodeIfPresent(String.self, forKey: .second) ?? ""
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(edges, forKey: .edges)
        if !faces.isEmpty { try c.encode(faces, forKey: .faces) }
        try c.encode(size, forKey: .size)
        if mode != .equalDistance { try c.encode(mode, forKey: .mode) }
        if !second.isEmpty { try c.encode(second, forKey: .second) }
        if flipped { try c.encode(flipped, forKey: .flipped) }
    }
}

/// A body read from a STEP or STL file. The file's contents are kept in the document, so the part
/// rebuilds without the original file. Its faces are named by their place in the file.
public struct ImportFeature: Codable, Hashable, Sendable {
    /// The name of the file it came from, for showing only.
    public var fileName: String
    /// The STEP or STL file's contents.
    public var data: Data
    public init(fileName: String, data: Data) { self.fileName = fileName; self.data = data }
}

/// A reference image (a canvas) lying on a plane or flat face, centred at (u, v) in the plane's frame.
/// It is for tracing and measuring against, and builds nothing. The image's file is kept in the
/// document, so the part opens without the original.
public struct ImageFeature: Codable, Hashable, Sendable {
    public var plane: PlaneRef
    /// The name of the file it came from, for showing only.
    public var fileName: String
    /// The image file's contents (PNG, JPEG, HEIC…).
    public var data: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var u: String
    public var v: String
    /// Width across the plane's x axis; the height follows the picture's proportions.
    public var width: String
    /// Turn about the centre, counter-clockwise as the plane is seen.
    public var angle: String
    /// 0 (see-through) to 1 (solid). Changing it rebuilds nothing (see `CADDocument.ignoringPresentation`).
    public var opacity: Double
    public init(plane: PlaneRef, fileName: String, data: Data, pixelWidth: Int, pixelHeight: Int, u: String = "0 mm",
                v: String = "0 mm", width: String = "100 mm", angle: String = "0 deg", opacity: Double = 0.5) {
        self.plane = plane; self.fileName = fileName; self.data = data
        self.pixelWidth = max(pixelWidth, 1); self.pixelHeight = max(pixelHeight, 1)
        self.u = u; self.v = v; self.width = width; self.angle = angle; self.opacity = min(max(opacity, 0), 1)
    }
    /// Height over width.
    public var aspect: Double { Double(pixelHeight) / Double(pixelWidth) }
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
        case thread(ThreadFeature)
        case primitive(PrimitiveFeature)
        case pipe(PipeFeature)
        case move(MoveFeature)
        case rotate(RotateFeature)
        case scale(ScaleFeature)
        case combine(CombineFeature)
        case split(SplitFeature)
        case layOnFloor(LayOnFloorFeature)
        case plane(PlaneFeature)
        case mirror(MirrorFeature)
        case pattern(PatternFeature)
        case shell(ShellFeature)
        case draft(DraftFeature)
        case project(ProjectFeature)
        case importBody(ImportFeature)
        case image(ImageFeature)
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
        case .thread: return "Thread"
        case .primitive(let p): return p.kind.rawValue
        case .pipe: return "Pipe"
        case .move: return "Move"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        case .combine: return "Combine"
        case .split: return "Split"
        case .layOnFloor: return "Lay on Floor"
        case .plane: return "Plane"
        case .mirror: return "Mirror"
        case .pattern(let p): return p.kind == .linear ? "Pattern" : "Circular Pattern"
        case .shell: return "Shell"
        case .draft: return "Draft"
        case .project: return "Project"
        case .importBody: return "Import"
        case .image: return "Canvas"
        }
    }

    /// Sketches this feature is built from (they are hidden once used, as in other CAD tools).
    public var sketchesUsed: [FeatureID] {
        switch kind {
        case .sketch, .fillet, .chamfer, .hole, .thread, .primitive, .move, .rotate, .scale, .combine, .plane, .mirror, .pattern,
             .shell, .draft, .importBody, .image, .layOnFloor: return []
        case .split(let f): if case .profile(let sketch) = f.tool { return [sketch] } else { return [] }
        case .project(let p): return [p.sketch]
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
        case .mirror(let m): return m.operation == .newBody
        case .pattern(let p): return p.operation == .newBody
        case .importBody: return true
        case .sketch, .fillet, .chamfer, .rib, .hole, .thread, .move, .rotate, .scale, .combine, .split, .layOnFloor, .plane, .shell, .draft, .project, .image: return false
        }
    }
}

/// A body's colour in the viewport: 8-bit sRGB, saved as "#RRGGBB" so files stay readable.
public struct BodyColor: Codable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }

    /// From components in 0...1 (clamped).
    public init(red: Double, green: Double, blue: Double) {
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(red: byte(red), green: byte(green), blue: byte(blue))
    }

    /// From "#RRGGBB" or "RRGGBB"; nil if it isn't one.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let v = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(v >> 16 & 0xFF), green: UInt8(v >> 8 & 0xFF), blue: UInt8(v & 0xFF))
    }

    public var hex: String {
        "#" + [red, green, blue].map { b in
            let s = String(b, radix: 16, uppercase: true)
            return s.count < 2 ? "0" + s : s
        }.joined()
    }

    /// Components in 0...1.
    public var components: (red: Double, green: Double, blue: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let c = BodyColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a #RRGGBB colour: \(text)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// What a body is made of in the Render view. Without one a body is plain, lit by its colour alone; the colour still
/// tints a material (the metal's colour, the glass's tint, the wood's base shade).
public enum BodyMaterial: String, Codable, CaseIterable, Hashable, Sendable {
    case metal, glass, wood
}

/// A folder in the browser. Folders hold bodies, sketches, planes and canvases, and other folders.
public struct BrowserFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The folder this one is in; nil at the top of the browser.
    public var parent: String?

    public init(id: String = UUID().uuidString, name: String, parent: String? = nil) {
        self.id = id; self.name = name; self.parent = parent
    }
}

extension CodingUserInfoKey {
    /// PNG bytes for `CADDocument` to store as its thumbnail when encoding.
    public static let cadThumbnail = CodingUserInfoKey(rawValue: "com.simplmaker.thumbnail")!
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
    /// Bodies and sketches locked against picking and editing, by the id of the feature that made them.
    public var locked: Set<FeatureID> = []
    /// Names given to bodies, by the id of the feature that made them (others are "Body1", "Body2"…).
    public var bodyNames: [FeatureID: String] = [:]
    /// Colours given to bodies, by the id of the feature that made them (others use the default).
    public var bodyColors: [FeatureID: BodyColor] = [:]
    /// Materials given to bodies, by the id of the feature that made them (others are plain).
    public var bodyMaterials: [FeatureID: BodyMaterial] = [:]
    /// Folders the user made in the browser, with their sub-folders (a folder lists its parent).
    public var folders: [BrowserFolder] = []
    /// The folder each body, sketch, plane or canvas sits in, by the id of the feature that made it. Anything
    /// not listed (or listed under a folder that no longer exists) stays in its usual group.
    public var folderOf: [FeatureID: String] = [:]

    public init(parameters: [Parameter] = [], features: [Feature] = []) {
        self.parameters = parameters; self.features = features
    }

    private enum CodingKeys: String, CodingKey { case version, parameters, features, rollback, hidden, locked, bodyNames, bodyColors, bodyMaterials, folders, folderOf, thumbnail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        parameters = try c.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
        features = try c.decodeIfPresent([Feature].self, forKey: .features) ?? []
        rollback = try c.decodeIfPresent(Int.self, forKey: .rollback)
        hidden = try c.decodeIfPresent(Set<FeatureID>.self, forKey: .hidden) ?? []  // older files have none
        locked = try c.decodeIfPresent(Set<FeatureID>.self, forKey: .locked) ?? []
        bodyNames = try c.decodeIfPresent([FeatureID: String].self, forKey: .bodyNames) ?? [:]
        bodyColors = try c.decodeIfPresent([FeatureID: BodyColor].self, forKey: .bodyColors) ?? [:]
        bodyMaterials = try c.decodeIfPresent([FeatureID: BodyMaterial].self, forKey: .bodyMaterials) ?? [:]
        folders = try c.decodeIfPresent([BrowserFolder].self, forKey: .folders) ?? []
        folderOf = try c.decodeIfPresent([FeatureID: String].self, forKey: .folderOf) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(features, forKey: .features)
        try c.encodeIfPresent(rollback, forKey: .rollback)
        if !hidden.isEmpty { try c.encode(hidden.sorted(), forKey: .hidden) }  // sorted: stable files
        if !locked.isEmpty { try c.encode(locked.sorted(), forKey: .locked) }
        if !bodyNames.isEmpty { try c.encode(bodyNames, forKey: .bodyNames) }  // sorted keys when encoded()
        if !bodyColors.isEmpty { try c.encode(bodyColors, forKey: .bodyColors) }
        if !bodyMaterials.isEmpty { try c.encode(bodyMaterials, forKey: .bodyMaterials) }
        if !folders.isEmpty { try c.encode(folders, forKey: .folders) }
        if !folderOf.isEmpty { try c.encode(folderOf, forKey: .folderOf) }
        // A picture of the part for Finder's Quick Look; given when saving, never part of the design itself.
        if let png = encoder.userInfo[.cadThumbnail] as? Data { try c.encode(png, forKey: .thumbnail) }
    }

    /// The same design with visibility, names, colours and materials ignored: changing those needs no rebuild.
    public var ignoringPresentation: CADDocument {
        var d = self
        d.hidden = []
        d.locked = []
        d.bodyNames = [:]
        d.bodyColors = [:]
        d.bodyMaterials = [:]
        d.folders = []
        d.folderOf = [:]
        for i in d.features.indices {
            d.features[i].name = ""
            if case .image(var f) = d.features[i].kind { f.opacity = 1; d.features[i].kind = .image(f) }
            if case .plane(var f) = d.features[i].kind { f.extent = nil; d.features[i].kind = .plane(f) }
        }
        return d
    }

    public var activeFeatures: ArraySlice<Feature> { features.prefix(rollback ?? features.count) }

    /// Adds a feature where the timeline marker is: before the features the marker has rolled back, and
    /// at the end (with the marker still there) when it hasn't.
    public mutating func insertAtMarker(_ feature: Feature) {
        if let r = rollback, r < features.count {
            features.insert(feature, at: r)
            rollback = r + 1
        } else {
            features.append(feature)
            rollback = nil  // a marker at the end is no marker; left set, it would hide the new feature
        }
    }

    /// Adds a new feature the way the tools do: where the timeline marker is, and hiding the sketches it is built
    /// from. The one place this rule lives, for the interface and for anything else that creates features.
    public mutating func addFeature(_ feature: Feature) {
        insertAtMarker(feature)
        hidden.formUnion(feature.sketchesUsed)
    }

    public func index(of id: FeatureID) -> Int? { features.firstIndex { $0.id == id } }

    /// Next free "<base><n>" name, e.g. "Fillet3".
    public func nextName(_ base: String) -> String {
        var n = 1
        while features.contains(where: { $0.name == "\(base)\(n)" }) { n += 1 }
        return "\(base)\(n)"
    }

    /// The file's bytes. `thumbnail` (PNG) is stored in the file for the Quick Look extensions; it is not part of the design.
    public func encoded(thumbnail: Data? = nil) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let thumbnail { enc.userInfo[.cadThumbnail] = thumbnail }
        return try enc.encode(self)
    }

    /// The picture stored in a file's bytes (PNG), if it has one. Reads nothing else, so it is cheap.
    public static func thumbnail(in data: Data) -> Data? {
        struct Picture: Decodable { var thumbnail: Data? }
        return (try? JSONDecoder().decode(Picture.self, from: data))?.thumbnail
    }

    public static func decode(_ data: Data) throws -> CADDocument {
        let doc = try JSONDecoder().decode(CADDocument.self, from: data)
        guard doc.version <= formatVersion else {
            throw ExpressionError("this file was made by a newer SimplMaker (format \(doc.version))")
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

// MARK: browser folders

extension CADDocument {
    /// The folders directly inside `parent` (nil: at the top), in the order they were made.
    public func subfolders(of parent: String?) -> [BrowserFolder] {
        folders.filter { $0.parent == parent }
    }

    public func folder(_ id: String) -> BrowserFolder? { folders.first { $0.id == id } }

    /// The folder an item sits in, if it has one that still exists.
    public func folder(of item: FeatureID) -> String? {
        guard let f = folderOf[item], folders.contains(where: { $0.id == f }) else { return nil }
        return f
    }

    /// The folder and every folder inside it, however deep.
    public func folderTree(_ id: String) -> Set<String> {
        var found: Set<String> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in folders where child.parent == next && found.insert(child.id).inserted { queue.append(child.id) }
        }
        return found
    }

    /// The items in the folder and in every folder inside it.
    public func items(inTree id: String) -> [FeatureID] {
        let tree = folderTree(id)
        return folderOf.filter { tree.contains($0.value) }.map(\.key).sorted()
    }

    /// How many folders deep this one is (0 at the top).
    public func depth(of id: String) -> Int {
        var n = 0, at = folder(id)?.parent
        while let p = at, n < folders.count { n += 1; at = folder(p)?.parent }
        return n
    }

    /// Next free "Folder", "Folder 2", ... name.
    public func nextFolderName() -> String {
        var n = 1
        func name(_ n: Int) -> String { n == 1 ? "Folder" : "Folder \(n)" }
        while folders.contains(where: { $0.name == name(n) }) { n += 1 }
        return name(n)
    }

    /// Makes a folder inside `parent` (nil: at the top) and returns its id.
    @discardableResult
    public mutating func addFolder(named name: String? = nil, in parent: String? = nil) -> String {
        let f = BrowserFolder(name: name ?? nextFolderName(), parent: parent.flatMap { folder($0) == nil ? nil : $0 })
        folders.append(f)
        return f.id
    }

    /// Puts items into a folder (nil: back in their usual group).
    public mutating func move(_ items: [FeatureID], toFolder id: String?) {
        for item in items {
            if let id, folder(id) != nil { folderOf[item] = id } else { folderOf[item] = nil }
        }
    }

    /// Puts a folder inside another (nil: at the top). Refused, with false, into itself or one of its own folders.
    @discardableResult
    public mutating func moveFolder(_ id: String, into parent: String?) -> Bool {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return false }
        if let parent, folder(parent) == nil || folderTree(id).contains(parent) { return false }
        folders[i].parent = parent
        return true
    }

    /// Removes a folder. What it held (items and folders) moves up into the folder it was in.
    public mutating func removeFolder(_ id: String) {
        guard let f = folder(id) else { return }
        for i in folders.indices where folders[i].parent == id { folders[i].parent = f.parent }
        for (item, home) in folderOf where home == id { folderOf[item] = f.parent }
        folders.removeAll { $0.id == id }
    }
}

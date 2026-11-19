// The Mold workspace's settings: a rigid, printable two-part mold for casting silicone or resin around a body. A mold is not
// a feature of the timeline. It is linked to a body, lives beside the features (`CADDocument.molds`) and follows the body when
// the part changes; the halves are worked out from it (MoldBuilder, in CADKernel) and are never stored.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An axis of the world, for the parting plane's normal.
public enum MoldAxis: String, Codable, CaseIterable, Sendable {
    case x, y, z

    public var vector: SIMD3<Double> {
        switch self {
        case .x: SIMD3(1, 0, 0)
        case .y: SIMD3(0, 1, 0)
        case .z: SIMD3(0, 0, 1)
        }
    }
    public var index: Int { self == .x ? 0 : self == .y ? 1 : 2 }
}

/// The way the mold is poured from ("up"): one of the six directions along an axis.
public enum MoldDirection: String, Codable, CaseIterable, Sendable {
    case plusX = "+x", minusX = "-x", plusY = "+y", minusY = "-y", plusZ = "+z", minusZ = "-z"

    public var vector: SIMD3<Double> {
        switch self {
        case .plusX: SIMD3(1, 0, 0)
        case .minusX: SIMD3(-1, 0, 0)
        case .plusY: SIMD3(0, 1, 0)
        case .minusY: SIMD3(0, -1, 0)
        case .plusZ: SIMD3(0, 0, 1)
        case .minusZ: SIMD3(0, 0, -1)
        }
    }
    public var axis: MoldAxis { self == .plusX || self == .minusX ? .x : self == .plusY || self == .minusY ? .y : .z }
}

/// A point in the world (mm), for a vent or a hand-placed gate.
public struct MoldPoint: Codable, Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public init(_ v: SIMD3<Double>) { x = v.x; y = v.y; z = v.z }
    public var vector: SIMD3<Double> { SIMD3(x, y, z) }
}

/// What is cast in the mold. Silicone is flexible: it is peeled out of mild undercuts, so they only warn. A rigid resin is not: an
/// undercut makes the mold impossible, and a face with no draft is warned about.
public enum MoldCasting: String, Codable, CaseIterable, Sendable {
    case silicone, resin
}

/// Where the mold splits into its two halves.
public enum MoldParting: Codable, Hashable, Sendable {
    /// The plane across an axis, through the middle of the body's bounding box.
    case middle(MoldAxis)
    /// An origin plane, a construction plane or a flat face. Planes that lean (not square to X, Y or Z) are not made yet.
    case plane(PlaneRef)
}

/// One mold: a body, the way it is parted and poured, and the sizes of what is added to it. Sizes are expressions like every
/// other size (so they can use parameters), in mm.
public struct MoldSetup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The body the mold is made around, by the id of the feature that made it.
    public var body: FeatureID
    public var parting: MoldParting
    /// Moves the parting plane along its normal (the middle plane, or the picked one).
    public var partingOffset: String
    /// The way the silicone is poured from. The gate goes in at the body's highest point along it.
    public var up: MoldDirection
    /// The thickness of the mold around the body.
    public var wall: String
    public var gateDiameter: String
    /// Where the gate goes in, when it is not at the highest point (only the position across `up` counts).
    public var gatePoint: MoldPoint?
    public var ventDiameter: String
    /// Air vents: each goes up along `up` from the point to the top of the mold.
    public var vents: [MoldPoint]
    /// Cone keys on the parting face that make the halves meet one way only.
    public var keys: Bool
    public var keyDiameter: String
    /// How much bigger the sockets are than the keys, all round.
    public var keyClearance: String
    /// What is cast: decides whether an undercut is a warning or a refusal.
    public var casting: MoldCasting
    /// How many pieces the mold is: 2 halves, or 4 (each half cut again across a second plane). Four pieces let go of more shapes, because
    /// each one is pulled out sideways as well as away, and each is smaller to print.
    public var pieces: Int
    /// The axis the second plane of a four-piece mold is square to (through the middle of the body); nil = chosen for the body: a plane
    /// that contains the pour direction, so the gate and the vents are cut lengthways.
    public var cross: MoldAxis?

    public init(id: String = UUID().uuidString, name: String, body: FeatureID, parting: MoldParting = .middle(.z),
                partingOffset: String = "0 mm", up: MoldDirection = .plusZ, wall: String = "10 mm", gateDiameter: String = "8 mm",
                gatePoint: MoldPoint? = nil, ventDiameter: String = "2 mm", vents: [MoldPoint] = [], keys: Bool = true,
                keyDiameter: String = "5 mm", keyClearance: String = "0.3 mm", casting: MoldCasting = .silicone,
                pieces: Int = 2, cross: MoldAxis? = nil) {
        self.id = id; self.name = name; self.body = body; self.parting = parting; self.partingOffset = partingOffset
        self.up = up; self.wall = wall; self.gateDiameter = gateDiameter; self.gatePoint = gatePoint
        self.ventDiameter = ventDiameter; self.vents = vents; self.keys = keys; self.keyDiameter = keyDiameter
        self.keyClearance = keyClearance; self.casting = casting
        self.pieces = pieces == 4 ? 4 : 2; self.cross = cross
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, body, parting, partingOffset, up, wall, gateDiameter, gatePoint, ventDiameter, vents, keys, keyDiameter, keyClearance, casting, pieces, cross
    }

    /// Every setting is optional in a file, so a later version can add one and an older file still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MoldSetup(name: "", body: "")
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mold"
        body = try c.decode(FeatureID.self, forKey: .body)
        parting = try c.decodeIfPresent(MoldParting.self, forKey: .parting) ?? d.parting
        partingOffset = try c.decodeIfPresent(String.self, forKey: .partingOffset) ?? d.partingOffset
        up = try c.decodeIfPresent(MoldDirection.self, forKey: .up) ?? d.up
        wall = try c.decodeIfPresent(String.self, forKey: .wall) ?? d.wall
        gateDiameter = try c.decodeIfPresent(String.self, forKey: .gateDiameter) ?? d.gateDiameter
        gatePoint = try c.decodeIfPresent(MoldPoint.self, forKey: .gatePoint)
        ventDiameter = try c.decodeIfPresent(String.self, forKey: .ventDiameter) ?? d.ventDiameter
        vents = try c.decodeIfPresent([MoldPoint].self, forKey: .vents) ?? []
        keys = try c.decodeIfPresent(Bool.self, forKey: .keys) ?? true
        keyDiameter = try c.decodeIfPresent(String.self, forKey: .keyDiameter) ?? d.keyDiameter
        keyClearance = try c.decodeIfPresent(String.self, forKey: .keyClearance) ?? d.keyClearance
        casting = try c.decodeIfPresent(MoldCasting.self, forKey: .casting) ?? d.casting
        pieces = (try c.decodeIfPresent(Int.self, forKey: .pieces)) == 4 ? 4 : 2
        cross = try c.decodeIfPresent(MoldAxis.self, forKey: .cross)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(body, forKey: .body)
        try c.encode(parting, forKey: .parting)
        try c.encode(partingOffset, forKey: .partingOffset)
        try c.encode(up, forKey: .up)
        try c.encode(wall, forKey: .wall)
        try c.encode(gateDiameter, forKey: .gateDiameter)
        try c.encodeIfPresent(gatePoint, forKey: .gatePoint)
        try c.encode(ventDiameter, forKey: .ventDiameter)
        if !vents.isEmpty { try c.encode(vents, forKey: .vents) }
        try c.encode(keys, forKey: .keys)
        try c.encode(keyDiameter, forKey: .keyDiameter)
        try c.encode(keyClearance, forKey: .keyClearance)
        if casting != .silicone { try c.encode(casting, forKey: .casting) }
        if pieces == 4 { try c.encode(pieces, forKey: .pieces) }
        try c.encodeIfPresent(cross, forKey: .cross)
    }

    /// The ids the two halves have as bodies (the way a split names its pieces): behind the parting plane and in front of it.
    public var halfIDs: (behind: FeatureID, front: FeatureID) { ("mold~\(id)~behind", "mold~\(id)~front") }

    /// The ids of every piece, in the order they are built: the two halves, or (in a four-piece mold) each half's two pieces, the one
    /// behind the second plane first ("~a") and the one in front of it second ("~b").
    public var pieceIDs: [FeatureID] {
        let h = halfIDs
        return pieces == 4 ? [h.behind + "~a", h.behind + "~b", h.front + "~a", h.front + "~b"] : [h.behind, h.front]
    }

    /// Whether `bodyID` is one of the pieces of a mold (they all have ids that start "mold~" and name a side).
    public static func isPiece(_ bodyID: FeatureID) -> Bool { bodyID.hasPrefix("mold~") && (bodyID.contains("~behind") || bodyID.contains("~front")) }
}

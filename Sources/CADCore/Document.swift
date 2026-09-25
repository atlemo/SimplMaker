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

    public init(sketch: FeatureID, profiles: [ProfileRef], extent: ExtrudeExtent, flipped: Bool = false,
                operation: BodyOperation = .newBody, target: FeatureID? = nil) {
        self.sketch = sketch; self.profiles = profiles; self.extent = extent
        self.flipped = flipped; self.operation = operation; self.target = target
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

    public init(parameters: [Parameter] = [], features: [Feature] = []) {
        self.parameters = parameters; self.features = features
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

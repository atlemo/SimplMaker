// Looking at the built geometry: a body's faces and edges, and measurements of them. Read-only, like the rest of the queries;
// the numbers come from the kernel's own measurements (KBody.measure, KBody.distance), the same ones the Measure tool shows.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import simd

struct FaceInfo: Encodable, Equatable {
    /// "face:<body>/<name>": use it wherever a face is asked for.
    var id: String
    /// "plane", "cylinder", "cone", "sphere", "torus" or "other".
    var shape: String
    var area: Double
    /// For a flat face the side it looks to when it is square to an axis: "+z" is a top face, "-z" a bottom face; nil otherwise.
    var facing: String?
    /// A flat face's normal out of the material, or a round face's axis.
    var direction: [Double]?
    /// The centre of mass of the face.
    var center: [Double]
    var radius: Double?
    var boundsMin: [Double]
    var boundsMax: [Double]
}

struct EdgeInfo: Encodable, Equatable {
    /// "edge:<body>/<name>".
    var id: String
    /// "line", "circle", "arc" or "other".
    var shape: String
    var length: Double
    var start: [Double]?
    var end: [Double]?
    var center: [Double]?
    var radius: Double?
    /// The faces on either side of it.
    var faces: [String]
}

struct BodyDescription: Encodable, Equatable {
    var documentId: String
    var revision: Int
    var body: BodyInfo
    var faces: [FaceInfo]
    var edges: [EdgeInfo]
    /// True when there were more faces or edges than are listed.
    var truncated: Bool
}

struct MeasureDetail: Encodable, Equatable {
    var id: String
    /// "body", "plane", "cylinder", "cone", "sphere", "torus", "line", "circle", "arc" or "other".
    var kind: String
    /// A body's or face's area, an edge's length.
    var area: Double?
    var length: Double?
    var volume: Double?
    var perimeter: Double?
    var radius: Double?
    var diameter: Double?
    var center: [Double]?
    var direction: [Double]?
    var start: [Double]?
    var end: [Double]?
    var boundsMin: [Double]
    var boundsMax: [Double]
    /// Size along x, y and z.
    var extent: [Double]
}

struct MeasureResult: Encodable, Equatable {
    var documentId: String
    var revision: Int
    var a: MeasureDetail
    var b: MeasureDetail?
    /// The shortest distance between the two.
    var distance: Double?
    var closestPointA: [Double]?
    var closestPointB: [Double]?
    /// Between the two directions (normals, axes, edges), ignoring which way each points: 0 to 90.
    var angleDegrees: Double?
    /// Between two flat faces' outward normals: 0 (same way) to 180 (opposite).
    var normalsAngleDegrees: Double?
}

extension CADService {
    private static func vec(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z].map { ($0 * 1e6).rounded() / 1e6 } }

    private static func shape(_ g: KGeometry) -> String {
        switch g {
        case .body: return "body"
        case .plane: return "plane"
        case .cylinder: return "cylinder"
        case .cone: return "cone"
        case .sphere: return "sphere"
        case .torus: return "torus"
        case .line: return "line"
        case .circle: return "circle"
        case .arc: return "arc"
        case .other: return "other"
        }
    }

    /// "+z" when `normal` is within 5° of an axis.
    static func facing(_ normal: SIMD3<Double>) -> String? {
        let n = simd_normalize(normal)
        let axes: [(String, SIMD3<Double>)] = [("+x", SIMD3(1, 0, 0)), ("-x", SIMD3(-1, 0, 0)), ("+y", SIMD3(0, 1, 0)),
                                               ("-y", SIMD3(0, -1, 0)), ("+z", SIMD3(0, 0, 1)), ("-z", SIMD3(0, 0, -1))]
        return axes.first { simd_dot(n, $0.1) > cos(5 * .pi / 180) }?.0
    }

    // MARK: get_body

    func getBody(documentID: String?, bodyID: String) async throws -> BodyDescription {
        try checkLicense()
        let (docID, model) = try resolve(documentID)
        await model.rebuilt()
        guard let built = model.result?.bodies.first(where: { $0.id == bodyID }) else {
            let known = (model.result?.bodies ?? []).map(\.id).joined(separator: ", ")
            throw AIError(.featureNotFound, "There is no body with the id \(bodyID).",
                          reason: known.isEmpty ? "The part has no bodies yet." : "The bodies are: \(known). get_document lists them.")
        }
        let body = built.body
        let faceLimit = 300, edgeLimit = 600
        var faces: [FaceInfo] = []
        for name in body.faceNames.prefix(faceLimit) {
            guard let m = try? body.measure(.face(name)) else { continue }
            let direction = m.direction
            faces.append(FaceInfo(
                id: AIEntityRef.face(FaceRef(body: bodyID, face: name)).string, shape: Self.shape(m.geometry), area: m.size,
                facing: m.geometry == .plane ? direction.flatMap(Self.facing) : nil, direction: direction.map(Self.vec),
                center: Self.vec(m.centroid), radius: [.cylinder, .cone, .sphere, .torus].contains(m.geometry) ? m.radius : nil,
                boundsMin: Self.vec(m.bounds.min), boundsMax: Self.vec(m.bounds.max)))
        }
        var edges: [EdgeInfo] = []
        for name in body.edgeNames.prefix(edgeLimit) {
            guard let m = try? body.measure(.edge(name)) else { continue }
            let adjacent = ((try? body.edgeFaces(name)) ?? []).map { AIEntityRef.face(FaceRef(body: bodyID, face: $0)).string }
            edges.append(EdgeInfo(id: AIEntityRef.edge(EdgeRef(body: bodyID, edge: name)).string, shape: Self.shape(m.geometry), length: m.size,
                                  start: m.ends.map { Self.vec($0.start) }, end: m.ends.map { Self.vec($0.end) },
                                  center: m.geometry == .circle || m.geometry == .arc ? m.center.map(Self.vec) : nil,
                                  radius: m.geometry == .circle || m.geometry == .arc ? m.radius : nil, faces: adjacent))
        }
        guard let info = bodies(of: model).first(where: { $0.id == bodyID }) else {
            throw AIError(.featureNotFound, "There is no body with the id \(bodyID).")
        }
        return BodyDescription(documentId: docID, revision: model.documentRevision, body: info, faces: faces, edges: edges,
                               truncated: body.faceNames.count > faceLimit || body.edgeNames.count > edgeLimit)
    }

    // MARK: measure

    private func piece(_ text: String, in model: DocumentModel) throws -> (id: String, body: KBody, piece: KPiece) {
        let invalid = AIError(.invalidArguments, "\"\(text)\" is not something that can be measured.",
                              reason: "Use a body id, a face as \"face:<body>/<name>\" or an edge as \"edge:<body>/<name>\" (get_body lists them).")
        func body(_ id: String) throws -> KBody {
            guard let b = model.result?.body(id) else {
                throw AIError(.featureNotFound, "There is no body with the id \(id).", reason: "Call get_document for the bodies the part has.")
            }
            return b
        }
        switch AIEntityRef(text) {
        case .face(let f)?:
            let b = try body(f.body)
            guard b.hasFace(f.face) else { throw AIError(.featureNotFound, "\"\(text)\" is not a face of \(f.body).", reason: "Face names change when the part is edited; read them again with get_body.") }
            return (text, b, .face(f.face))
        case .edge(let e)?:
            let b = try body(e.body)
            guard b.hasEdge(e.edge) else { throw AIError(.featureNotFound, "\"\(text)\" is not an edge of \(e.body).", reason: "Edge names change when the part is edited; read them again with get_body.") }
            return (text, b, .edge(e.edge))
        case nil where !text.contains(":"):
            return (text, try body(text), .body)
        default:
            throw invalid
        }
    }

    private func detail(_ id: String, _ m: KMeasure) -> MeasureDetail {
        let isBody = m.geometry == .body
        let isEdge = [.line, .circle, .arc].contains(m.geometry)
        let round = [.cylinder, .cone, .sphere, .torus, .circle, .arc].contains(m.geometry)
        return MeasureDetail(
            id: id, kind: Self.shape(m.geometry), area: isEdge ? nil : m.size, length: isEdge ? m.size : nil, volume: isBody ? m.volume : nil,
            perimeter: !isBody && !isEdge ? m.perimeter : nil, radius: round ? m.radius : nil, diameter: round ? m.radius * 2 : nil,
            center: m.center.map(Self.vec) ?? (isBody ? Self.vec(m.centroid) : nil), direction: m.direction.map(Self.vec),
            start: m.ends.map { Self.vec($0.start) }, end: m.ends.map { Self.vec($0.end) },
            boundsMin: Self.vec(m.bounds.min), boundsMax: Self.vec(m.bounds.max), extent: Self.vec(m.extent))
    }

    func measure(documentID: String?, a: String, b: String?) async throws -> MeasureResult {
        try checkLicense()
        let (docID, model) = try resolve(documentID)
        await model.rebuilt()
        let first = try piece(a, in: model)
        let ma: KMeasure
        do { ma = try first.body.measure(first.piece) } catch {
            throw AIError(.invalidValue, "\"\(a)\" could not be measured: \(error).", reason: "Try another face or edge.")
        }
        var result = MeasureResult(documentId: docID, revision: model.documentRevision, a: detail(a, ma))
        guard let b else { return result }
        let second = try piece(b, in: model)
        let mb: KMeasure
        do { mb = try second.body.measure(second.piece) } catch {
            throw AIError(.invalidValue, "\"\(b)\" could not be measured: \(error).", reason: "Try another face or edge.")
        }
        result.b = detail(b, mb)
        if let d = try? first.body.distance(first.piece, to: second.body, second.piece) {
            result.distance = d.distance
            result.closestPointA = Self.vec(d.a); result.closestPointB = Self.vec(d.b)
        }
        if let da = ma.direction, let db = mb.direction, simd_length(da) > 1e-9, simd_length(db) > 1e-9 {
            let cosine = min(max(simd_dot(simd_normalize(da), simd_normalize(db)), -1), 1)
            let degrees = acos(cosine) * 180 / .pi
            result.angleDegrees = (min(degrees, 180 - degrees) * 1e4).rounded() / 1e4
            if ma.geometry == .plane, mb.geometry == .plane { result.normalsAngleDegrees = (degrees * 1e4).rounded() / 1e4 }
        }
        return result
    }
}

struct ViewportImageResult {
    var documentID: String
    var revision: Int
    var direction: SnapshotDirection
    var image: SnapshotImage
    var bodies: [String]
}

extension CADService {
    /// A picture of the part, from a direction (or an angle of your own).
    func viewportImage(documentID: String?, direction: SnapshotDirection, azimuth: Double?, elevation: Double?, width: Int, height: Int,
                       axes: Bool) async throws -> ViewportImageResult {
        try checkLicense()
        guard (256...1600).contains(width), (192...1200).contains(height) else {
            throw AIError(.invalidArguments, "The picture size must be 256–1600 wide and 192–1200 high (asked for \(width) × \(height)).",
                          reason: "The default of 1024 × 768 is good for most views.")
        }
        let (id, model) = try resolve(documentID)
        await model.rebuilt()
        let image = try await ViewportSnapshot.render(model, direction: direction, azimuth: azimuth, elevation: elevation, width: width, height: height, axes: axes)
        return ViewportImageResult(documentID: id, revision: model.documentRevision, direction: direction, image: image,
                                   bodies: model.visibleMeshes.map(\.id))
    }
}

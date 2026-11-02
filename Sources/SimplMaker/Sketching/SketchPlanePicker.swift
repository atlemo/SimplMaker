// Choosing where a new sketch goes: the three origin planes shown in the viewport, or a flat face.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import simd

/// One of the origin planes offered when a sketch is created.
enum OriginPlane: Int, CaseIterable, Sendable {
    case xy, xz, yz

    var frame: Frame {
        switch self {
        case .xy: return .xy
        case .xz: return .xz
        case .yz: return .yz
        }
    }

    var planeRef: PlaneRef {
        switch self {
        case .xy: return .xy
        case .xz: return .xz
        case .yz: return .yz
        }
    }

    var label: String {
        switch self {
        case .xy: return "XY"
        case .xz: return "XZ"
        case .yz: return "YZ"
        }
    }

    var pickID: PickID { PickID(plane: rawValue) }

    /// Identifier of the plane's viewport label.
    var labelID: EntityID { "plane:\(label)" }

    init?(pick: PickID) {
        guard pick.kind == .plane else { return nil }
        self.init(rawValue: pick.element)
    }

    init?(labelID: EntityID) {
        guard let plane = OriginPlane.allCases.first(where: { $0.labelID == labelID }) else { return nil }
        self = plane
    }

    /// Size of the plane squares so they sit comfortably around the model (25 mm for an empty scene).
    static func displaySize(for bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?) -> Double {
        guard let b = bounds else { return 25 }
        let extent = max(simd_reduce_max(simd_abs(b.min)), simd_reduce_max(simd_abs(b.max)))
        return max(25, Double(extent) * 0.6)
    }
}

extension SketchOverlayBuilder {
    /// The origin planes as translucent, pickable squares in the positive quadrant of each plane.
    static func originPlanes(size s: Double, into o: inout SketchOverlay) {
        o.originPlaneCount = OriginPlane.allCases.count
        for plane in OriginPlane.allCases {
            let f = plane.frame, id = plane.pickID.raw
            let n = SIMD3<Float>(Float(f.normal.x), Float(f.normal.y), Float(f.normal.z))
            let corners = [SIMD2(0, 0), SIMD2(s, 0), SIMD2(s, s), SIMD2(0, s)].map { world(f, $0) }
            let base = UInt32(o.planeVertices.count)
            for c in corners {
                o.planeVertices.append(FaceVertex(px: c.x, py: c.y, pz: c.z, nx: n.x, ny: n.y, nz: n.z, id: id))
            }
            o.planeIndices += [0, 1, 2, 0, 2, 3].map { base + $0 }
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                o.planeOutline.append(SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: id))
            }
        }
    }

    /// A construction plane: a translucent, pickable rectangle over `extent` in its own frame. Its sides
    /// also go in as separate pickable segments (`edgeIDs`, bottom, right, top, left) to drag them.
    static func constructionPlane(_ f: Frame, extent e: PlaneExtent, id: UInt32, edgeIDs: [UInt32]?, into o: inout SketchOverlay) {
        let n = SIMD3<Float>(Float(f.normal.x), Float(f.normal.y), Float(f.normal.z))
        let corners = [SIMD2(e.uMin, e.vMin), SIMD2(e.uMax, e.vMin), SIMD2(e.uMax, e.vMax), SIMD2(e.uMin, e.vMax)].map { world(f, $0) }
        let base = UInt32(o.planeVertices.count)
        for c in corners { o.planeVertices.append(FaceVertex(px: c.x, py: c.y, pz: c.z, nx: n.x, ny: n.y, nz: n.z, id: id)) }
        o.planeIndices += [0, 1, 2, 0, 2, 3].map { base + $0 }
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            o.planeOutline.append(SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: id))
            if let edgeIDs {
                o.planeEdges.append(SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: edgeIDs[i]))
            }
        }
    }

    /// "XY", "XZ" and "YZ" labels at the centre of each plane square.
    static func originPlaneLabels(size s: Double) -> [DimensionLabel] {
        OriginPlane.allCases.map { plane in
            DimensionLabel(id: plane.labelID, world: world(plane.frame, SIMD2(s / 2, s / 2)), text: plane.label, editing: false)
        }
    }
}

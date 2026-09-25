// Turns sketches (2D, in a plane frame) into GPU segments/triangles for the viewport.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd

/// A dimension's value label, anchored in world space.
struct DimensionLabel: Identifiable, Equatable {
    var id: EntityID
    var world: SIMD3<Float>
    var text: String
    var editing: Bool
}

@MainActor
enum SketchOverlayBuilder {
    static func world(_ frame: Frame, _ p: SIMD2<Double>) -> SIMD3<Float> {
        let w = frame.point(p.x, p.y)
        return SIMD3(Float(w.x), Float(w.y), Float(w.z))
    }

    /// Points along a sketch curve (in sketch coordinates).
    static func polyline(_ c: SketchCurve, in s: Sketch) -> [SIMD2<Double>] {
        func arc(_ center: SIMD2<Double>, _ r: Double, _ a0: Double, _ a1: Double) -> [SIMD2<Double>] {
            let n = max(6, Int(abs(a1 - a0) / (2 * .pi) * 96))
            return (0...n).map { i in
                let t = a0 + (a1 - a0) * Double(i) / Double(n)
                return center + r * SIMD2(cos(t), sin(t))
            }
        }
        switch c.geometry {
        case .line(let a, let b):
            guard let pa = s.position(a), let pb = s.position(b) else { return [] }
            return [pa, pb]
        case .circle(let center, let r):
            guard let pc = s.position(center) else { return [] }
            return arc(pc, r, 0, 2 * .pi)
        case .arc(let center, let start, let end):
            guard let pc = s.position(center), let ps = s.position(start), let pe = s.position(end) else { return [] }
            let a0 = atan2(ps.y - pc.y, ps.x - pc.x)
            var a1 = atan2(pe.y - pc.y, pe.x - pc.x)
            while a1 <= a0 { a1 += 2 * .pi }
            return arc(pc, simdLength(ps - pc), a0, a1)
        }
    }

    static func segments(_ line: [SIMD2<Double>], frame: Frame, id: UInt32) -> [SegmentInstance] {
        guard line.count > 1 else { return [] }
        return (0..<(line.count - 1)).map { i in
            let a = world(frame, line[i]), b = world(frame, line[i + 1])
            return SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: id)
        }
    }

    /// The sketch being edited: pickable curves and points, plus the tool preview.
    static func editing(_ session: SketchSession, into o: inout SketchOverlay) {
        let s = session.sketch, f = session.frame
        for (i, c) in s.curves.enumerated() {
            let segs = segments(polyline(c, in: s), frame: f, id: PickID(sketchCurve: i).raw)
            if c.construction { o.construction += segs } else { o.curves += segs }
        }
        for (i, p) in s.points.enumerated() {
            let w = world(f, p.position)
            o.points.append(SegmentInstance(ax: w.x, ay: w.y, az: w.z, bx: w.x, by: w.y, bz: w.z,
                                            id: PickID(sketchPoint: i).raw))
        }
        for line in session.previewPolylines() { o.preview += segments(line, frame: f, id: 0) }
        o.fullyConstrained = session.solve?.status == .solved && session.solve?.degreesOfFreedom == 0
    }

    /// A finished sketch shown for reference (not pickable).
    static func inactive(_ s: Sketch, frame: Frame, into o: inout SketchOverlay) {
        for c in s.curves where !c.construction { o.inactive += segments(polyline(c, in: s), frame: frame, id: 0) }
    }

    /// Profile regions of a sketch, pickable for extrude.
    static func regions(_ r: SketchResult, into o: inout SketchOverlay) {
        let n = r.frame.normal
        for (i, mesh) in r.regionMeshes.enumerated() {
            let base = UInt32(o.regionVertices.count)
            let id = PickID(region: i).raw
            for v in stride(from: 0, to: mesh.positions.count, by: 3) {
                o.regionVertices.append(FaceVertex(px: mesh.positions[v], py: mesh.positions[v + 1], pz: mesh.positions[v + 2],
                                                   nx: Float(n.x), ny: Float(n.y), nz: Float(n.z), id: id))
            }
            o.regionIndices += mesh.indices.map { $0 + base }
        }
    }

    /// Value labels for the dimensions of the sketch being edited.
    static func labels(_ session: SketchSession) -> [DimensionLabel] {
        let s = session.sketch
        return s.dimensions.compactMap { d in
            guard let anchor = anchor(d.kind, s) else { return nil }
            let value = session.values[d.id].map { d.unitKind.format($0) } ?? "?"
            let isParametric = ((try? Expressions.parse(d.expression))?.references.isEmpty == false)
            return DimensionLabel(id: d.id, world: world(session.frame, anchor),
                                  text: isParametric ? "\(d.expression) = \(value)" : value,
                                  editing: session.editingDimension == d.id)
        }
    }

    static func anchor(_ k: SketchDimension.Kind, _ s: Sketch) -> SIMD2<Double>? {
        func mid(_ a: SIMD2<Double>?, _ b: SIMD2<Double>?) -> SIMD2<Double>? {
            guard let a, let b else { return nil }
            return (a + b) / 2
        }
        func lineMid(_ l: EntityID) -> SIMD2<Double>? { s.lineEnds(l).map { ($0.0 + $0.1) / 2 } }
        switch k {
        case .distance(let a, let b), .horizontalDistance(let a, let b), .verticalDistance(let a, let b):
            return mid(s.position(a), s.position(b))
        case .pointLineDistance(let p, let l): return mid(s.position(p), lineMid(l))
        case .length(let l): return lineMid(l)
        case .radius(let c), .diameter(let c):
            guard let curve = s.curve(c), let center = s.center(of: c).flatMap({ s.position($0) }),
                  let r = s.radius(of: curve) else { return nil }
            return center + r * SIMD2(0.7071, 0.7071)
        case .angle(let a, let b): return mid(lineMid(a), lineMid(b))
        }
    }
}

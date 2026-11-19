// What a mold needs to know about the body, read from its mesh: which faces the halves can let go of when they are pulled apart (the
// pull direction is the parting plane's normal: the half in front goes forwards, the half behind goes backwards), and where air would be
// trapped while pouring (the peaks of the body along "up"). Both are pure functions of a mesh, so they are cheap to test and to run
// again after every change of the part.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd

/// Whether the body's faces can be released from the two halves.
public struct MoldAnalysis: Sendable, Equatable {
    public enum Release: String, Sendable { case free, noDraft, undercut }

    /// Each face of the body (by its persistent name) and how it releases. A face is judged by its share: an undercut part of a face
    /// makes it an undercut only when it is more than a sliver, so a curved face that merely meets the parting plane is not.
    public var faces: [String: Release] = [:]
    public var totalArea = 0.0
    /// The area (mm²) that can not be released (it faces back against the pull), and the area that has no draft (parallel to it).
    public var undercutArea = 0.0
    public var noDraftArea = 0.0
    public var undercutFaces: [String] = []
    public var noDraftFaces: [String] = []

    public init() {}

    public var undercutShare: Double { totalArea > 0 ? undercutArea / totalArea : 0 }
    public var noDraftShare: Double { totalArea > 0 ? noDraftArea / totalArea : 0 }
    /// More than a speck of the surface can not be released.
    public var hasUndercuts: Bool { undercutArea > 1 && undercutShare > 0.005 }

    /// A face has a draft when its normal leans this far (degrees) towards the way the half is pulled.
    public static let draftDegrees = 1.0
    /// A face leaning this far (degrees) the wrong way is an undercut; less is the mesh's own roughness.
    public static let undercutDegrees = 1.0

    /// The axis to part a body across, through the middle of its box: the one that leaves the least undercut, and among those that are about
    /// as good (within half a per cent of the surface) the one with the shortest extent, so the halves meet over the body's biggest outline.
    public static func bestAxis(_ mesh: Mesh, bounds: (min: SIMD3<Double>, max: SIMD3<Double>)) -> MoldAxis {
        let centre = (bounds.min + bounds.max) / 2, ext = bounds.max - bounds.min
        let scored = MoldAxis.allCases.map { axis in (axis, analyse(mesh, partingPoint: centre, normal: axis.vector)) }
        let total = scored.map(\.1.totalArea).max() ?? 0
        let least = scored.map(\.1.undercutArea).min() ?? 0
        let good = scored.filter { $0.1.undercutArea <= least + 0.005 * total }
        return good.min { ext[$0.0.index] < ext[$1.0.index] }?.0 ?? .z
    }

    /// Reads a body's mesh against a parting plane (a point on it and its normal, along which the half in front is pulled).
    public static func analyse(_ mesh: Mesh, partingPoint: SIMD3<Double>, normal: SIMD3<Double>) -> MoldAnalysis {
        var out = MoldAnalysis()
        let drafted = sin(draftDegrees * .pi / 180), wrong = -sin(undercutDegrees * .pi / 180)
        let n = simd_normalize(normal)
        let p = mesh.positions, v = mesh.normals
        var area = [Double](repeating: 0, count: mesh.faceNames.count)
        var under = area, flat = area
        let hasNormals = v.count == p.count
        func point(_ i: Int) -> SIMD3<Double> { SIMD3(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2])) }
        func vertexNormal(_ i: Int) -> SIMD3<Double> { SIMD3(Double(v[i * 3]), Double(v[i * 3 + 1]), Double(v[i * 3 + 2])) }
        for t in 0..<(mesh.indices.count / 3) {
            let i = Int(mesh.indices[t * 3]), j = Int(mesh.indices[t * 3 + 1]), k = Int(mesh.indices[t * 3 + 2])
            let a = point(i), b = point(j), c = point(k)
            let cross = simd_cross(b - a, c - a)
            let twice = simd_length(cross)
            guard twice > 1e-12 else { continue }
            // The surface's own normal where the mesh has them (exact on a curved face), else the triangle's, turned outwards.
            var normalHere = cross / twice
            if hasNormals {
                let average = vertexNormal(i) + vertexNormal(j) + vertexNormal(k)
                if simd_length(average) > 1e-9 { normalHere = simd_normalize(average) }
            }
            let centroid = (a + b + c) / 3
            let release = simd_dot(centroid - partingPoint, n) >= 0 ? n : -n  // the half this bit of surface sits in is pulled this way
            let lean = simd_dot(normalHere, release)
            let f = Int(mesh.triangleFace[t])
            guard f < area.count else { continue }
            let a2 = twice / 2
            area[f] += a2
            if lean < wrong { under[f] += a2 } else if lean < drafted { flat[f] += a2 }
        }
        for (f, name) in mesh.faceNames.enumerated() where area[f] > 0 {
            out.totalArea += area[f]
            out.undercutArea += under[f]
            out.noDraftArea += flat[f]
            if under[f] > max(0.01 * area[f], 0.3) {
                out.faces[name] = .undercut; out.undercutFaces.append(name)
            } else if flat[f] > 0.25 * area[f] {
                out.faces[name] = .noDraft; out.noDraftFaces.append(name)
            } else {
                out.faces[name] = .free
            }
        }
        return out
    }
}

/// Where air gets trapped while the mold is filled: the peaks of the body along "up" (the top of every lobe that rises out of a lower
/// surface). The gate goes in at the highest one; each of the others wants a vent.
public enum MoldVents {
    /// The peaks of `mesh` along `up`, most prominent first, without the one at `gate` (and the ones that lie across `gateRadius + 2` mm of it).
    /// A peak counts when it stands at least `prominence` mm above the lowest saddle that joins it to a higher one (a body's own
    /// tessellation roughness never does), and peaks closer than 5 mm to a higher one are one.
    public static func suggest(_ mesh: Mesh, up: SIMD3<Double>, gate: SIMD3<Double>, gateRadius: Double, maxCount: Int = 4,
                               prominence: Double? = nil) -> [SIMD3<Double>] {
        let u = simd_normalize(up)
        let count = mesh.positions.count / 3
        guard count > 3, !mesh.indices.isEmpty else { return [] }
        func point(_ i: Int) -> SIMD3<Double> { SIMD3(Double(mesh.positions[i * 3]), Double(mesh.positions[i * 3 + 1]), Double(mesh.positions[i * 3 + 2])) }

        // Weld the vertices that lie in the same place (every face has its own), so the surface is one graph.
        var weldedIndex: [SIMD3<Int32>: Int] = [:]
        var welded = [Int](repeating: 0, count: count)
        var positions: [SIMD3<Double>] = []
        for i in 0..<count {
            let q = point(i)
            let key = SIMD3<Int32>(Int32((q.x * 1000).rounded()), Int32((q.y * 1000).rounded()), Int32((q.z * 1000).rounded()))
            if let id = weldedIndex[key] { welded[i] = id } else {
                welded[i] = positions.count; weldedIndex[key] = positions.count; positions.append(q)
            }
        }
        let n = positions.count
        var neighbours = [[Int]](repeating: [], count: n)
        for t in 0..<(mesh.indices.count / 3) {
            let a = welded[Int(mesh.indices[t * 3])], b = welded[Int(mesh.indices[t * 3 + 1])], c = welded[Int(mesh.indices[t * 3 + 2])]
            for (x, y) in [(a, b), (b, c), (c, a)] where x != y { neighbours[x].append(y); neighbours[y].append(x) }
        }
        let height = positions.map { simd_dot($0, u) }
        let range = (height.max() ?? 0) - (height.min() ?? 0)
        let needed = prominence ?? max(1.0, 0.03 * range)

        // Peaks and their prominence: walk down from the top, merging the regions that meet; when two meet, the lower peak has been
        // as prominent as the drop from it to where they met.
        let order = (0..<n).sorted { height[$0] > height[$1] }
        var parent = Array(0..<n)
        let peak = Array(0..<n)  // the highest vertex of a region, kept at its root
        var seen = [Bool](repeating: false, count: n)
        var found: [(vertex: Int, prominence: Double)] = []
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for v in order {
            seen[v] = true
            for w in neighbours[v] where seen[w] {
                let a = root(v), b = root(w)
                guard a != b else { continue }
                let (high, low) = height[peak[a]] >= height[peak[b]] ? (a, b) : (b, a)
                found.append((peak[low], height[peak[low]] - height[v]))
                parent[low] = high
            }
        }
        let top = order.first.map { peak[root($0)] } ?? 0
        // The highest peak is a vent too when the gate was put well below it (somewhere else); a gate on a flat top is on the highest.
        if height[top] - simd_dot(gate, u) > max(0.5, needed * 0.5) { found.append((top, .infinity)) }
        var chosen: [SIMD3<Double>] = []
        func across(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { simd_length((a - b) - simd_dot(a - b, u) * u) }
        for candidate in found.sorted(by: { $0.prominence > $1.prominence }) where candidate.prominence >= needed {
            // A flat top is one peak whose "highest vertex" is any corner of it: the vent goes in the middle of the flat.
            var at = positions[candidate.vertex]
            let level = height[candidate.vertex] - 0.05
            var sum = SIMD3<Double>.zero, flat = 0.0
            for (i, q) in positions.enumerated() where height[i] >= level && simd_length(q - at) < 12 { sum += q; flat += 1 }
            if flat > 1 { at = sum / flat }
            if across(at, gate) < gateRadius + 2 { continue }
            if chosen.contains(where: { simd_length($0 - at) < 5 }) { continue }
            chosen.append(at)
            if chosen.count == maxCount { break }
        }
        return chosen
    }
}

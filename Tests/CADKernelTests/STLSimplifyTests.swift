// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADKernel

/// Reducing a mesh with too many triangles, and the limit on what an STL import takes.
@Suite struct STLSimplifyTests {
    private static func binarySTL(_ triangles: [[SIMD3<Float>]]) -> Data {
        var d = Data(count: 80)
        var n = UInt32(triangles.count)
        d.append(Data(bytes: &n, count: 4))
        for t in triangles {
            var f: [Float] = [0, 0, 0] + t.flatMap { [$0.x, $0.y, $0.z] }
            f.withUnsafeBytes { d.append(contentsOf: $0) }
            d.append(Data([0, 0]))
        }
        return d
    }

    /// A UV sphere of the given radius with `rings` × `segments` quads (two triangles each, fewer at the poles).
    static func sphere(rings: Int, segments: Int, radius: Float = 10) -> Data {
        func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
            if i == 0 { return [0, 0, radius] }
            if i == rings { return [0, 0, -radius] }
            let theta = Float.pi * Float(i) / Float(rings), phi = 2 * Float.pi * Float(j % segments) / Float(segments)
            return [radius * sin(theta) * cos(phi), radius * sin(theta) * sin(phi), radius * cos(theta)]
        }
        var tris: [[SIMD3<Float>]] = []
        for j in 0..<segments { tris.append([point(0, 0), point(1, j), point(1, j + 1)]) }
        for i in 1..<(rings - 1) {
            for j in 0..<segments {
                tris.append([point(i, j), point(i + 1, j), point(i + 1, j + 1)])
                tris.append([point(i, j), point(i + 1, j + 1), point(i, j + 1)])
            }
        }
        for j in 0..<segments { tris.append([point(rings, 0), point(rings - 1, j + 1), point(rings - 1, j)]) }
        return binarySTL(tris)
    }

    /// A 20 × 10 × 6 box whose every face is cut into `n` × `n` squares, two triangles each.
    static func gridBox(_ n: Int) -> Data {
        let size = SIMD3<Float>(20, 10, 6)
        var tris: [[SIMD3<Float>]] = []
        // For each of the six faces: a corner, two edge directions (u × v pointing out of the box).
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([0, 0, 0], [0, size.y, 0], [size.x, 0, 0]),                  // bottom (z = 0), normal -z
            ([0, 0, size.z], [size.x, 0, 0], [0, size.y, 0]),             // top
            ([0, 0, 0], [size.x, 0, 0], [0, 0, size.z]),                  // front (y = 0), normal -y
            ([0, size.y, 0], [0, 0, size.z], [size.x, 0, 0]),             // back
            ([0, 0, 0], [0, 0, size.z], [0, size.y, 0]),                  // left (x = 0), normal -x
            ([size.x, 0, 0], [0, size.y, 0], [0, 0, size.z]),             // right
        ]
        for (o, u, v) in faces {
            for i in 0..<n {
                for j in 0..<n {
                    let a = o + u * (Float(i) / Float(n)) + v * (Float(j) / Float(n))
                    let b = a + u / Float(n), c = b + v / Float(n), d = a + v / Float(n)
                    tris.append([a, b, c])
                    tris.append([a, c, d])
                }
            }
        }
        return binarySTL(tris)
    }

    @Test func countsTheTrianglesOfBinaryAndASCIIFiles() throws {
        let box = Self.gridBox(2)
        #expect(KBody.stlTriangleCount(box) == 48)
        let ascii = Data("solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n".utf8)
        #expect(KBody.stlTriangleCount(ascii) == 1)
        #expect(KBody.stlTriangleCount(Data("hello".utf8)) == nil)
    }

    @Test func aFinelyCutBoxCollapsesBackToItsSixFaces() throws {
        let fine = Self.gridBox(30)  // 10 800 triangles
        #expect(KBody.stlTriangleCount(fine) == 10_800)
        let reduced = try KBody.simplifySTL(fine, toTriangles: 500)
        let count = try #require(KBody.stlTriangleCount(reduced))
        #expect(count <= 500, "\(count) triangles")
        let body = try KBody.importSTL(reduced, featureID: "simplbox")
        #expect(abs(body.volume - 1200) < 1e-2, "\(body.volume)")
        #expect(body.faceNames.count == 6, "\(body.faceNames.count) faces")
    }

    @Test func aSphereKeepsItsShapeAndVolumeWhenReduced() throws {
        let fine = Self.sphere(rings: 100, segments: 200)  // 39 600 triangles
        let reduced = try KBody.simplifySTL(fine, toTriangles: 2_000)
        let count = try #require(KBody.stlTriangleCount(reduced))
        #expect(count <= 2_100 && count >= 1_000, "\(count) triangles")
        let body = try KBody.importSTL(reduced, featureID: "simplsphere")
        let exact = 4.0 / 3.0 * Double.pi * 1000
        #expect(body.volume > exact * 0.95 && body.volume < exact * 1.01, "\(body.volume) vs \(exact)")
        let bounds = try #require(body.bounds)
        #expect(abs(bounds.max.x - 10) < 0.3 && abs(bounds.min.z + 10) < 0.3, "\(bounds)")
    }

    @Test func aMeshThatIsAlreadySmallEnoughIsLeftAlone() throws {
        let small = Self.gridBox(1)  // 12 triangles
        let same = try KBody.simplifySTL(small, toTriangles: 1_000)
        #expect(KBody.stlTriangleCount(same) == 12)
    }

    @Test func aMeshOverTheLimitIsRefusedUntilItIsReduced() throws {
        let big = Self.gridBox(90)  // 97 200 triangles: fine
        #expect(KBody.stlTriangleCount(big)! <= KBody.maxSTLTriangles)
        let tooBig = Self.gridBox(100)  // 120 000
        #expect(throws: KernelError.self) { try KBody.importSTL(tooBig, featureID: "toobig") }
        let reduced = try KBody.simplifySTL(tooBig, toTriangles: 5_000)
        let body = try KBody.importSTL(reduced, featureID: "reducedbig")
        #expect(abs(body.volume - 1200) < 1e-2 && body.faceNames.count == 6)
    }

    @Test func aFileThatIsNotAnSTLCannotBeReduced() {
        #expect(throws: KernelError.self) { try KBody.simplifySTL(Data("hello".utf8), toTriangles: 100) }
    }

    @Test func smallHolesAreFilledWhenAMeshIsReduced() throws {
        // Take triangles out of a box: one on a side, and two next to each other on another.
        let whole = Self.gridBox(10)
        var bytes = whole
        let all = (0..<1200).map { i in Data(bytes[(84 + 50 * i)..<(84 + 50 * (i + 1))]) }
        let kept = all.enumerated().filter { ![5, 300, 301].contains($0.offset) }.map(\.element)
        bytes = whole.prefix(80) + withUnsafeBytes(of: UInt32(kept.count)) { Data($0) } + kept.reduce(Data()) { $0 + $1 }
        #expect(KBody.stlTriangleCount(bytes) == 1197)
        #expect(throws: KernelError.self) { try KBody.importSTL(bytes, featureID: "holey") }
        let repaired = try KBody.simplifySTL(bytes, toTriangles: 100_000)
        let body = try KBody.importSTL(repaired, featureID: "repaired")
        #expect(abs(body.volume - 1200) < 1e-2, "\(body.volume)")
        #expect(body.faceNames.count == 6, "\(body.faceNames.count) faces")
    }
}

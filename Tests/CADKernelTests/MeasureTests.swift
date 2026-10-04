// Measuring faces, edges and bodies: sizes, round geometry and the distance between two pieces.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import simd
import Testing
@testable import CADKernel

@Suite struct MeasureTests {
    static func close(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol * max(abs(b), 1) }
    static func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double = 1e-6) -> Bool {
        close(a.x, b.x, tol) && close(a.y, b.y, tol) && close(a.z, b.z, tol)
    }

    static func box(_ w: Double, _ l: Double, _ h: Double, id: String = "b") throws -> KBody {
        try KBody.primitive(.box(width: w, length: l, height: h), on: .xy, featureID: id)
    }

    @Test func aBodyHasVolumeAreaAndExtent() throws {
        let m = try Self.box(20, 10, 5).measure()
        #expect(m.geometry == .body)
        #expect(Self.close(m.volume, 1000))
        #expect(Self.close(m.size, 2 * (200 + 100 + 50)))
        #expect(Self.close(m.extent, SIMD3(20, 10, 5)))
    }

    @Test func aFlatFaceHasAreaPerimeterAndNormal() throws {
        let body = try Self.box(20, 10, 5)
        let top = try body.measure(.face("b.top"))
        #expect(top.geometry == .plane)
        #expect(Self.close(top.size, 200))
        #expect(Self.close(top.perimeter, 60))
        #expect(Self.close(top.direction ?? .zero, SIMD3(0, 0, 1)))
        #expect(Self.close(top.extent, SIMD3(20, 10, 0)))
        let bottom = try body.measure(.face("b.bottom"))
        #expect(Self.close(bottom.direction ?? .zero, SIMD3(0, 0, -1)))
    }

    @Test func aStraightEdgeHasLengthDirectionAndEnds() throws {
        let body = try Self.box(20, 10, 5)
        let lengths = try body.edgeNames.map { try body.measure(.edge($0)) }
        #expect(lengths.count == 12)
        #expect(lengths.allSatisfy { $0.geometry == .line })
        #expect(lengths.filter { Self.close($0.size, 20) }.count == 4)
        #expect(lengths.filter { Self.close($0.size, 10) }.count == 4)
        #expect(lengths.filter { Self.close($0.size, 5) }.count == 4)
        let e = lengths[0]
        let ends = try #require(e.ends)
        #expect(Self.close(simd_length(ends.end - ends.start), e.size))
    }

    @Test func aCylinderFaceAndItsCircularEdgesAreRound() throws {
        let body = try KBody.primitive(.cylinder(diameter: 10, height: 30), on: .xy, featureID: "c")
        let side = try body.measure(.face("c.side"))
        #expect(side.geometry == .cylinder)
        #expect(Self.close(side.radius, 5))
        #expect(Self.close(side.length, 30))
        #expect(Self.close(side.size, 2 * .pi * 5 * 30))
        #expect(Self.close(abs(side.direction?.z ?? 0), 1))
        let circles = try body.edgeNames.map { try body.measure(.edge($0)) }.filter { $0.geometry == .circle }
        #expect(circles.count == 2)
        #expect(circles.allSatisfy { Self.close($0.radius, 5) && Self.close($0.size, 2 * .pi * 5) })
        #expect(circles.contains { Self.close($0.center?.z ?? -1, 0) } && circles.contains { Self.close($0.center?.z ?? -1, 30) })
    }

    @Test func aSphereHasRadiusAndCentre() throws {
        let body = try KBody.primitive(.sphere(diameter: 20), on: .xy, featureID: "s")
        let face = try body.measure(.face(try #require(body.faceNames.first)))
        #expect(face.geometry == .sphere)
        #expect(Self.close(face.radius, 10))
        #expect(Self.close(face.center ?? .zero, .zero))
        #expect(Self.close(try body.measure().volume, 4.0 / 3 * .pi * 1000, 1e-4))
    }

    @Test func theDistanceBetweenTwoFacesIsTheGapBetweenThem() throws {
        let body = try Self.box(20, 10, 5)
        let d = try body.distance(.face("b.top"), to: body, .face("b.bottom"))
        #expect(Self.close(d.distance, 5))
        #expect(Self.close(abs(d.a.z - d.b.z), 5))
    }

    @Test func theDistanceBetweenTwoBodiesIsTheGapBetweenTheirNearestPoints() throws {
        let a = try Self.box(10, 10, 10, id: "a")
        let b = try Self.box(10, 10, 10, id: "b").translated(SIMD3(25, 0, 0))
        let d = try a.distance(.body, to: b, .body)
        #expect(Self.close(d.distance, 15))
        #expect(Self.close(d.a.x, 5) && Self.close(d.b.x, 20))
        // Touching bodies are no distance apart.
        let c = try Self.box(10, 10, 10, id: "c").translated(SIMD3(10, 0, 0))
        #expect(Self.close(try a.distance(.body, to: c, .body).distance, 0))
    }

    @Test func missingPiecesAreReported() throws {
        let body = try Self.box(1, 1, 1)
        #expect(throws: KernelError.self) { try body.measure(.face("nope")) }
        #expect(throws: KernelError.self) { try body.distance(.edge("nope"), to: body, .body) }
    }
}

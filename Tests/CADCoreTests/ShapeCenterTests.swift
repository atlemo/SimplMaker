// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Finding the middle of closed shapes, and keeping what's placed there centred.
@Suite struct ShapeCenterTests {
    @Test func aRectangleAndATriangleHaveCenters() throws {
        var s = Sketch()
        s.addRectangle(10, 0, 50, 20)
        let a = s.addPoint(100, 0), b = s.addPoint(140, 0), c = s.addPoint(120, 30)
        s.addLine(a, b); s.addLine(b, c); s.addLine(c, a)
        s.addLine(s.addPoint(0, 50), s.addPoint(10, 60))  // open: no center
        let centers = s.shapeCenters()
        #expect(centers.count == 2)
        let rect = try #require(centers.first { $0.corners != nil })
        #expect(vlen(rect.position - SIMD2(30, 10)) < 1e-9)
        let tri = try #require(centers.first { $0.corners == nil })
        #expect(vlen(tri.position - SIMD2(120, 15)) < 1e-9, "the middle of its bounding box")
    }

    @Test func aCircleAtTheCenterStaysCentred() throws {
        var s = Sketch()
        let rect = s.addRectangle(0, 0, 40, 20)
        let center = try #require(s.shapeCenters().first)
        let circle = s.addCircle(center: SketchSnap(center.position, centerOf: center.corners), through: SketchSnap(SIMD2(25, 10)))
        let c = try #require(s.center(of: circle))
        // Drag the top-right corner out: the rectangle grows and the circle follows.
        let moved = s.drag(rect.corners[2], to: SIMD2(60, 30), values: [:])
        #expect(moved)
        let lo = try #require(s.position(rect.corners[0])), hi = try #require(s.position(rect.corners[2]))
        let p = try #require(s.position(c))
        #expect(vlen(hi - SIMD2(60, 30)) < 1e-6)
        #expect(vlen(p - (lo + hi) / 2) < 1e-6, "still in the middle: \(p)")
        #expect(vlen(p - (s.shapeCenters().first?.position ?? .zero)) < 1e-6)
        #expect(s.curves.contains { $0.construction }, "held by a construction diagonal")
    }
}

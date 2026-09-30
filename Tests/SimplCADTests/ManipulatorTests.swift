// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CoreGraphics
import Foundation
import Testing
import simd
@testable import SimplCAD

/// The Move/Rotate manipulator's layout, hit tests and drag math (no window needed).
@Suite struct ManipulatorTests {
    let size = CGSize(width: 900, height: 700)

    private func camera(top: Bool = false) -> Camera {
        var c = Camera()
        c.target = SIMD3(30, 20, 5)
        c.distance = 200
        if top { c.setStandard(.top) }
        return c
    }

    private func layout(_ camera: Camera, turn: SIMD3<Double> = .zero) throws -> ManipulatorLayout {
        try #require(ManipulatorLayout(middle: SIMD3(30, 20, 5), turn: turn, camera: camera, viewSize: size))
    }

    private func screen(_ p: SIMD3<Double>, _ c: Camera) throws -> CGPoint { try #require(ManipulatorLayout.project(p, c, size)) }

    @Test func fromAboveTheZArrowIsHidden() throws {
        let l = try layout(camera(top: true))
        #expect(Set(l.arrows.map(\.axis)) == [.x, .y], "Z points at the viewer")
        #expect(l.squares.map(\.normal) == [.z] || Set(l.squares.map(\.normal)).contains(.z), "the XY square shows")
        #expect(l.rings.count == 3)
        #expect(hypot(l.center.x - 450, l.center.y - 350) < 200)
    }

    @Test func clicksHitTheRightPart() throws {
        let l = try layout(camera())
        #expect(l.hit(l.center) == .center)
        for a in l.arrows {
            let mid = CGPoint(x: (a.tail.x + a.tip.x) / 2, y: (a.tail.y + a.tip.y) / 2)
            #expect(l.hit(mid) == .axis(a.axis))
        }
        for r in l.rings { #expect(l.hit(r.handle) == .ring(r.axis)) }
        // From above nothing covers the XY square.
        let top = try layout(camera(top: true))
        let sq = try #require(top.squares.first { $0.normal == .z })
        #expect(top.hit(CGPoint(x: sq.corners.map(\.x).reduce(0, +) / 4, y: sq.corners.map(\.y).reduce(0, +) / 4)) == .plane(.z))
        #expect(l.hit(CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func draggingAnArrowSlidesAlongItsAxis() throws {
        let c = camera(top: true)
        let l = try layout(c)
        let x = try #require(l.arrows.first { $0.axis == .x })
        var drag = try #require(ManipulatorDrag(part: .axis(.x), at: x.tip, layout: l, start: TransformValues()))
        // 50 mm along X, on screen.
        let there = try screen(SIMD3(30, 20, 5) + SIMD3(50, 0, 0), c)
        let here = CGPoint(x: there.x + (x.tip.x - l.center.x), y: there.y + (x.tip.y - l.center.y))
        let vopt = drag.values(at: here, camera: c, viewSize: size)
        let v = try #require(vopt)
        #expect(abs(v.move.x - 50) < 1.0 && v.move.y == 0 && v.move.z == 0 && v.turn == .zero, "\(v)")
        // Back the other way: negative, from where it started.
        var back = try #require(ManipulatorDrag(part: .axis(.x), at: x.tip, layout: l, start: TransformValues(move: SIMD3(10, 0, 0))))
        let wopt = back.values(at: CGPoint(x: x.tip.x - 2 * l.pointsPerMM * 30, y: x.tip.y), camera: c, viewSize: size)
        let w = try #require(wopt)
        #expect(abs(w.move.x - (10 - 60)) < 1.0, "\(w)")
    }

    @Test func aSquareSlidesInItsPlaneAndTheDotAnywhereOnScreen() throws {
        let c = camera(top: true)
        let l = try layout(c)
        let sq = try #require(l.squares.first { $0.normal == .z })
        let grab = CGPoint(x: sq.corners.map(\.x).reduce(0, +) / 4, y: sq.corners.map(\.y).reduce(0, +) / 4)
        var drag = try #require(ManipulatorDrag(part: .plane(.z), at: grab, layout: l, start: TransformValues()))
        let moved = CGPoint(x: grab.x + 30 * l.pointsPerMM, y: grab.y - 20 * l.pointsPerMM)  // +30 right, 20 up the screen
        let vopt = drag.values(at: moved, camera: c, viewSize: size)
        let v = try #require(vopt)
        #expect(abs(v.move.x - 30) < 1 && abs(abs(v.move.y) - 20) < 1 && v.move.z == 0, "\(v)")

        var free = try #require(ManipulatorDrag(part: .center, at: l.center, layout: l, start: TransformValues()))
        let fopt = free.values(at: CGPoint(x: l.center.x + 10 * l.pointsPerMM, y: l.center.y), camera: c, viewSize: size)
        let f = try #require(fopt)
        #expect(abs(f.move.x - 10) < 0.6 && abs(f.move.y) < 0.6 && abs(f.move.z) < 0.6, "\(f)")
    }

    @Test func draggingARingTurnsAboutItsAxis() throws {
        let c = camera(top: true)
        let l = try layout(c)
        let ring = try #require(l.rings.first { $0.axis == .z })
        var drag = try #require(ManipulatorDrag(part: .ring(.z), at: ring.handle, layout: l, start: TransformValues()))
        // The handle rides at 45°; carry the mouse to 135° round the ring: a quarter turn counter-clockwise.
        let radius = Double(ManipulatorLayout.ringRadius) / l.pointsPerMM
        let target = SIMD3(30, 20, 5) + radius * SIMD3(cos(3 * Double.pi / 4), sin(3 * Double.pi / 4), 0)
        let vopt = drag.values(at: try screen(target, c), camera: c, viewSize: size)
        let v = try #require(vopt)
        #expect(abs(v.turn.z - .pi / 2) < 0.02 && v.turn.x == 0 && v.turn.y == 0 && v.move == .zero, "\(v)")
        // On round to a bit past half a turn: it keeps counting, not wrapping.
        let far = SIMD3(30, 20, 5) + radius * SIMD3(cos(-3 * Double.pi / 4), sin(-3 * Double.pi / 4), 0)
        _ = drag.values(at: try screen(SIMD3(30, 20, 5) + radius * SIMD3(cos(Double.pi * 1.2), sin(Double.pi * 1.2), 0), c), camera: c, viewSize: size)
        let wopt = drag.values(at: try screen(far, c), camera: c, viewSize: size)
        let w = try #require(wopt)
        #expect(abs(w.turn.z - (5 * Double.pi / 4 - Double.pi / 4)) < 0.05 || abs(w.turn.z - .pi) < 0.05, "180° round: \(w.turn.z)")
    }

    @Test func aRingSeenEdgeOnTurnsByTheMouseTravelAlongIt() throws {
        var c = camera()
        c.setStandard(.front)  // looking along Y: the ring about Z is edge-on
        let l = try layout(c)
        let ring = try #require(l.rings.first { $0.axis == .z })
        var drag = try #require(ManipulatorDrag(part: .ring(.z), at: ring.handle, layout: l, start: TransformValues()))
        let d = ring.direction
        let travelled = Double(ManipulatorLayout.ringRadius) * (Double.pi / 4)  // 45° worth of arc, in points
        let vopt = drag.values(at: CGPoint(x: ring.handle.x + d.dx * travelled, y: ring.handle.y + d.dy * travelled),
                               camera: c, viewSize: size)
        let v = try #require(vopt)
        #expect(abs(abs(v.turn.z) - .pi / 4) < 0.1, "\(v.turn.z)")
    }

    @Test func handlesRideRoundWithTheTurn() throws {
        let c = camera(top: true)
        let a = try layout(c), b = try layout(c, turn: SIMD3(0, 0, .pi / 2))
        let h0 = try #require(a.rings.first { $0.axis == .z }).handle, h1 = try #require(b.rings.first { $0.axis == .z }).handle
        #expect(hypot(h0.x - h1.x, h0.y - h1.y) > 50)
        #expect(a.anchor(for: .axis(.x)) != nil && a.anchor(for: .plane(.z)) == nil)
    }

    @Test func perspectiveKeepsTheSameSizeOnScreen() throws {
        var near = camera(), far = camera()
        near.orthographic = false; far.orthographic = false
        near.distance = 100; far.distance = 900
        let a = try layout(near), b = try layout(far)
        let ax = try #require(a.arrows.first { $0.axis == .x }), bx = try #require(b.arrows.first { $0.axis == .x })
        let la = hypot(ax.tip.x - a.center.x, ax.tip.y - a.center.y), lb = hypot(bx.tip.x - b.center.x, bx.tip.y - b.center.y)
        #expect(abs(la - lb) < 6, "\(la) vs \(lb)")
    }
}

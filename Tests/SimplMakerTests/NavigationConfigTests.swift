// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Foundation
import simd
import Testing
@testable import SimplMaker

/// Which inputs orbit, pan and zoom the camera, which way, and how fast.
@Suite struct NavigationConfigTests {
    private func moved(_ config: NavigationConfig, _ action: NavAction, _ input: NavInput, dx: Float, dy: Float) -> Camera {
        var camera = Camera()
        config.navigate(&camera, action, input: input, dx: dx, dy: dy, viewHeight: 600)
        return camera
    }

    @Test func theDefaultsAreWhatSimplMakerAlwaysDid() {
        let c = NavigationConfig.simplMaker()
        #expect(c.left.plain == .orbit && c.right.plain == .pan && c.middle.plain == .pan)
        #expect(c.trackpad.plain == .pan && c.trackpad.shift == .orbit)
        #expect(c.wheel.plain == .zoom)
        #expect(c.matchingPreset == .simplMaker)
    }

    @Test func optionDragRollsAndOnlyTheRotateGestureRollsInASketch() {
        let c = NavigationConfig.simplMaker()
        #expect(c.left.option == .roll && c.left.plain == .orbit)
        var camera = Camera()
        c.rotate(&camera, degrees: 30)
        #expect(camera.roll == 0 && camera.yaw != Camera().yaw, "outside a sketch it spins the view")
        camera = Camera()
        c.rotate(&camera, degrees: 30, sketching: true)
        #expect(abs(camera.roll - .pi / 6) < 1e-6 && camera.yaw == Camera().yaw, "in one it turns the picture, counter-clockwise")
    }

    @Test func theOldSettingsCarryOver() {
        let c = NavigationConfig.simplMaker(trackpadOrbits: true, invertZoom: true)
        #expect(c.trackpad.plain == .orbit && c.trackpad.shift == .pan && c.invertZoom)
    }

    @Test func draggingOrbitsAsBefore() {
        let c = NavigationConfig.simplMaker()
        let base = Camera()
        // Dragging right and down (down is positive on screen): yaw goes down, pitch goes down (the view tips over the top).
        let cam = moved(c, .orbit, .drag, dx: 10, dy: 20)
        #expect(abs((cam.yaw - base.yaw) - (-10 * 0.008)) < 1e-6)
        #expect(abs((cam.pitch - base.pitch) - (-20 * 0.008)) < 1e-6)
    }

    @Test func scrollingOrbitsTheOtherWayToDragging() {
        let c = NavigationConfig.simplMaker()
        let drag = moved(c, .orbit, .drag, dx: 10, dy: 20), scroll = moved(c, .orbit, .trackpad, dx: 10, dy: 20)
        let base = Camera()
        #expect(abs((scroll.yaw - base.yaw) + (drag.yaw - base.yaw)) < 1e-6)
        #expect(abs((scroll.pitch - base.pitch) + (drag.pitch - base.pitch)) < 1e-6)
    }

    @Test func invertingOrbitFlipsOneAxisOnly() {
        let base = Camera()
        var c = NavigationConfig.simplMaker()
        let plain = moved(c, .orbit, .drag, dx: 10, dy: 20)
        c.invertOrbitVertical = true
        let v = moved(c, .orbit, .drag, dx: 10, dy: 20)
        #expect(abs((v.pitch - base.pitch) + (plain.pitch - base.pitch)) < 1e-6)
        #expect(v.yaw == plain.yaw)
        c.invertOrbitVertical = false
        c.invertOrbitHorizontal = true
        let h = moved(c, .orbit, .drag, dx: 10, dy: 20)
        #expect(abs((h.yaw - base.yaw) + (plain.yaw - base.yaw)) < 1e-6)
        #expect(h.pitch == plain.pitch)
    }

    @Test func invertingPanFlipsTheDirection() {
        var c = NavigationConfig.simplMaker()
        let base = Camera().target
        let plain = moved(c, .pan, .drag, dx: 30, dy: 10).target - base
        c.invertPanHorizontal = true; c.invertPanVertical = true
        let flipped = moved(c, .pan, .drag, dx: 30, dy: 10).target - base
        #expect(simd_length(plain + flipped) < 1e-4 && simd_length(plain) > 0)
    }

    @Test func zoomDirectionAndInversion() {
        var c = NavigationConfig.simplMaker()
        let d = Camera().distance
        #expect(moved(c, .zoom, .wheel, dx: 0, dy: 1).distance < d, "one notch of the wheel away from you zooms in, as before")
        #expect(abs(moved(c, .zoom, .wheel, dx: 0, dy: 1).distance - d / 1.1) < 1e-3)
        #expect(moved(c, .zoom, .drag, dx: 0, dy: -50).distance < d, "dragging up zooms in")
        c.invertZoom = true
        #expect(moved(c, .zoom, .wheel, dx: 0, dy: 1).distance > d)
        #expect(moved(c, .zoom, .drag, dx: 0, dy: -50).distance > d)
    }

    @Test func speedScalesOrbitAndZoom() {
        var c = NavigationConfig.simplMaker()
        let base = Camera()
        let slow = moved(c, .orbit, .drag, dx: 10, dy: 0)
        c.orbitSpeed = 2
        let fast = moved(c, .orbit, .drag, dx: 10, dy: 0)
        #expect(abs((fast.yaw - base.yaw) - 2 * (slow.yaw - base.yaw)) < 1e-6)
        c.zoomSpeed = 2
        let once = NavigationConfig.simplMaker()
        #expect(abs(log(moved(c, .zoom, .wheel, dx: 0, dy: 1).distance / base.distance)
                    - 2 * log(moved(once, .zoom, .wheel, dx: 0, dy: 1).distance / base.distance)) < 1e-5)
    }

    @Test func nothingDoesNothing() {
        let base = Camera()
        let cam = moved(.simplMaker(), .none, .drag, dx: 40, dy: 40)
        #expect(cam.pose == base.pose)
    }

    @Test func pinchSpreadingZoomsIn() {
        var cam = Camera()
        NavigationConfig.simplMaker().pinch(&cam, magnification: 0.5)
        #expect(cam.distance < Camera().distance)
    }

    /// The spot of the picture under the cursor is still under it after zooming, in either projection.
    @Test(arguments: [true, false]) func zoomingKeepsTheSpotUnderTheCursor(orthographic: Bool) throws {
        let size = CGSize(width: 800, height: 600), cursor = CGPoint(x: 650, y: 140)
        var cam = Camera()
        cam.orthographic = orthographic
        cam.roll = 0.3
        cam.centerShift = SIMD2(0.1, -0.05)
        let ray = cam.ray(at: cursor, viewSize: size)
        // The point of the target's plane under the cursor.
        let t = simd_dot(cam.target - ray.origin, cam.forward) / simd_dot(ray.direction, cam.forward)
        let spot = ray.origin + ray.direction * t
        let anchor = ZoomAnchor(point: cursor, viewSize: size)
        NavigationConfig.simplMaker().pinch(&cam, magnification: 0.5, cursor: anchor)
        NavigationConfig.simplMaker().pinch(&cam, magnification: -0.3, cursor: anchor)
        let after = try #require(cam.project(spot, viewSize: size))
        #expect(abs(after.x - cursor.x) < 0.01 && abs(after.y - cursor.y) < 0.01)
    }

    @Test func zoomingTowardTheCursorMovesTheTarget() {
        var cam = Camera()
        let before = cam.target
        NavigationConfig.simplMaker().pinch(&cam, magnification: 0.5,
                                            cursor: ZoomAnchor(point: CGPoint(x: 700, y: 100), viewSize: CGSize(width: 800, height: 600)))
        #expect(simd_length(cam.target - before) > 1)
        var centered = Camera()
        NavigationConfig.simplMaker().pinch(&centered, magnification: 0.5,
                                            cursor: ZoomAnchor(point: CGPoint(x: 400, y: 300), viewSize: CGSize(width: 800, height: 600)))
        #expect(simd_length(centered.target - before) < 1e-3)
    }

    @Test func rotateCanBeTurnedOff() {
        var c = NavigationConfig.simplMaker()
        var cam = Camera()
        c.rotateSpins = false
        c.rotate(&cam, degrees: 10)
        #expect(cam.pose == Camera().pose)
    }

    @Test func presetsOnlyTouchTheBindings() {
        var c = NavigationConfig.simplMaker()
        c.invertOrbitVertical = true
        c.orbitSpeed = 2
        c.apply(.blender)
        #expect(c.middle.plain == .orbit && c.middle.shift == .pan && c.trackpad.plain == .orbit)
        #expect(c.invertOrbitVertical && c.orbitSpeed == 2)
        #expect(c.matchingPreset == .blender)
        c.apply(.onshape)
        #expect(c.right.plain == .orbit && c.middle.plain == .pan && c.matchingPreset == .onshape)
        c.middle.plain = .zoom
        #expect(c.matchingPreset == .custom)
    }

    @Test func everyPresetIsDistinctAndLeftControlStaysFree() {
        let all = NavigationPreset.choosable.map { NavigationConfig.preset($0) }
        for (i, a) in all.enumerated() { #expect(all.enumerated().filter { $0.offset != i && $0.element.matchingPreset == a.matchingPreset }.isEmpty) }
        for c in all { #expect(c.left.control == .none, "⌃-click is a right-click") }
    }

    @Test func modifiersChooseTheBinding() {
        #expect(NavModifier([]) == .plain && NavModifier([.shift]) == .shift && NavModifier([.control]) == .control && NavModifier([.option]) == .option)
        #expect(NavModifier([.shift, .option]) == .shift)
        #expect(NavModifier([.command]) == .plain)
    }

    @Test func roundTripsThroughJSON() throws {
        var c = NavigationConfig.preset(.solidWorks)
        c.invertOrbitVertical = true
        c.zoomSpeed = 1.5
        let back = try JSONDecoder().decode(NavigationConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Foundation
import Testing
@testable import SimplCAD

/// Leaving a sketch turns the flat view back to the 3D one it was opened from, smoothly.
@Suite struct CameraTransitionTests {
    private let iso = CameraPose(target: SIMD3(30, 20, 0), distance: 220, yaw: -.pi / 3, pitch: 0.55)
    private let flat = CameraPose(target: SIMD3(0, 0, 0), distance: 60, yaw: -.pi / 2, pitch: 1.55)

    @Test func aBlendStartsAndEndsWhereItShould() {
        #expect(iso.blended(to: flat, 0) == iso)
        #expect(flat.blended(to: iso, 1).isClose(to: iso))
        let mid = iso.blended(to: flat, 0.5)
        #expect(mid.pitch > flat.pitch - 1 && mid.pitch < iso.pitch + 1 && abs(mid.pitch - (iso.pitch + flat.pitch) / 2) < 1e-5)
        #expect(abs(mid.distance - (220 * 60).squareRoot()) < 1e-3, "zooms by the same factor each step")
    }

    @Test func turnsTheShortWayRound() {
        let a = CameraPose(target: .zero, distance: 100, yaw: 3, pitch: 0.2)
        let b = CameraPose(target: .zero, distance: 100, yaw: -3, pitch: 0.2)  // 0.28 rad away through ±π, not 6 the other way
        let mid = a.blended(to: b, 0.5)
        #expect(abs(remainder(mid.yaw - .pi, 2 * .pi)) < 1e-5, "\(mid.yaw)")
    }

    @Test func easingIsSlowAtBothEnds() {
        #expect(CameraPose.eased(0) == 0 && CameraPose.eased(1) == 1 && abs(CameraPose.eased(0.5) - 0.5) < 1e-6)
        #expect(CameraPose.eased(0.1) < 0.1 && CameraPose.eased(0.9) > 0.9)
    }

    @Test func theViewBeforeASketchIsRememberedAndGivenBack() {
        var memory = SketchCameraMemory()
        #expect(memory.update(sketching: false, camera: iso) == nil, "nothing open, nothing to return to")
        #expect(memory.update(sketching: true, camera: iso) == nil, "opening notes the view, and moves nothing")
        #expect(memory.update(sketching: true, camera: flat) == nil, "while sketching it stays put")
        #expect(memory.update(sketching: false, camera: flat) == iso, "closing goes back to the 3D view")
        #expect(memory.update(sketching: false, camera: iso) == nil, "once")
        // Another sketch starts from where the camera is then.
        #expect(memory.update(sketching: true, camera: flat) == nil)
        #expect(memory.update(sketching: false, camera: iso) == flat)
    }

    @Test func aCameraPoseRoundTripsThroughTheCamera() {
        var camera = Camera()
        camera.pose = iso
        #expect(camera.pose == iso && camera.yaw == iso.yaw && camera.distance == 220)
    }
}

@Suite @MainActor struct CameraAnimationTests {
    private func makeView() throws -> ViewportMTKView {
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        return view
    }

    private let iso = CameraPose(target: SIMD3(30, 20, 0), distance: 220, yaw: -.pi / 3, pitch: 0.55)
    private let flat = CameraPose(target: SIMD3(0, 0, 0), distance: 60, yaw: -.pi / 2, pitch: 1.55)

    @Test func theCameraTurnsInStagesAndArrives() async throws {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        let view = try makeView()
        let renderer = try #require(view.renderer)
        renderer.camera.pose = flat
        view.animateCamera(to: iso, duration: 0.3)
        #expect(view.isAnimatingCamera)
        try await Task.sleep(for: .milliseconds(150))
        let mid = renderer.camera.pose
        #expect(mid != flat && !mid.isClose(to: iso), "part of the way, not jumped: \(mid)")
        try await Task.sleep(for: .milliseconds(400))
        #expect(renderer.camera.pose.isClose(to: iso))
        #expect(!view.isAnimatingCamera)
    }

    @Test func takingHoldOfTheViewStopsIt() async throws {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        let view = try makeView()
        let renderer = try #require(view.renderer)
        renderer.camera.pose = flat
        view.animateCamera(to: iso, duration: 0.4)
        try await Task.sleep(for: .milliseconds(100))
        renderer.camera.orbit(dx: 10, dy: 0)  // the user drags
        let held = renderer.camera.pose
        try await Task.sleep(for: .milliseconds(150))
        #expect(renderer.camera.pose == held, "it let go instead of pulling the view back")
        #expect(!view.isAnimatingCamera)
    }

    @Test func aNewAnimationReplacesTheOldOne() async throws {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        let view = try makeView()
        let renderer = try #require(view.renderer)
        renderer.camera.pose = flat
        view.animateCamera(to: iso, duration: 0.3)
        try await Task.sleep(for: .milliseconds(50))
        view.animateCamera(to: flat, duration: 0.2)  // straight back
        try await Task.sleep(for: .milliseconds(400))
        #expect(renderer.camera.pose.isClose(to: flat))
        #expect(!view.isAnimatingCamera)
    }

    @Test func stoppingLeavesTheCameraWhereItIs() async throws {
        let view = try makeView()
        let renderer = try #require(view.renderer)
        renderer.camera.pose = flat
        view.stopCameraAnimation()
        #expect(renderer.camera.pose == flat && !view.isAnimatingCamera)
        view.animateCamera(to: flat)  // already there: nothing to do
        #expect(!view.isAnimatingCamera)
    }
}

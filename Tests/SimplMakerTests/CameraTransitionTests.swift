// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import simd
import Testing
@testable import SimplMaker

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

    @Test func rollTurnsTheViewAboutTheLineOfSight() {
        var camera = Camera()
        camera.look(along: SIMD3(0, 0, 1), at: .zero)
        let (right, up, forward) = (camera.right, camera.up, camera.forward)
        camera.roll(by: .pi / 2)
        #expect(simd_length(camera.forward - forward) < 1e-6, "the line of sight stays")
        // A quarter turn counter-clockwise: what was on the right is now up, and what was up is now to the left.
        #expect(simd_length(camera.up - right) < 1e-4 && simd_length(camera.right + up) < 1e-4)
        #expect(abs(simd_dot(camera.right, camera.up)) < 1e-5 && abs(simd_length(camera.up) - 1) < 1e-5)
    }

    @Test func rollGoesWithThePoseAndBlendsTheShortWayRound() {
        var camera = Camera()
        camera.roll(by: 1)
        #expect(camera.pose.roll == camera.roll && camera.roll == 1)
        let a = CameraPose(target: .zero, distance: 100, yaw: 0, pitch: 1, roll: 3)
        let b = CameraPose(target: .zero, distance: 100, yaw: 0, pitch: 1, roll: -3)
        #expect(abs(remainder(a.blended(to: b, 0.5).roll - .pi, 2 * .pi)) < 1e-5)
        #expect(!a.isClose(to: CameraPose(target: .zero, distance: 100, yaw: 0, pitch: 1, roll: 0)))
    }

    @Test func aQuarterTurnLandsOnTheNextRightAngle() {
        var camera = Camera()
        #expect(abs(camera.quarterTurnedRoll(1) - .pi / 2) < 1e-6 && abs(camera.quarterTurnedRoll(-1) + .pi / 2) < 1e-6)
        camera.roll = 0.3
        #expect(abs(camera.quarterTurnedRoll(1) - .pi / 2) < 1e-6 && abs(camera.quarterTurnedRoll(-1)) < 1e-6)
        camera.roll = .pi / 2
        #expect(abs(camera.quarterTurnedRoll(1) - .pi) < 1e-5 && abs(camera.quarterTurnedRoll(-1)) < 1e-5)
    }

    @Test func lookingAtAPlaneOrAStandardViewUndoesTheRoll() {
        var camera = Camera()
        camera.roll(by: 1)
        camera.look(along: SIMD3(0, 0, 1), at: .zero)
        #expect(camera.roll == 0)
        camera.roll(by: 1)
        camera.setStandard(.home)
        #expect(camera.roll == 0)
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

    /// Waits (up to two seconds) for the view to stop moving by itself, noting each pose it passes through.
    private func poses(until view: ViewportMTKView) async throws -> [CameraPose] {
        var seen: [CameraPose] = []
        let began = Date()
        while view.isAnimatingCamera && Date().timeIntervalSince(began) < 2 {
            if let pose = view.renderer?.camera.pose, pose != seen.last { seen.append(pose) }
            try await Task.sleep(for: .milliseconds(5))
        }
        return seen
    }

    @Test func theCameraTurnsInStagesAndArrives() async throws {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        let view = try makeView()
        let renderer = try #require(view.renderer)
        // The animation goes by the clock, and the main actor is shared with the tests running alongside: held up for
        // longer than the whole turn, it rightly jumps to the end, and that run shows nothing. So a few tries.
        var between: CameraPose?
        for _ in 0..<5 where between == nil {
            renderer.camera.pose = flat
            view.animateCamera(to: iso, duration: 0.3)
            #expect(view.isAnimatingCamera)
            between = try await poses(until: view).first { $0 != flat && !$0.isClose(to: iso) }
            #expect(renderer.camera.pose.isClose(to: iso))
            #expect(!view.isAnimatingCamera)
        }
        #expect(between != nil, "part of the way, not jumped")
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
        _ = try await poses(until: view)
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

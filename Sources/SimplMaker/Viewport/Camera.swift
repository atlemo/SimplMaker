// Orbit camera, Z up. Angles in radians, distances in mm.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import simd
import SwiftUI

enum StandardView: String, CaseIterable, Identifiable {
    case top, front, right, home
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "Top"
        case .front: return "Front"
        case .right: return "Right"
        case .home: return "Home (Isometric)"
        }
    }
    var shortcut: KeyboardShortcut {
        switch self {
        case .top: return KeyboardShortcut("1")
        case .front: return KeyboardShortcut("2")
        case .right: return KeyboardShortcut("3")
        case .home: return KeyboardShortcut("4")
        }
    }
}

enum CameraCommand {
    case look(target: SIMD3<Float>, normal: SIMD3<Float>)
    /// Looks straight at a plane and frames a box on it.
    case lookFit(min: SIMD3<Float>, max: SIMD3<Float>, normal: SIMD3<Float>)
    case standard(StandardView)
}

/// Where a camera stands and where it looks: what a view change animates between.
struct CameraPose: Equatable {
    var target: SIMD3<Float>
    var distance: Float
    var yaw: Float
    var pitch: Float
    /// Turn about the line of sight, in radians: positive turns the picture counter-clockwise (a sketch's axes
    /// don't have to run along the screen's).
    var roll: Float = 0

    /// The pose a fraction `t` (0...1) of the way from this one to `goal`: turning the short way round, and
    /// zooming by the same factor each step, so a big change in distance doesn't rush at the end.
    func blended(to goal: CameraPose, _ t: Float) -> CameraPose {
        CameraPose(target: target + (goal.target - target) * t,
                   distance: distance * pow(goal.distance / distance, t),
                   yaw: yaw + remainder(goal.yaw - yaw, 2 * .pi) * t,
                   pitch: pitch + (goal.pitch - pitch) * t,
                   roll: roll + remainder(goal.roll - roll, 2 * .pi) * t)
    }

    /// Whether the two are the same view, give or take rounding.
    func isClose(to other: CameraPose) -> Bool {
        simd_length(target - other.target) < 1e-3 * max(distance, 1) && abs(distance / other.distance - 1) < 1e-3
            && abs(remainder(yaw - other.yaw, 2 * .pi)) < 1e-4 && abs(pitch - other.pitch) < 1e-4
            && abs(remainder(roll - other.roll, 2 * .pi)) < 1e-4
    }

    /// Slow at both ends: 0...1 in, 0...1 out.
    static func eased(_ t: Float) -> Float { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
}

/// Remembers the view from before a sketch was opened, so closing the sketch can go back to it.
struct SketchCameraMemory {
    private var sketching = false
    private var saved: CameraPose?

    /// Tell it, on every update, whether a sketch is open and where the camera is now. Returns the view to
    /// return to when that update closed the sketch.
    mutating func update(sketching now: Bool, camera: CameraPose) -> CameraPose? {
        guard now != sketching else { return nil }
        sketching = now
        if now {
            saved = camera
            return nil
        }
        defer { saved = nil }
        return saved
    }
}

struct Camera {
    var target = SIMD3<Float>(30, 20, 0)
    var distance: Float = 220
    var yaw: Float = -.pi / 3        // around Z
    var pitch: Float = 0.55          // above the XY plane
    var roll: Float = 0              // about the line of sight; counter-clockwise on screen when positive
    var fovY: Float = 35 * .pi / 180
    var orthographic = true
    /// Where the middle of the uncovered part of the view is, in normalized device coordinates
    /// (floating panels cover the sides). The image is shifted so the camera looks at that spot.
    var centerShift = SIMD2<Float>(0, 0)
    /// How much of the view's width and height is uncovered, 0...1 (used to fit the model into it).
    var visibleFraction = SIMD2<Float>(1, 1)

    var pose: CameraPose {
        get { CameraPose(target: target, distance: distance, yaw: yaw, pitch: pitch, roll: roll) }
        set {
            target = newValue.target; distance = newValue.distance
            yaw = newValue.yaw; pitch = newValue.pitch; roll = newValue.roll
        }
    }

    /// Half the visible height at the target, in mm (used for orthographic size and panning).
    var halfHeight: Float { distance * tan(fovY / 2) }
    /// Orthographic views look from far back so nothing in front of the target gets clipped.
    private var viewEye: SIMD3<Float> { orthographic ? target - forward * orthoBack : eye }
    private var orthoBack: Float { max(distance * 3, 300) }

    var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }
    var forward: SIMD3<Float> { simd_normalize(target - eye) }
    /// The view is from under the ground plane (Z = 0): looking up at it in an orthographic view, which has no
    /// eye of its own to place, or with the eye below it in a perspective one.
    var isBelowGround: Bool { orthographic ? sin(pitch) < -1e-4 : eye.z < 0 }
    /// Right and up before the roll: up is as near the world's Z as the view allows.
    /// Taken from the yaw, not from forward × Z, which collapses to zero when looking straight down or up.
    private var levelRight: SIMD3<Float> { SIMD3(-sin(yaw), cos(yaw), 0) }
    private var levelUp: SIMD3<Float> { simd_cross(levelRight, forward) }
    var right: SIMD3<Float> { roll == 0 ? levelRight : cos(roll) * levelRight - sin(roll) * levelUp }
    var up: SIMD3<Float> { roll == 0 ? levelUp : sin(roll) * levelRight + cos(roll) * levelUp }

    func viewMatrix() -> simd_float4x4 {
        let f = forward, s = right, u = up, e = viewEye
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, e), -simd_dot(u, e), simd_dot(f, e), 1)))
    }

    /// Clip-space depth offset that moves a point toward the camera by 1× its view depth (perspective)
    /// or by 1× the camera distance (orthographic). Edges and sketch lines are drawn a small multiple of
    /// this in front, so they win over their own faces without showing through the body: a constant
    /// offset in depth-buffer units grows with distance in perspective and let hidden edges poke out
    /// near corners.
    var depthBiasScale: Float {
        if orthographic {
            let near: Float = 1, far = orthoBack * 2 + 1000
            return distance / (far - near)
        }
        return max(distance * 0.005, 0.01)  // the near plane: Δz = bias · z / near in perspective
    }

    /// Right-handed perspective with Metal's [0, 1] depth range, shifted by `centerShift`.
    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let shift = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                            SIMD4(centerShift.x, centerShift.y, 0, 1)))
        return shift * unshiftedProjection(aspect: aspect)
    }

    private func unshiftedProjection(aspect: Float) -> simd_float4x4 {
        if orthographic {
            let h = halfHeight, w = h * aspect
            let near: Float = 1, far = orthoBack * 2 + 1000
            return simd_float4x4(columns: (
                SIMD4(1 / w, 0, 0, 0), SIMD4(0, 1 / h, 0, 0),
                SIMD4(0, 0, 1 / (near - far), 0), SIMD4(0, 0, near / (near - far), 1)))
        }
        let near = max(distance * 0.005, 0.01), far = distance * 50 + 1000
        let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -.pi / 2), .pi / 2)
    }

    /// Turns the picture about the line of sight by `radians`, counter-clockwise on screen when positive.
    mutating func roll(by radians: Float) {
        roll = remainder(roll + radians, 2 * .pi)
    }

    /// The roll a quarter turn from this one in a direction (+1 counter-clockwise, −1 clockwise): the next
    /// multiple of 90° that way, so a picture turned a little first lands square.
    func quarterTurnedRoll(_ direction: Int) -> Float {
        let quarter = Float.pi / 2, r = roll / quarter
        return (direction > 0 ? floor(r + 1e-3) + 1 : ceil(r - 1e-3) - 1) * quarter
    }

    /// Pans by a screen-space delta in points, so the model follows the cursor.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let scale = 2 * halfHeight / max(viewHeight, 1)
        target += (-dx * right + dy * up) * scale
    }

    mutating func zoom(_ factor: Float) { distance = min(max(distance * factor, 0.5), 100_000) }

    /// Zooms so that the spot of the picture under `point` (view coordinates, points, origin top-left) stays
    /// under it: the camera drifts toward the point when zooming in and away from it when zooming out.
    mutating func zoom(_ factor: Float, about point: CGPoint, viewSize: CGSize) {
        let before = distance
        zoom(factor)
        let applied = distance / before  // the zoom limits may have held it back
        let w = Float(max(viewSize.width, 1)), h = Float(max(viewSize.height, 1))
        let nx = 2 * Float(point.x) / w - 1 - centerShift.x, ny = 1 - 2 * Float(point.y) / h - centerShift.y
        // The point's offset from the target, across the plane through the target facing the camera, at the old distance.
        let half = before * tan(fovY / 2)
        let offset = nx * half * (w / h) * right + ny * half * up
        target += offset * (1 - applied)
    }

    /// Ray through a point in view coordinates (points, origin top-left).
    func ray(at p: CGPoint, viewSize: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let w = Float(max(viewSize.width, 1)), h = Float(max(viewSize.height, 1))
        let nx = 2 * Float(p.x) / w - 1 - centerShift.x, ny = 1 - 2 * Float(p.y) / h - centerShift.y
        if orthographic {
            let h2 = halfHeight
            return (viewEye + nx * h2 * (w / h) * right + ny * h2 * up, forward)
        }
        let t = tan(fovY / 2)
        let d = forward + nx * t * (w / h) * right + ny * t * up
        return (eye, simd_normalize(d))
    }

    /// Projects a world point to view coordinates (points, origin top-left); nil if behind the camera.
    func project(_ world: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        let aspect = Float(viewSize.width / max(viewSize.height, 1))
        let c = projectionMatrix(aspect: aspect) * viewMatrix() * SIMD4(world, 1)
        guard c.w > 1e-6 else { return nil }
        return CGPoint(x: CGFloat((c.x / c.w + 1) / 2) * viewSize.width,
                       y: CGFloat((1 - c.y / c.w) / 2) * viewSize.height)
    }

    /// Looks straight down `normal` onto `target` (e.g. a sketch plane), keeping the distance, with the roll undone.
    mutating func look(along normal: SIMD3<Float>, at target: SIMD3<Float>) {
        self.target = target
        roll = 0
        let n = simd_normalize(normal)
        pitch = min(max(asin(min(max(n.z, -1), 1)), -.pi / 2), .pi / 2)
        if abs(n.x) + abs(n.y) > 1e-4 { yaw = atan2(n.y, n.x) } else { yaw = -.pi / 2 }
    }

    mutating func setStandard(_ view: StandardView) {
        roll = 0
        switch view {
        case .top: pitch = .pi / 2; yaw = -.pi / 2
        case .front: pitch = 0; yaw = -.pi / 2
        case .right: pitch = 0; yaw = 0
        case .home: pitch = 0.55; yaw = -.pi / 3
        }
    }

    /// Frames a bounding box in the uncovered part of a view with this width/height ratio.
    mutating func fit(min lo: SIMD3<Float>, max hi: SIMD3<Float>, aspect: Float = 1) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        let t = tan(fovY / 2)
        let half = atan(min(t * visibleFraction.y, t * aspect * visibleFraction.x))
        distance = radius / sin(max(half, 0.05)) * 1.15
    }
}

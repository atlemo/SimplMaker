// Orbit camera, Z up. Angles in radians, distances in mm.
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

struct Camera {
    var target = SIMD3<Float>(30, 20, 0)
    var distance: Float = 220
    var yaw: Float = -.pi / 3        // around Z
    var pitch: Float = 0.55          // above the XY plane
    var fovY: Float = 35 * .pi / 180
    var orthographic = true
    /// Where the middle of the uncovered part of the view is, in normalized device coordinates
    /// (floating panels cover the sides). The image is shifted so the camera looks at that spot.
    var centerShift = SIMD2<Float>(0, 0)
    /// How much of the view's width and height is uncovered, 0...1 (used to fit the model into it).
    var visibleFraction = SIMD2<Float>(1, 1)

    /// Half the visible height at the target, in mm (used for orthographic size and panning).
    var halfHeight: Float { distance * tan(fovY / 2) }
    /// Orthographic views look from far back so nothing in front of the target gets clipped.
    private var viewEye: SIMD3<Float> { orthographic ? target - forward * orthoBack : eye }
    private var orthoBack: Float { max(distance * 3, 300) }

    var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }
    var forward: SIMD3<Float> { simd_normalize(target - eye) }
    var right: SIMD3<Float> { simd_normalize(simd_cross(forward, SIMD3(0, 0, 1))) }
    var up: SIMD3<Float> { simd_cross(right, forward) }

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
        pitch = min(max(pitch + dy * 0.008, -1.55), 1.55)
    }

    /// Pans by a screen-space delta in points, so the model follows the cursor.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let scale = 2 * halfHeight / max(viewHeight, 1)
        target += (-dx * right + dy * up) * scale
    }

    mutating func zoom(_ factor: Float) { distance = min(max(distance * factor, 0.5), 100_000) }

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

    /// Looks straight down `normal` onto `target` (e.g. a sketch plane), keeping the distance.
    mutating func look(along normal: SIMD3<Float>, at target: SIMD3<Float>) {
        self.target = target
        let n = simd_normalize(normal)
        pitch = min(max(asin(n.z), -1.55), 1.55)
        if abs(n.x) + abs(n.y) > 1e-4 { yaw = atan2(n.y, n.x) } else { yaw = -.pi / 2 }
    }

    mutating func setStandard(_ view: StandardView) {
        switch view {
        case .top: pitch = 1.55; yaw = -.pi / 2
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

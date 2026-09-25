// Orbit camera, Z up. Angles in radians, distances in mm.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import simd

struct Camera {
    var target = SIMD3<Float>(30, 20, 0)
    var distance: Float = 220
    var yaw: Float = -.pi / 3        // around Z
    var pitch: Float = 0.55          // above the XY plane
    var fovY: Float = 35 * .pi / 180

    var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }
    var forward: SIMD3<Float> { simd_normalize(target - eye) }
    var right: SIMD3<Float> { simd_normalize(simd_cross(forward, SIMD3(0, 0, 1))) }
    var up: SIMD3<Float> { simd_cross(right, forward) }

    func viewMatrix() -> simd_float4x4 {
        let f = forward, s = right, u = up, e = eye
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, e), -simd_dot(u, e), simd_dot(f, e), 1)))
    }

    /// Right-handed perspective with Metal's [0, 1] depth range.
    func projectionMatrix(aspect: Float) -> simd_float4x4 {
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
        let scale = 2 * distance * tan(fovY / 2) / max(viewHeight, 1)
        target += (-dx * right + dy * up) * scale
    }

    mutating func zoom(_ factor: Float) { distance = min(max(distance * factor, 0.5), 100_000) }

    /// Ray through a point in view coordinates (points, origin top-left).
    func ray(at p: CGPoint, viewSize: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let w = Float(max(viewSize.width, 1)), h = Float(max(viewSize.height, 1))
        let nx = 2 * Float(p.x) / w - 1, ny = 1 - 2 * Float(p.y) / h
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

    mutating func fit(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        distance = radius / sin(fovY / 2) * 1.15
    }
}

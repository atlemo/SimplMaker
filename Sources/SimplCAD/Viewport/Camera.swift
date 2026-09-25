// Orbit camera, Z up. Angles in radians, distances in mm.
// SPDX-License-Identifier: GPL-3.0-or-later
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

    mutating func fit(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        distance = radius / sin(fovY / 2) * 1.15
    }
}

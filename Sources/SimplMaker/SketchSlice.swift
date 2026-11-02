// Slice View for sketching: when part of the model stands between the camera and the sketch plane (a sketch
// between walls), the sketch starts with the slice on, which cuts that part away so the plane can be reached.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADKernel
import Foundation
import simd

extension DocumentModel {
    /// Set once the user has been told why the slice came on by itself.
    static let sliceExplainedKey = "sliceViewExplained"

    /// Whether the body geometry hides the sketch plane from a camera looking at it (from the side its normal
    /// points to, where the camera goes when a sketch opens). Samples a grid over where the model reaches on the
    /// plane. A sample that lies on a face of the plane doesn't count either way: a body standing on the plane, or
    /// the face being sketched on, doesn't hide it. The plane is hidden when half of the other samples have a
    /// surface in front of them.
    func isSketchPlaneHidden(_ f: Frame) -> Bool {
        guard let b = sceneBounds else { return false }
        func local(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = p - f.origin
            return SIMD3(simd_dot(d, f.xAxis), simd_dot(d, f.yAxis), simd_dot(d, f.normal))
        }
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] { for z in [b.min.z, b.max.z] {
            let q = local(SIMD3(Double(x), Double(y), Double(z)))
            lo = simd_min(lo, SIMD2(q.x, q.y)); hi = simd_max(hi, SIMD2(q.x, q.y))
        } } }
        let n = 12, tolerance = 0.05
        guard hi.x - lo.x > 1e-6, hi.y - lo.y > 1e-6 else { return false }
        let step = (hi - lo) / Double(n - 1)
        var front = [Bool](repeating: false, count: n * n), onPlane = front

        for m in visibleMeshes {
            let p = m.mesh.positions, idx = m.mesh.indices
            for t in 0..<(idx.count / 3) {
                var v: [SIMD3<Double>] = []
                for k in 0..<3 {
                    let i = Int(idx[t * 3 + k]) * 3
                    v.append(local(SIMD3(Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))))
                }
                let area = (v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[2].x - v[0].x) * (v[1].y - v[0].y)
                guard abs(area) > 1e-9 else { continue }  // edge-on to the camera
                let minU = min(v[0].x, v[1].x, v[2].x), maxU = max(v[0].x, v[1].x, v[2].x)
                let minV = min(v[0].y, v[1].y, v[2].y), maxV = max(v[0].y, v[1].y, v[2].y)
                let i0 = max(Int(((minU - lo.x) / step.x).rounded(.up)), 0), i1 = min(Int(((maxU - lo.x) / step.x).rounded(.down)), n - 1)
                let j0 = max(Int(((minV - lo.y) / step.y).rounded(.up)), 0), j1 = min(Int(((maxV - lo.y) / step.y).rounded(.down)), n - 1)
                guard i0 <= i1, j0 <= j1 else { continue }
                for j in j0...j1 { for i in i0...i1 {
                    let x = lo.x + Double(i) * step.x, y = lo.y + Double(j) * step.y
                    // Barycentric weights of the sample in the triangle, as seen along the plane's normal.
                    let w1 = ((x - v[0].x) * (v[2].y - v[0].y) - (v[2].x - v[0].x) * (y - v[0].y)) / area
                    let w2 = ((v[1].x - v[0].x) * (y - v[0].y) - (x - v[0].x) * (v[1].y - v[0].y)) / area
                    let w0 = 1 - w1 - w2
                    guard w0 >= -1e-9, w1 >= -1e-9, w2 >= -1e-9 else { continue }
                    let height = w0 * v[0].z + w1 * v[1].z + w2 * v[2].z
                    if abs(height) <= tolerance { onPlane[j * n + i] = true } else if height > tolerance { front[j * n + i] = true }
                } }
            }
        }
        let valid = (0..<(n * n)).filter { !onPlane[$0] }
        guard valid.count >= n else { return false }
        return Double(valid.filter { front[$0] }.count) / Double(valid.count) >= 0.5
    }

    /// A sketch has just opened on this plane: the slice is on if the plane is hidden, and the first time that
    /// happens the user is told why part of the model has gone.
    func startSketchSlice(_ frame: Frame) {
        sketchSlice = isSketchPlaneHidden(frame)
        guard sketchSlice, !UserDefaults.standard.bool(forKey: Self.sliceExplainedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.sliceExplainedKey)
        alert = AlertInfo(title: "Part of the model is hidden while you sketch",
                          message: "This sketch's plane is behind other parts of the model, so Slice View cut away what is between it and the camera. Turn it off with Sketch ▸ Slice View, or the Slice View switch in the inspector.")
    }
}

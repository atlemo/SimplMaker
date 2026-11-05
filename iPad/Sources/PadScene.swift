// What the viewport shows: the demo part, rebuilt by the kernel off the main thread and tessellated.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Observation
import simd

@MainActor @Observable
final class PadScene {
    var status = "Building…"
    var meshes: [BodyMesh] = []
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var revision = 0
    /// The face or edge the last tap picked, if any.
    var selection: PickID?
    var selectionRevision = 0
    private var summary = ""
    private var selectionText = ""

    func load() async {
        let result = await Task.detached(priority: .userInitiated) { () -> (meshes: [BodyMesh], errors: Int, volume: Double, rebuild: Double, mesh: Double) in
            let t0 = Date()
            let r = Regenerator.regenerate(.demo())
            let t1 = Date()
            let meshes = MeshCache().meshes(for: r.bodies)
            let t2 = Date()
            let volume = r.bodies.reduce(0) { $0 + $1.body.volume }
            return (meshes, r.errors.count, volume, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1))
        }.value
        meshes = result.meshes
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for m in meshes {
            for i in stride(from: 0, to: m.mesh.positions.count, by: 3) {
                let p = SIMD3(m.mesh.positions[i], m.mesh.positions[i + 1], m.mesh.positions[i + 2])
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        bounds = meshes.isEmpty ? nil : (lo, hi)
        let triangles = meshes.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        summary = String(format: "OCCT %@ · %d body, %d triangles · volume %.1f mm³ · rebuild %.0f ms, mesh %.0f ms · %d errors",
                        occtVersion, meshes.count, triangles, result.volume,
                        result.rebuild * 1000, result.mesh * 1000, result.errors)
        status = summary
        revision += 1
    }

    /// A tap's pick came back (0: nothing was there).
    func picked(_ raw: UInt32) {
        let pick = PickID(raw: raw)
        switch pick.kind {
        case .face, .edge:
            selection = pick
            let mesh = meshes[safe: pick.body]?.mesh
            let names = pick.kind == .face ? mesh?.faceNames : mesh?.edgeNames
            selectionText = "\(pick.kind == .face ? "face" : "edge") \(names?[safe: pick.element] ?? "#\(pick.element)")"
        default:
            selection = nil
            selectionText = ""
        }
        status = selectionText.isEmpty ? summary : summary + "\nSelected: " + selectionText
        selectionRevision += 1
    }
}

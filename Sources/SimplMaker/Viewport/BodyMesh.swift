// A tessellated body for the viewport, and the cache that keeps the meshes of bodies a rebuild did not touch.
// Shared by the Mac and the iPad app: nothing here knows about a window system.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

/// A tessellated body for the viewport.
struct BodyMesh: Sendable {
    var index: Int
    var id: FeatureID
    var name: String
    var mesh: Mesh
}

/// Display meshes of the last rebuild's bodies: a body a rebuild didn't touch (the same kernel
/// body) keeps its mesh instead of being tessellated again.
final class MeshCache: @unchecked Sendable {
    private let lock = NSLock()
    private var meshes: [ObjectIdentifier: (body: KBody, mesh: Mesh)] = [:]  // holds the body, so its id isn't reused

    func meshes(for bodies: [BodyResult]) -> [BodyMesh] {
        lock.lock(); defer { lock.unlock() }
        var kept: [ObjectIdentifier: (body: KBody, mesh: Mesh)] = [:]
        var out: [BodyMesh] = []
        for (i, b) in bodies.enumerated() {
            let key = ObjectIdentifier(b.body)
            guard let mesh = meshes[key]?.mesh ?? (try? b.body.tessellate()) else { continue }
            kept[key] = (b.body, mesh)
            out.append(BodyMesh(index: i, id: b.id, name: b.name, mesh: mesh))
        }
        meshes = kept
        return out
    }
}

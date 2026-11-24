// Names of features and planes, as the panels and messages say them. Shared by the Mac and the iPad app.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

extension DocumentModel {
    func featureName(_ id: FeatureID) -> String { document.features.first { $0.id == id }?.name ?? "missing" }

    /// "XY plane", "Plane1" (a construction plane) or "Face e.end".
    /// An axis a plane turns about, as the Inspector and the tool's panel say it.
    func axisName(_ axis: PatternAxis) -> String {
        switch axis {
        case .x: return "X axis"
        case .y: return "Y axis"
        case .z: return "Z axis"
        case .edge(let e): return "Edge \(e.edge)"
        case .cylinder(let f): return "Axis of \(f.face)"
        }
    }

    func planeName(_ plane: PlaneRef) -> String {
        switch plane {
        case .xy: return "XY plane"
        case .xz: return "XZ plane"
        case .yz: return "YZ plane"
        case .face(let f): return "Face \(f.face)"
        case .plane(let id): return featureName(id)
        }
    }
}

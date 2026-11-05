// Names of features and planes, as the panels and messages say them. Shared by the Mac and the iPad app.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

extension DocumentModel {
    func featureName(_ id: FeatureID) -> String { document.features.first { $0.id == id }?.name ?? "missing" }

    /// "XY plane", "Plane1" (a construction plane) or "Face e.end".
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

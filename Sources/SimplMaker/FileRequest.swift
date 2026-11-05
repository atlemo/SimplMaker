// What the model needs the person to pick or choose where the Mac would open a panel: a file to import, an export format, a picture.
// The iPad app turns each into the system's picker (file importer, share sheet); the Mac asks with its own panels and does not use this.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import UniformTypeIdentifiers

enum FileRequest: Equatable, Identifiable {
    case step, stl, svg, dxf
    /// A new version of an imported body's file.
    case replaceImport(FeatureID)
    /// A picture for a Canvas, on a plane or face (`plane`, centred at `centre`), or on the open sketch's own plane.
    case image(plane: PlaneRef?, centre: SIMD2<Double>)
    /// A new picture for an existing Canvas.
    case replaceImage(FeatureID)

    var id: String {
        switch self {
        case .step: return "step"
        case .stl: return "stl"
        case .svg: return "svg"
        case .dxf: return "dxf"
        case .replaceImport(let id): return "replaceImport-\(id)"
        case .image: return "image"
        case .replaceImage(let id): return "replaceImage-\(id)"
        }
    }

    /// The kinds of file the picker shows.
    var contentTypes: [UTType] {
        switch self {
        case .step: return ["step", "stp"].compactMap { UTType(filenameExtension: $0) }
        case .stl: return [UTType(filenameExtension: "stl") ?? .data]
        case .svg: return [.svg]
        case .dxf: return [UTType(filenameExtension: "dxf") ?? .data]
        case .replaceImport: return ["step", "stp", "stl"].compactMap { UTType(filenameExtension: $0) }
        case .image, .replaceImage: return [.image]
        }
    }

    /// The picker's title.
    var title: String {
        switch self {
        case .step: return "Choose a STEP file (.step or .stp)"
        case .stl: return "Choose an STL file"
        case .svg: return "Choose an SVG file"
        case .dxf: return "Choose a DXF file"
        case .replaceImport: return "Choose the new version of the file"
        case .image, .replaceImage: return "Choose a picture"
        }
    }
}

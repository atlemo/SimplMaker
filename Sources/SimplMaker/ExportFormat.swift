// The file formats a body can be exported to. Shared by the Mac and the iPad app.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The file formats a body can be exported to.
enum ExportFormat: String, CaseIterable {
    case stl, step
    case threeMF = "3mf"

    var fileExtension: String { rawValue }
    var menuTitle: String { self == .threeMF ? "3MF…" : "\(fileExtension.uppercased())…" }
}

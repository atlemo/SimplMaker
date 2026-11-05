// Exporting on the iPad: the file is written to a temporary place and handed to the share sheet (Save to Files, AirDrop, …).
// The Mac asks for a place with a save panel instead (see DocumentModel.swift).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if !os(macOS)
import CADCore
import CADKernel
import Foundation

extension DocumentModel {
    // MARK: what the Mac asks with a panel

    func importSTEP() { guard !importInProgress() else { return }; fileRequest = .step }
    func importSTL() { guard !importInProgress() else { return }; fileRequest = .stl }
    func importSVG() { guard !importInProgress() else { return }; fileRequest = .svg }
    func importDXF() { guard !importInProgress() else { return }; fileRequest = .dxf }
    func replaceImport(_ id: FeatureID) { guard !importInProgress() else { return }; fileRequest = .replaceImport(id) }
    func replaceImage(_ id: FeatureID) { fileRequest = .replaceImage(id) }
    func exportWithDialog() { showExportChooser = true }
    func exportImageWithDialog() { showImageExport = true }

    /// What a picked file is for: hands it to the import that asked for it.
    func fileChosen(_ url: URL, for request: FileRequest) {
        let access = url.startAccessingSecurityScopedResource()
        switch request {
        case .step, .stl: Task { await importSTEP(from: url); if access { url.stopAccessingSecurityScopedResource() } }
        case .svg, .dxf: Task { await importSVG(from: url); if access { url.stopAccessingSecurityScopedResource() } }
        case .replaceImport(let id): Task { await replaceImport(id, from: url); if access { url.stopAccessingSecurityScopedResource() } }
        case .image(let plane, let centre):
            if let plane { insertImage(from: url, on: plane, at: centre) }
            else if let session = sketchSession, case .sketch(let sf)? = document.features.first(where: { $0.id == session.featureID })?.kind {
                insertImage(from: url, on: sf.plane, at: .zero, keepingSketch: true)
            }
            if access { url.stopAccessingSecurityScopedResource() }
        case .replaceImage(let id):
            replaceImage(id, from: url)
            if access { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// A fresh place in the temporary folder for a file called `name`.
    private func shareURL(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    /// Writes the sketch as a DXF file and offers it. Nothing in the part changes.
    func exportDXF(sketch id: FeatureID) {
        guard let solved = result?.sketches[id]?.solved else {
            alert = AlertInfo(title: "There's no sketch to export", message: "Fix the sketch's problems first, then export it.")
            return
        }
        guard solved.curves.contains(where: { !$0.construction }) else {
            alert = AlertInfo(title: "There's nothing to export", message: "\(featureName(id)) has no lines, arcs or curves. Construction lines are left out.")
            return
        }
        let url = shareURL("\(featureName(id)).dxf")
        do {
            try DXFExport.data(solved).write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            alert = AlertInfo(title: "The export failed", message: "\(error.localizedDescription)")
        }
    }

    /// Exports the bodies, or just the ones with these ids, as an STL, 3MF or STEP file and offers it. `name` is the file
    /// name used when the ids are a group (a folder) rather than one body.
    func export(bodies ids: [FeatureID]? = nil, name: String? = nil, format: ExportFormat) {
        let wanted = result?.bodies.filter { ids?.contains($0.id) ?? true } ?? []
        guard !wanted.isEmpty else {
            alert = name.map { AlertInfo(title: "There's nothing to export", message: "\($0) has no bodies in it.") }
                ?? AlertInfo(title: "There's nothing to export", message: "Create a body first, for example by extruding a sketch.")
            return
        }
        let partName = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let base = name ?? (ids == nil ? partName
            : (wanted.count == 1 ? bodies.first { $0.id == wanted[0].id }?.name : nil) ?? partName)
        let url = shareURL("\(base).\(format.fileExtension)")
        if write(wanted, format: format, to: url) { exportedFile = url }
    }

    /// Exports every body in a folder (and in the folders inside it) as one file.
    func export(folder id: String, format: ExportFormat) {
        guard let folder = document.folder(id) else { return }
        export(bodies: bodies(inFolder: id).map(\.id), name: folder.name, format: format)
    }
}
#endif

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

/// The pieces of a mold or a split, waiting for the person to say which format and whether one file or one each.
struct PiecesExportRequest: Identifiable {
    let id = UUID()
    /// The mold's or split's name: the file's name, or the folder's.
    let name: String
    /// "halves", "pieces": what the bodies are called in the sheet.
    let noun: String
    let bodies: [BodyResult]
}

extension DocumentModel {
    /// Writes the pieces the person chose to export: one file, or one for each piece, and offers them in the share sheet.
    func exportPieces(_ request: PiecesExportRequest, format: ExportFormat, individually: Bool) {
        piecesExport = nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var one: URL?
        var many: [URL] = []
        if individually && request.bodies.count > 1 {
            let written = writeIndividually(request.bodies, format: format, into: folder)
            if written.count == request.bodies.count { many = written }
        } else {
            let url = folder.appendingPathComponent("\(Self.safeFileName(request.name)).\(format.fileExtension)")
            if write(request.bodies, format: format, to: url) { one = url }
        }
        // The question's sheet is still going away: the share sheet comes up once it has.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            exportedFile = one
            exportedFiles = many
        }
    }

    /// Mold ▸ Export: asks what to write (see `PiecesExportSheet`).
    func exportMoldHalves() {
        guard let mold = activeMold, let built = moldResults[mold.id], built.isBuilt else {
            alert = AlertInfo(title: "There is nothing to export", message: "The mold has not been built. Fix what the Mold panel says first.")
            return
        }
        let placed = MoldBuilder.printLayout(built)
        guard placed.count == built.pieces.count else { return }
        piecesExport = PiecesExportRequest(name: mold.name, noun: mold.pieces == 4 ? "pieces" : "halves", bodies: placed)
    }

    /// Split ▸ Export: asks what to write (see `PiecesExportSheet`).
    func exportSplitPieces() {
        guard let split = activeSplit, let built = splitResults[split.id], built.isBuilt else {
            alert = AlertInfo(title: "There is nothing to export", message: "The split has not been built. Fix what the Split panel says first.")
            return
        }
        let placed = PrintSplitBuilder.printLayout(built).bodies
        guard !placed.isEmpty else { return }
        piecesExport = PiecesExportRequest(name: split.name, noun: "pieces", bodies: placed)
    }

    /// A file name that is safe to write: letters, digits, spaces and a few marks, no folders, never empty (as the Mac's `CADService.safeFileName`).
    static func safeFileName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.()"))
        let last = (text as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Part" : String(cleaned.prefix(80))
    }

    /// File names for these names in a folder: safe to write, different from each other and from what the folder already holds.
    static func exportFileURLs(for names: [String], extension ext: String, in folder: URL) -> [URL] {
        var taken = Set<String>()
        return names.map { name in
            let base = Self.safeFileName(name)
            var candidate = base
            var n = 2
            while taken.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(candidate).\(ext)").path) {
                candidate = "\(base) \(n)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return folder.appendingPathComponent("\(candidate).\(ext)")
        }
    }

    /// Writes each body to a file of its own in the folder, named after the body. Returns the files written; stops and alerts at the first failure.
    @discardableResult
    func writeIndividually(_ bodies: [BodyResult], format: ExportFormat, into folder: URL) -> [URL] {
        let urls = Self.exportFileURLs(for: bodies.map(\.name), extension: format.fileExtension, in: folder)
        var written: [URL] = []
        for (body, url) in zip(bodies, urls) {
            guard write([body], format: format, to: url) else { break }
            written.append(url)
        }
        return written
    }
}
#endif

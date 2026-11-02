// Files: export the bodies of a part to STL or STEP, and import a STEP or STL file as a body. Exports go to one folder, never over an
// existing file; imports read only STEP and STL files, by an absolute path the assistant was given.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation

struct ExportResult: Encodable, Equatable {
    var success = true
    var documentId: String
    var message: String
    /// Where the file is.
    var path: String
    var format: String
    var bytes: Int
    var bodies: [String]
}

extension CADService {
    /// Where exports are written: a folder in the user's Documents that SimplMaker makes.
    static var exportFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SimplMaker Exports", isDirectory: true)
    }

    /// A file name that is safe to write: letters, digits, spaces and a few marks, no folders, never empty.
    static func safeFileName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.()"))
        let last = (text as NSString).lastPathComponent  // never a folder, whatever came in
        let cleaned = String(last.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Part" : String(cleaned.prefix(80))
    }

    /// Writes bodies of a part to an STL, 3MF or STEP file in the exports folder. Nothing in the part changes.
    func exportFile(documentID: String?, bodyIDs: [String]?, format: String, fileName: String?, folder: URL? = nil) async throws -> ExportResult {
        guard let kind = ExportFormat(rawValue: format) else {
            throw AIError(.invalidArguments, "format \"\(format)\" is not stl, 3mf or step.", reason: "STL or 3MF for 3D printing, STEP for other CAD programs.")
        }
        let (docID, model) = try resolve(documentID)
        await model.rebuilt()
        let all = model.bodies
        guard !all.isEmpty else {
            throw AIError(.invalidArguments, "The part has no bodies to export.", reason: "Make a body first, for example by extruding a sketch.")
        }
        var chosen = all
        if let bodyIDs {
            guard !bodyIDs.isEmpty else { throw AIError(.invalidArguments, "bodies is empty.", reason: "Leave it out to export every body.") }
            for id in bodyIDs where !all.contains(where: { $0.id == id }) {
                throw AIError(.featureNotFound, "There is no body with the id \(id).", reason: "The bodies are: \(all.map(\.id).joined(separator: ", ")).")
            }
            chosen = all.filter { bodyIDs.contains($0.id) }
        }
        let directory = folder ?? Self.exportFolder
        let base = Self.safeFileName(fileName.map { ($0 as NSString).deletingPathExtension } ?? model.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            throw AIError(.invalidArguments, "The export folder could not be made: \(error.localizedDescription)")
        }
        var url = directory.appendingPathComponent("\(base).\(format)")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(base) \(n).\(format)"); n += 1 }  // never over an existing file
        let kernelBodies = chosen.map(\.body)
        let named = chosen.map { (name: $0.name, body: $0.body, color: model.document.bodyColors[$0.id]) }
        let target = url
        do {
            try await Task.detached(priority: .userInitiated) {
                switch kind {
                case .stl: try KBody.exportSTL(kernelBodies, to: target)
                case .step: try KBody.exportSTEP(kernelBodies, to: target)
                case .threeMF: try ThreeMF.write(named, to: target)
                }
            }.value
        } catch {
            throw AIError(.invalidArguments, "The export failed: \(error).", reason: "Check that the bodies are valid with get_body.")
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ExportResult(documentId: docID, message: "Exported \(chosen.count) bod\(chosen.count == 1 ? "y" : "ies") to \(url.path).",
                            path: url.path, format: format, bytes: size, bodies: chosen.map(\.id))
    }
}

struct ImportFileOperation: AIOperation {
    let path: String
    let name: String?
    let id: String?
    var toolName: String { "import_file" }
    var label: String { "Import \((path as NSString).lastPathComponent)" }
    var activity: String { "Importing \((path as NSString).lastPathComponent)" }
    static let maxBytes = 100_000_000

    func apply(to doc: inout CADDocument, context: OperationContext) throws -> OperationOutcome {
        try CADService.refuseRolledBack(doc)
        guard path.hasPrefix("/") else {
            throw AIError(.invalidArguments, "path must be an absolute path (it starts with /).", reason: "For example /Users/me/Downloads/bracket.step.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard ["step", "stp", "stl"].contains(url.pathExtension.lowercased()) else {
            throw AIError(.invalidArguments, "Only STEP (.step, .stp) and STL (.stl) files can be imported, not \"\(url.pathExtension)\".")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AIError(.invalidArguments, "There is no file at \(url.path).", reason: "Check the path; the file has to exist on this Mac.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0, size <= Self.maxBytes else {
            throw AIError(.invalidArguments, size == 0 ? "The file is empty." : "The file is too large (\(size / 1_000_000) MB; at most \(Self.maxBytes / 1_000_000) MB).")
        }
        guard let data = try? Data(contentsOf: url) else {
            throw AIError(.invalidArguments, "The file could not be read.", reason: "SimplMaker may not be allowed to read that folder.")
        }
        let featureID = try AIValues.newFeatureID(id, in: doc)
        let featureName = doc.nextName("Import")
        doc.addFeature(Feature(id: featureID, name: featureName, .importBody(ImportFeature(fileName: url.lastPathComponent, data: data))))
        doc.bodyNames[featureID] = name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? url.deletingPathExtension().lastPathComponent
        return OperationOutcome(featureID: featureID,
                                message: "Imported \(url.lastPathComponent) (\(size / 1000) kB) as the body \(featureID). An STL must be watertight and is read in millimetres.")
    }
}

// The Export dialog: file format and one part or many, for STEP and STL alike.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADKernel
import UniformTypeIdentifiers

/// What the Export dialog asks for.
struct ExportChoice: Equatable {
    enum Grouping: String { case onePart, individualParts }
    var format: ExportFormat
    var grouping: Grouping

    var fileExtension: String { format.fileExtension }

    private static let formatKey = "exportFormat"
    private static let groupingKey = "exportGrouping"

    /// What was chosen last time, or STL with one part the first time.
    static var remembered: ExportChoice {
        let defaults = UserDefaults.standard
        return ExportChoice(format: ExportFormat(rawValue: defaults.string(forKey: formatKey) ?? "") ?? .stl,
                            grouping: Grouping(rawValue: defaults.string(forKey: groupingKey) ?? "") ?? .onePart)
    }

    func remember() {
        UserDefaults.standard.set(format.rawValue, forKey: Self.formatKey)
        UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey)
    }
}

/// Gives the dialog's radio buttons an action, which is what makes them choose one at a time.
private final class RadioTarget: NSObject {
    @objc func chosen(_ sender: NSButton) {}
}

extension DocumentModel {
    /// File ▸ Export…: asks for a format and for one part or one part per body, then for where to write.
    func exportWithDialog() {
        let all = bodies
        guard !all.isEmpty else {
            alert = AlertInfo(title: "There's nothing to export", message: "Create a body first, for example by extruding a sketch.")
            return
        }
        guard let choice = exportChoice(all.count) else { return }
        choice.remember()
        switch choice.grouping {
        case .onePart:
            export(format: choice.format)
        case .individualParts:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose where to put the \(all.count) \(choice.fileExtension.uppercased()) files, one for each body."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let written = writeIndividually(all, format: choice.format, into: folder)
            if written.count == all.count { NSWorkspace.shared.activateFileViewerSelecting(written) }
        }
    }

    /// The Export dialog. Nil if the user cancels. With one body there is nothing to group, so that choice is disabled.
    static func askExportChoice(bodyCount: Int) -> ExportChoice? {
        let last = ExportChoice.remembered

        let alert = NSAlert()
        alert.messageText = "Export"
        alert.informativeText = "Choose a file format and how the bodies are put into files."

        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        let formats: [ExportFormat] = [.stl, .threeMF, .step]
        format.addItems(withTitles: ["STL · a mesh, for slicers and 3D printing",
                                     "3MF · a mesh with units and colours, for slicers",
                                     "STEP · exact shapes, for other CAD programs"])
        format.selectItem(at: formats.firstIndex(of: last.format) ?? 0)
        let formatRow = NSStackView(views: [NSTextField(labelWithString: "Format"), format])
        formatRow.spacing = 8

        let target = RadioTarget()
        let one = NSButton(radioButtonWithTitle: "All bodies as one single part", target: target, action: #selector(RadioTarget.chosen))
        let many = NSButton(radioButtonWithTitle: "All bodies as individual parts", target: target, action: #selector(RadioTarget.chosen))
        let individual = bodyCount > 1 && last.grouping == .individualParts
        one.state = individual ? .off : .on
        many.state = individual ? .on : .off
        let single = bodyCount == 1
        one.isEnabled = !single
        many.isEnabled = !single
        let note = NSTextField(labelWithString: single ? "The part has one body."
            : "Individual parts: one file for each of the \(bodyCount) bodies, in a folder you choose.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let column = NSStackView(views: [formatRow, one, many, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(14, after: formatRow)
        column.frame = NSRect(origin: .zero, size: column.fittingSize)
        alert.accessoryView = column
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return ExportChoice(format: formats[format.indexOfSelectedItem], grouping: many.state == .on ? .individualParts : .onePart)
    }

    /// File names for these names in a folder: safe to write, different from each other and from what the folder already holds.
    static func exportFileURLs(for names: [String], extension ext: String, in folder: URL) -> [URL] {
        let fm = FileManager.default
        var taken = Set<String>()
        return names.map { name in
            let base = CADService.safeFileName(name)
            var candidate = base
            var n = 2
            while taken.contains(candidate.lowercased()) || fm.fileExists(atPath: folder.appendingPathComponent("\(candidate).\(ext)").path) {
                candidate = "\(base) \(n)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return folder.appendingPathComponent("\(candidate).\(ext)")
        }
    }

    /// Writes each body to a file of its own in the folder, named after the body, never over a file already there.
    /// Returns the files written; it stops and alerts at the first failure.
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

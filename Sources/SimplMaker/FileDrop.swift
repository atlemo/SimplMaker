// Dropping files on the window: a STEP, STL, SVG or DXF file dragged from Finder is imported the same way as
// File ▸ Import does it.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The kinds of file the window takes by drop, and what each becomes.
enum DroppedFileKind {
    case model   // STEP or STL: a body of its own
    case drawing // SVG or DXF: a sketch

    static let modelExtensions = ["step", "stp", "stl"]
    static let drawingExtensions = ["svg", "dxf"]
    static let allExtensions = modelExtensions + drawingExtensions

    init?(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.modelExtensions.contains(ext) { self = .model }
        else if Self.drawingExtensions.contains(ext) { self = .drawing }
        else { return nil }
    }
}

extension DocumentModel {
    /// Imports the dropped files one after the other, each as File ▸ Import would. Files of other kinds are named
    /// in an alert; a drop with nothing importable in it does nothing else.
    func importDropped(_ urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let known = urls.filter { DroppedFileKind($0) != nil }
        let unknown = urls.filter { DroppedFileKind($0) == nil }
        if known.isEmpty {
            let names = unknown.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            alert = AlertInfo(title: unknown.count == 1 ? "\(names) can't be imported" : "Those files can't be imported",
                              message: "SimplMaker imports STEP (.step, .stp) and STL (.stl) files as bodies, and SVG and DXF files as sketches.")
            return
        }
        Task {
            for url in known {
                switch DroppedFileKind(url) {
                case .model?: await importSTEP(from: url)
                case .drawing?: await importSVG(from: url)
                case nil: break
                }
            }
        }
    }

    /// Reads the file URLs out of what was dropped, then imports them. True if there was anything to read.
    func importDropped(providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url { urls.append(url) }
            }
            importDropped(urls)
        }
        return true
    }
}

/// A frame round the window while files are dragged over it that can be imported.
struct FileDropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.xl2)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.06))
            .padding(4)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// The Export Image dialog: what the 3D view shows, as a PNG or JPEG picture, with a preview and (for PNG) a transparent background.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The picture file formats the view can be exported to.
enum PictureFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var type: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    /// Whether the format can leave pixels see-through.
    var hasAlpha: Bool { self == .png }
}

extension DocumentModel {
    /// File ▸ Export Image… (and the Render options' Export render): opens the dialog for the picture of the view as it is now.
    func exportImageWithDialog() {
        guard viewportView != nil else { return }
        showExportImage = true
    }

    /// The dialog's preview: the view as a PNG (see-through if asked), one frame of it.
    func previewImage(transparent: Bool) async -> NSImage? {
        guard let view = viewportView, let data = await view.exportImage(.png, transparent: transparent, frames: 1) else { return nil }
        return NSImage(data: data)
    }

    /// The pixel size of the picture an export makes.
    var exportImageSize: CGSize? { viewportView.map { $0.drawableSize } }

    /// Makes the picture, then asks where to put it. In the Render view the picture is made from several frames (its export quality).
    func exportImage(format: PictureFormat, transparent: Bool) {
        guard let view = viewportView else { return }
        let frames = renderView ? renderSettings.exportQuality.frames : 1
        Task { @MainActor [weak self] in
            let data = await view.exportImage(format, transparent: transparent, frames: frames)
            guard let self else { return }
            guard let data else {
                alert = AlertInfo(title: "The picture could not be saved", message: "The picture of the view could not be made. Try again.")
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.type]
            let name = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
            panel.nameFieldStringValue = name + (renderView ? " render." : " view.") + format.fileExtension
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch {
                alert = AlertInfo(title: "The picture could not be saved", message: "\(error.localizedDescription)")
            }
        }
    }
}

/// Grey and white squares, the usual way to show that a picture is see-through.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 1)))
            for row in 0..<Int((size.height / cell).rounded(.up)) {
                for column in 0..<Int((size.width / cell).rounded(.up)) where (row + column) % 2 == 1 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.84)))
                }
            }
        }
    }
}

struct ExportImageDialog: View {
    @Bindable var model: DocumentModel
    @AppStorage("exportImageFormat") private var formatName = PictureFormat.png.rawValue
    @AppStorage("exportImageTransparent") private var wantsTransparent = false
    @State private var preview: NSImage?

    private var format: PictureFormat { PictureFormat(rawValue: formatName) ?? .png }
    private var transparent: Bool { wantsTransparent && format.hasAlpha }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space6) {
            Text("Export Image")
                .font(.headline)
            ZStack {
                if transparent { Checkerboard() } else { Color(nsColor: .underPageBackgroundColor) }
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(.separator))
            .task(id: transparent) {
                guard let image = await model.previewImage(transparent: transparent) else { return }
                preview = image
            }

            Picker("Format", selection: $formatName) {
                ForEach(PictureFormat.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                Toggle("Transparent background", isOn: $wantsTransparent)
                    .disabled(!format.hasAlpha)
                Text(format.hasAlpha ? "Leaves out the background\(model.renderView ? ", the floor and its shadows" : " and the grid"): only the part is in the picture."
                     : "Only PNG can have a transparent background.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.renderView {
                HStack {
                    Text("Quality")
                    Spacer()
                    Picker("Quality", selection: $model.renderSettings.exportQuality) {
                        ForEach(RenderSettings.ExportQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .help("An exported render is made from several pictures, each a little to one side, and averaged: smooth edges, soft effects without grain. Standard is one picture; High is 16, Maximum 64.")
            }

            HStack {
                if let size = model.exportImageSize {
                    Text("\(Int(size.width)) × \(Int(size.height)) px")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.showExportImage = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    model.showExportImage = false
                    model.exportImage(format: format, transparent: transparent)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.windowMargin)
        .frame(width: 420)
    }
}

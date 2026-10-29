// The space-bar preview of a .simplmaker file in Finder: the PNG the app stored in the file when it saved.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Reads only the thumbnail out of the document, nothing else.
private struct Picture: Decodable { var thumbnail: Data? }

@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        guard let png = (try JSONDecoder().decode(Picture.self, from: data)).thumbnail,
              let image = NSImage(data: png), image.size.width > 0 else {
            throw CocoaError(.fileReadCorruptFile)  // no picture in the file: Quick Look shows its generic preview
        }
        return QLPreviewReply(dataOfContentType: .png, contentSize: image.size) { _ in png }
    }
}

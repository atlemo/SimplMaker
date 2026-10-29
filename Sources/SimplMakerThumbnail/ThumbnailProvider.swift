// Finder's icon and column-view picture for a .simplmaker file: the PNG the app stored in the file when it saved. A file
// without one (made before this, or an empty part) gets no picture, so Finder shows the document icon instead.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import QuickLookThumbnailing

/// Reads only the thumbnail out of the document, nothing else.
private struct Picture: Decodable { var thumbnail: Data? }

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let data = try? Data(contentsOf: request.fileURL),
              let png = (try? JSONDecoder().decode(Picture.self, from: data))?.thumbnail,
              let image = NSImage(data: png), image.size.width > 0, image.size.height > 0 else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        // Fit the picture in what was asked for, keeping its shape.
        let max = request.maximumSize
        let scale = min(max.width / image.size.width, max.height / image.size.height)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        var rect = CGRect(origin: .zero, size: image.size)
        guard let picture = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        handler(QLThumbnailReply(contextSize: size, drawing: { context in
            context.draw(picture, in: CGRect(origin: .zero, size: size))
            return true
        }), nil)
    }
}

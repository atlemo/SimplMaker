// The picture the iPad's file browser shows for a .simplmaker file: the PNG the app stored in the file when it saved. A file without
// one (an empty part, or made before this) gets the document icon instead.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import QuickLookThumbnailing
import UIKit

/// Reads only the thumbnail out of the document, nothing else.
private struct Picture: Decodable { var thumbnail: Data? }

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let data = try? Data(contentsOf: request.fileURL),
              let png = (try? JSONDecoder().decode(Picture.self, from: data))?.thumbnail,
              let image = UIImage(data: png), image.size.width > 0, image.size.height > 0 else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let max = request.maximumSize
        let scale = min(max.width / image.size.width, max.height / image.size.height)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        }), nil)
    }
}

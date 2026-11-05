// Turning BGRA pixels into a PNG or JPEG file. Shared by the Mac and the iPad app.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PictureFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var type: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    /// Whether the format can leave pixels see-through.
    var hasAlpha: Bool { self == .png }
}

enum PictureEncoder {
    /// Not on the main actor: the renderer calls it from the GPU's completion handler.
    nonisolated static func png(bgra: [UInt8], width: Int, height: Int) -> Data? {
        image(bgra: bgra, width: width, height: height, format: .png)
    }

    /// A picture file's data from BGRA bytes: opaque, or with the fourth byte as opacity (colours already multiplied by it).
    nonisolated static func image(bgra: [UInt8], width: Int, height: Int, format: PictureFormat, premultipliedAlpha: Bool = false) -> Data? {
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let alpha: CGImageAlphaInfo = premultipliedAlpha ? .premultipliedLast : .noneSkipLast
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

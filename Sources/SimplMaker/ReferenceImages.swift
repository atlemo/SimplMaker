// Reference images (Canvas): reading a picture, placing it on a plane or flat face, and what the
// viewport needs to draw it.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import ImageIO
import simd
import UniformTypeIdentifiers

enum ReferenceImage {
    /// Pictures bigger than this on a side are shown scaled down (the file itself is kept whole).
    static let maxTexturePixels = 4096

    /// The picture turned the way it is meant to be seen (camera orientation applied), and no bigger
    /// than `maxPixels` on a side. Nil if the data isn't an image.
    static func decode(_ data: Data, maxPixels: Int = maxTexturePixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The picture as 8-bit BGRA with colour multiplied by alpha, the way the shader blends it.
    static func premultipliedPixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }
}

extension DocumentModel {
    /// Asks for an image and puts it on a plane or face, centred at (u, v) in the plane's frame.
    /// False if nothing was added (the panel was cancelled, or the file isn't a picture).
    @discardableResult
    func insertImage(on plane: PlaneRef, at centre: SIMD2<Double>) -> Bool {
        guard let url = Self.chooseImage("Insert") else { return false }
        return insertImage(from: url, on: plane, at: centre)
    }

    /// Sketch mode's Canvas: asks for an image and puts it on the sketch's own plane, centred on the sketch's
    /// origin, to trace over. The sketch stays open, and the Canvas goes just before it in the timeline. False if nothing was added.
    @discardableResult
    func insertImageInSketch() -> Bool {
        guard let session = sketchSession,
              case .sketch(let sf)? = document.features.first(where: { $0.id == session.featureID })?.kind,
              let url = Self.chooseImage("Insert") else { return false }
        return insertImage(from: url, on: sf.plane, at: .zero, keepingSketch: true)
    }

    @discardableResult
    func insertImage(from url: URL, on plane: PlaneRef, at centre: SIMD2<Double>, keepingSketch: Bool = false) -> Bool {
        guard let (data, pixels) = loadImage(url) else { return false }
        if sketchSession != nil, !keepingSketch { finishSketch() }
        let id = IDs.make()
        let aspect = Double(pixels.height) / Double(pixels.width)
        // Wide pictures get the default size across, tall ones down.
        let width = formatDimension(defaultCanvasSize / max(aspect, 1), kind: .length)
        let feature = Feature(id: id, name: document.nextName("Canvas"), .image(ImageFeature(
            plane: plane, fileName: url.lastPathComponent, data: data, pixelWidth: pixels.width, pixelHeight: pixels.height,
            u: formatDimension(centre.x, kind: .length), v: formatDimension(centre.y, kind: .length), width: width)))
        // While a sketch is open the model shows as it was at that sketch, so a Canvas to trace over goes just
        // before it (it only needs the plane, which the sketch itself needs first).
        let sketchID = keepingSketch ? sketchSession?.featureID : nil
        mutate("Insert \(url.lastPathComponent)") { doc in
            guard let sketchID, let i = doc.index(of: sketchID) else { return doc.insertAtMarker(feature) }
            doc.features.insert(feature, at: i)
            if let r = doc.rollback, r > i { doc.rollback = r + 1 }
        }
        pendingTool = nil
        // The sketch stays the thing being worked on; the new Canvas is in the browser to select.
        if !keepingSketch {
            selection = []
            selectedFeature = id
        }
        return true
    }

    /// Asks for another picture for a Canvas, keeping its place and size across (the height follows
    /// the new picture's proportions).
    func replaceImage(_ id: FeatureID) {
        guard let url = Self.chooseImage("Replace") else { return }
        replaceImage(id, from: url)
    }

    @discardableResult
    func replaceImage(_ id: FeatureID, from url: URL) -> Bool {
        guard let (data, pixels) = loadImage(url) else { return false }
        updateFeature(id, "Replace \(url.lastPathComponent)") { f in
            guard case .image(var i) = f.kind else { return }
            i.fileName = url.lastPathComponent
            i.data = data
            i.pixelWidth = pixels.width
            i.pixelHeight = pixels.height
            f.kind = .image(i)
        }
        return true
    }

    /// Sets how see-through a Canvas is. `final: false` while a slider is dragged: the view follows
    /// but no undo step is made until it is let go (and then `final: true`).
    func setImageOpacity(_ id: FeatureID, _ opacity: Double, final: Bool = true) {
        let value = min(max(opacity, 0), 1)
        let change: (inout Feature) -> Void = { f in
            guard case .image(var i) = f.kind else { return }
            i.opacity = value
            f.kind = .image(i)
        }
        if final { updateFeature(id, "Change Opacity", change) } else { setPresentation(id, change) }
    }

    /// The pictures drawn in the viewport: every visible Canvas that was placed by the last rebuild.
    func imageDraws() -> [ImageDraw] {
        document.features.compactMap { f -> ImageDraw? in
            guard case .image(let image) = f.kind, !document.hidden.contains(f.id), let placement = result?.images[f.id] else { return nil }
            return ImageDraw(id: f.id, data: image.data,
                             corners: placement.corners.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) },
                             opacity: Float(image.opacity))
        }
    }

    /// The height a Canvas ends up with, for showing ("" while it can't be built).
    func imageHeightText(_ image: ImageFeature) -> String {
        guard let w = try? parameterValues.value(of: image.width, kind: .length) else { return "" }
        return formatDimension(w * image.aspect, kind: .length)
    }

    /// The outline of the selected Canvas, so it can be seen against the model.
    func imageBorder() -> [SegmentInstance] {
        guard let id = selectedFeature, !document.hidden.contains(id), let placement = result?.images[id] else { return [] }
        let c = placement.corners.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
        return (0..<4).map { i in
            let a = c[i], b = c[(i + 1) % 4]
            return SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: 0)
        }
    }

    /// A size across for a new picture: about the size of the model, or 100 mm without one.
    private var defaultCanvasSize: Double {
        guard let b = sceneBounds else { return 100 }
        let extent = Double(simd_reduce_max(b.max - b.min))
        let nice = [25.0, 50, 100, 150, 200, 250, 500, 1000].min { abs($0 - extent) < abs($1 - extent) } ?? 100
        return nice
    }

    private static func chooseImage(_ prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = prompt
        panel.message = "Choose a reference image (PNG, JPEG, HEIC, TIFF…)."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The file's contents and the picture's size, or an alert saying why not.
    private func loadImage(_ url: URL) -> (Data, (width: Int, height: Int))? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            alert = AlertInfo(title: "\(url.lastPathComponent) couldn't be read", message: error.localizedDescription)
            return nil
        }
        guard let image = ReferenceImage.decode(data) else {
            alert = AlertInfo(title: "\(url.lastPathComponent) isn't an image SimplMaker can show",
                              message: "Choose a PNG, JPEG, HEIC or TIFF file.")
            return nil
        }
        return (data, (image.width, image.height))
    }
}

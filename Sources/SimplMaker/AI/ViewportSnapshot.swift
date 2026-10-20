// A picture of the part as an assistant can look at it: the app's own renderer, in a window nobody sees, from a named direction,
// framed to fit, with the red/green/blue axes through the origin to tell which way is which. It has its own renderer, so the
// user's own view (camera, selection, hover) is not touched.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import simd

enum SnapshotDirection: String, CaseIterable, Sendable {
    case iso, front, back, left, right, top, bottom

    /// The camera's turn about Z and tilt above the XY plane, in radians (the same as the view cube's).
    var angles: (yaw: Float, pitch: Float) {
        switch self {
        case .iso: return (-.pi / 3, 0.55)
        case .front: return (-.pi / 2, 0)
        case .back: return (.pi / 2, 0)
        case .right: return (0, 0)
        case .left: return (.pi, 0)
        case .top: return (-.pi / 2, 1.55)
        case .bottom: return (-.pi / 2, -1.55)
        }
    }

    /// Which way the picture runs, in words an assistant can use.
    var orientation: String {
        switch self {
        case .iso: return "Seen from the front-right and above: +X runs toward you and to the right (down-right in the picture), +Y away from you and to the right (up-right), +Z up."
        case .front: return "Seen from the front (from -Y, looking toward +Y): +X to the right, +Z up."
        case .back: return "Seen from the back (from +Y, looking toward -Y): +X to the left, +Z up."
        case .right: return "Seen from the right (from +X, looking toward -X): +Y to the right, +Z up."
        case .left: return "Seen from the left (from -X, looking toward +X): +Y to the left, +Z up."
        case .top: return "Seen from above (looking down -Z): +X to the right, +Y up the picture."
        case .bottom: return "Seen from below (looking up +Z): +X to the right, +Y down the picture."
        }
    }
}

struct SnapshotImage: Sendable {
    var png: Data
    var width: Int
    var height: Int
    /// For a section: where it cut and which side was cut away, in words.
    var section: String?
}

/// A cut through the bodies, as the Section Analysis tool makes: everything on one side of a plane square to an axis is cut away.
struct SnapshotSection: Sendable {
    /// 0 = X, 1 = Y, 2 = Z.
    var axis: Int
    /// Where along the axis (mm); nil = the middle of what is shown.
    var offset: Double?
    /// Cut away the side with the higher values along the axis; nil = the side that faces the camera, so the cut face is seen.
    var cutPositive: Bool?
    static let axisNames = ["x", "y", "z"]
}

/// What to show besides the whole part.
struct SnapshotOptions: Sendable {
    /// Only these bodies (hidden ones too); nil = every visible body.
    var only: [String]?
    /// Finished sketches to draw as lines, hidden or not.
    var sketches: [FeatureID] = []
    var section: SnapshotSection?
    /// Draw the ground grid too (pictures for an assistant don't; the tests of how the grid meets the bodies do).
    var grid = false
    /// A perspective camera instead of the orthographic one (for the tests too).
    var perspective = false
}

@MainActor
enum ViewportSnapshot {
    /// One renderer for all pictures (building its pipelines is the slow part). It is the pictures' own: the user's views have theirs.
    private static var shared: Renderer?

    /// One picture at a time: they share the renderer, and a second one starting while the first waits for its frames (it does, to
    /// let the GPU finish) would replace the first one's scene.
    private static var running = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    private static func acquire() async {
        if running { await withCheckedContinuation { waiters.append($0) } } else { running = true }
    }
    private static func release() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }  // handed straight on: running stays true
    }

    /// The corners of the box round some meshes and the points of some sketches, in the part's coordinates.
    private static func bounds(of meshes: [BodyMesh], sketches: [SketchResult]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        for m in meshes {
            let p = m.mesh.positions
            for i in stride(from: 0, to: p.count, by: 3) {
                let v = SIMD3(p[i], p[i + 1], p[i + 2])
                lo = simd_min(lo, v); hi = simd_max(hi, v); any = true
            }
        }
        for r in sketches {
            for point in r.solved.points {
                let w = r.frame.origin + point.x * r.frame.xAxis + point.y * r.frame.yAxis
                let v = SIMD3(Float(w.x), Float(w.y), Float(w.z))
                lo = simd_min(lo, v); hi = simd_max(hi, v); any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    static func render(_ model: DocumentModel, direction: SnapshotDirection, azimuth: Double? = nil, elevation: Double? = nil,
                       width: Int = 1024, height: Int = 768, axes: Bool = true, options: SnapshotOptions = SnapshotOptions()) async throws -> SnapshotImage {
        await acquire()
        defer { release() }
        let meshes: [BodyMesh]
        if let only = options.only {
            meshes = model.meshes.filter { only.contains($0.id) }
            if let missing = only.first(where: { id in !model.meshes.contains { $0.id == id } }) {
                throw AIError(.featureNotFound, "only: \"\(missing)\" is not a body of the part.", reason: "The bodies are: \(model.meshes.map(\.id).joined(separator: ", ")).")
            }
        } else {
            meshes = model.visibleMeshes
        }
        var sketchResults: [SketchResult] = []
        for id in options.sketches {
            guard let r = model.result?.sketches[id] else {
                throw AIError(.featureNotFound, "sketches: \"\(id)\" is not a sketch that built.", reason: "Take sketch ids from get_document; get_feature shows whether one failed.")
            }
            sketchResults.append(r)
        }
        guard let bounds = bounds(of: meshes, sketches: sketchResults) else {
            throw AIError(.invalidArguments, "There is nothing to show: the part has no visible bodies.", reason: "Make a body first, or ask the user to show a hidden one (set_body), or name it in only.")
        }
        guard let renderer = shared ?? Renderer() else {
            throw AIError(.invalidArguments, "A picture could not be made: this Mac has no usable graphics device.")
        }
        shared = renderer

        let (view, window) = offscreenView(width: width, height: height, renderer: renderer)

        renderer.setScene(meshes)
        var overlay = SketchOverlay()
        for (slot, r) in sketchResults.enumerated() { SketchOverlayBuilder.finished(r, slot: slot + 1, parameters: model.parameterValues, into: &overlay) }
        renderer.setOverlay(overlay)
        renderer.palette = .make(dark: false, increaseContrast: false)
        let background = renderer.palette.background
        view.clearColor = MTLClearColor(red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
        renderer.showGrid = options.grid
        renderer.showAxes = axes
        renderer.visualStyle = .standard
        renderer.printPreview = false
        renderer.renderSettings = nil
        renderer.sectionPlane = nil
        var sectionNote: String?
        renderer.hovered = 0
        renderer.selected = []
        renderer.wholeBodies = false
        renderer.bodyColors = meshes.map { m in
            model.displayColor(of: m.id).map { c -> SIMD4<Float> in
                let (r, g, b) = c.components
                return SIMD4(Float(r), Float(g), Float(b), 1)
            }
        }
        var camera = Camera()
        camera.orthographic = !options.perspective
        let angles = direction.angles
        camera.yaw = azimuth.map { Float($0 * .pi / 180) } ?? angles.yaw
        camera.pitch = elevation.map { min(max(Float($0 * .pi / 180), -1.55), 1.55) } ?? angles.pitch
        camera.fit(min: bounds.min, max: bounds.max, aspect: Float(width) / Float(height))
        renderer.camera = camera
        if let cut = options.section {
            let lo = Double([bounds.min.x, bounds.min.y, bounds.min.z][cut.axis]), hi = Double([bounds.max.x, bounds.max.y, bounds.max.z][cut.axis])
            let offset = cut.offset ?? (lo + hi) / 2
            // The cut face is seen when the side cut away faces the viewer: the plane's normal points toward the camera.
            let towardCamera = -[camera.forward.x, camera.forward.y, camera.forward.z][cut.axis]
            let positive = cut.cutPositive ?? (towardCamera >= 0)
            var normal = SIMD3<Float>(repeating: 0)
            normal[cut.axis] = positive ? 1 : -1
            renderer.sectionPlane = SIMD4(normal, Float(offset) * (positive ? 1 : -1))
            sectionNote = "Cut at \(SnapshotSection.axisNames[cut.axis]) = \(AIValues.number(offset)) mm (the part runs \(AIValues.number(lo)) to \(AIValues.number(hi))); the \(positive ? "higher" : "lower") \(SnapshotSection.axisNames[cut.axis]) side is cut away."
        }
        defer { renderer.setScene([]); renderer.sectionPlane = nil }  // the GPU buffers are not kept between pictures

        // The first frames of a new view may still be settling: draw until two in a row agree.
        var previous: [UInt8] = []
        var pixels: [UInt8] = []
        var size = (width: 0, height: 0)
        var wrongSize: (width: Int, height: Int)?
        for attempt in 0..<12 {
            view.draw(view.bounds)
            renderer.waitForGPU()
            // A frame of another size is not the picture asked for (two of them in a row would look settled): draw again.
            guard let texture = view.currentDrawable?.texture else {
                try await Task.sleep(for: .milliseconds(40))
                continue
            }
            guard texture.width == width, texture.height == height else {
                wrongSize = (texture.width, texture.height)
                pin(view, width: width, height: height)
                try await Task.sleep(for: .milliseconds(40))
                continue
            }
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            pixels = bytes
            size = (texture.width, texture.height)
            // Two frames that agree end it, unless they are blank (a frame drawn before the scene reached the GPU is just background).
            if bytes == previous && !Self.isBlank(bytes) { break }
            previous = bytes
            if attempt < 11 { try await Task.sleep(for: .milliseconds(40)) }
        }
        withExtendedLifetime(window) {}
        if pixels.isEmpty, let wrong = wrongSize {
            throw AIError(.invalidArguments, "The picture could not be drawn at \(width) × \(height) pixels (it kept coming out \(wrong.width) × \(wrong.height)).",
                          reason: "Try again; if it keeps failing the graphics device may be busy.")
        }
        guard !pixels.isEmpty, size.width > 0, !isBlank(pixels) else {
            throw AIError(.invalidArguments, "The picture could not be drawn.", reason: "Try again; if it keeps failing the graphics device may be busy.")
        }
        guard let png = Self.png(bgra: pixels, width: size.width, height: size.height) else {
            throw AIError(.invalidArguments, "The picture could not be saved as an image.")
        }
        return SnapshotImage(png: png, width: size.width, height: size.height, section: sectionNote)
    }

    /// A view of `width` × `height` pixels in a window nobody sees, for one picture.
    static func offscreenView(width: Int, height: Int, renderer: Renderer) -> (ViewportMTKView, NSWindow) {
        // A scale of 1 or 2 points per pixel makes no difference to the picture, so the window's own is used and the size is pinned.
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: max(width / 2, 1), height: max(height / 2, 1)), device: renderer.device)
        view.renderer = renderer
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        pin(view, width: width, height: height)
        return (view, window)
    }

    /// Pins the view's drawables to `width` × `height` pixels. Its layer takes the window's scale only on a later pass of the
    /// run loop and then sizes its drawables by its own size and scale, so until then (or after, on a screen of another scale)
    /// a frame can come at half or double the pixels asked for. Given the scale the pixel size implies, it stays as asked.
    private static func pin(_ view: MTKView, width: Int, height: Int) {
        let pixels = CGSize(width: width, height: height)
        view.layer?.contentsScale = CGFloat(width) / max(view.bounds.width, 1)
        (view.layer as? CAMetalLayer)?.drawableSize = pixels
        view.drawableSize = pixels
    }

    /// Every pixel is the colour of the first one (nothing was drawn).
    static func isBlank(_ bgra: [UInt8]) -> Bool {
        guard bgra.count >= 8 else { return true }
        let (b, g, r) = (bgra[0], bgra[1], bgra[2])
        var i = 4
        while i + 2 < bgra.count {
            if bgra[i] != b || bgra[i + 1] != g || bgra[i + 2] != r { return false }
            i += 4
        }
        return true
    }

    static func png(bgra: [UInt8], width: Int, height: Int) -> Data? {
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

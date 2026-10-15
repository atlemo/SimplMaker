// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd
@testable import SimplMaker

/// The section analysis as drawn: the cut face shows only where the cut is, and the rest of the model is untouched.
/// Set SECTION_DUMP_DIR to also write each picture there as a PNG.
@Suite @MainActor struct SectionRenderTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 60 × 40 × 30 mm box shelled open at the top (2 mm walls), and a solid cylinder beside it.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "sh", name: "Shell1", .shell(ShellFeature(body: "a", faces: [FaceRef(body: "a", face: "a.top")]))),
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "90 mm", height: "30", diameter: "20"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    struct Picture {
        var width: Int, height: Int
        var bgra: [UInt8]
        func color(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]))
        }
        /// How much of the square around (x, y), `radius` pixels out, is the cut face (pink), 0...1.
        func cutShare(_ x: Int, _ y: Int, radius: Int = 6) -> Double {
            var cut = 0, all = 0
            for j in max(0, y - radius)...min(height - 1, y + radius) {
                for i in max(0, x - radius)...min(width - 1, x + radius) {
                    let c = color(i, j)
                    if c.r > 150 && c.b > 130 && c.g < c.r - 20 && c.g < c.b - 15 { cut += 1 }
                    all += 1
                }
            }
            return Double(cut) / Double(all)
        }
    }

    private func render(_ model: DocumentModel, name: String, style: VisualStyle = .standard, print: Bool = false,
                        orthographic: Bool = true, yaw: Float = -.pi / 3, pitch: Float = 0.55) async throws -> (Picture, Renderer, ViewportMTKView) {
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 560), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.framebufferOnly = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        renderer.setScene(model.visibleMeshes)
        renderer.showGrid = false
        renderer.showAxes = false
        renderer.visualStyle = style
        renderer.printPreview = print
        renderer.sectionPlane = model.sectionClip
        renderer.camera.orthographic = orthographic
        renderer.camera.target = SIMD3(45, 20, 15)
        renderer.camera.distance = 260
        renderer.camera.yaw = yaw
        renderer.camera.pitch = pitch
        renderer.setOverlay(model.sketchOverlay())

        var picture = Picture(width: 0, height: 0, bgra: [])
        var last: [UInt8] = []
        for _ in 0..<40 {
            view.draw(view.bounds)
            try await Task.sleep(for: .milliseconds(100))
            guard let texture = view.fullSizeTexture else { continue }
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            picture = Picture(width: texture.width, height: texture.height, bgra: bytes)
            if bytes == last { break }
            last = bytes
        }
        try #require(picture.width > 0, "no frame came at the view's full size")
        if let dir = ProcessInfo.processInfo.environment["SECTION_DUMP_DIR"] { try dump(picture, to: dir + "/\(name).png") }
        withExtendedLifetime(window) {}
        return (picture, renderer, view)
    }

    private func dump(_ p: Picture, to path: String) throws {
        var rgba = p.bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = URL(fileURLWithPath: path)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Pink (the cut face) has red and blue well above green.
    private func isCutFace(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 150 && c.b > 130 && c.g < c.r - 20 && c.g < c.b - 15 }

    @Test func theCutFaceShowsOnlyWhereThePlaneCutsAndNotOnTheWholeModel() async throws {
        let model = try await loaded()
        let bounds = try #require(model.sceneBounds)
        // Cut the box across its middle: the YZ plane at x = 30, the half beyond it (toward the viewer's right) cut away.
        model.clickRay = (SIMD3(100, 0, 100), simd_normalize(SIMD3(-1, 0.3, -1)))
        model.beginSection(.origin(.yz), title: "YZ plane")
        model.setSectionOffset(Double(bounds.min.x) + 30)
        let (picture, renderer, view) = try await render(model, name: "yz")

        func share(_ p: SIMD3<Float>, radius: Int = 4) -> Double {
            let q = renderer.camera.project(p, viewSize: view.bounds.size)!
            let scale = CGFloat(picture.width) / view.bounds.width
            return picture.cutShare(Int(q.x * scale), Int(q.y * scale), radius: radius)
        }
        let cut = model.sectionClip!
        let clipX = cut.w / cut.x
        // On the cut: the box's two walls are cut (1 mm into each), the cavity between them is not.
        #expect(share(SIMD3(clipX, bounds.min.y + 1, 15), radius: 2) > 0.3, "a cut wall is the cut face")
        #expect(share(SIMD3(clipX, bounds.min.y + 20, 15), radius: 12) < 0.02, "the hollow of the box is not")
        // What is left of the box, and a body the plane doesn't touch, are shaded as before.
        #expect(share(SIMD3(clipX - 20, bounds.min.y + 20, 30), radius: 8) < 0.02, "the part that is left")
        #expect(share(SIMD3(90, bounds.min.y + 20, 30), radius: 8) < 0.02, "a body the plane doesn't touch")
        // Nowhere but along the cut: the picture holds only a thin line of it, not the whole model.
        let total = picture.cutShare(picture.width / 2, picture.height / 2, radius: min(picture.width, picture.height) / 2 - 1)
        #expect(total < 0.02, "the cut face is a small part of the picture: \(total)")
    }

    @Test func aSolidBodyIsFilledAndTheModelBehindItStaysHidden() async throws {
        let model = try await loaded()
        // Cut the cylinder (centre x = 90) through its middle.
        model.clickRay = (SIMD3(100, 0, 100), simd_normalize(SIMD3(-1, 0.3, -1)))
        model.beginSection(.origin(.yz), title: "YZ plane")
        model.setSectionOffset(90 - Double(try #require(model.sceneBounds).min.x) * 0)
        let (picture, renderer, view) = try await render(model, name: "cylinder")
        let cut = model.sectionClip!
        let q = renderer.camera.project(SIMD3(cut.w / cut.x, 0, 15), viewSize: view.bounds.size)!
        let scale = CGFloat(picture.width) / view.bounds.width
        #expect(picture.cutShare(Int(q.x * scale), Int(q.y * scale), radius: 12) > 0.5, "the middle of the cut cylinder is filled")
    }

    @Test func theCutFaceIsRightInPerspectiveToo() async throws {
        let model = try await loaded()
        let bounds = try #require(model.sceneBounds)
        model.clickRay = (SIMD3(100, 0, 100), simd_normalize(SIMD3(-1, 0.3, -1)))
        model.beginSection(.origin(.yz), title: "YZ plane")
        model.setSectionOffset(Double(bounds.min.x) + 30)
        let (picture, renderer, view) = try await render(model, name: "perspective-cut", orthographic: false)
        let cut = model.sectionClip!
        let clipX = cut.w / cut.x
        let scale = CGFloat(picture.width) / view.bounds.width
        func share(_ p: SIMD3<Float>, radius: Int) -> Double {
            let q = renderer.camera.project(p, viewSize: view.bounds.size)!
            return picture.cutShare(Int(q.x * scale), Int(q.y * scale), radius: radius)
        }
        #expect(share(SIMD3(clipX, bounds.min.y + 1, 15), radius: 2) > 0.3, "a cut wall is the cut face")
        #expect(share(SIMD3(clipX, bounds.min.y + 20, 15), radius: 12) < 0.02, "the hollow is not")
        let total = picture.cutShare(picture.width / 2, picture.height / 2, radius: min(picture.width, picture.height) / 2 - 1)
        #expect(total < 0.02, "a thin line of it, not the whole model: \(total)")
    }

    @Test func otherStylesAndPerspectiveStillDraw() async throws {
        let model = try await loaded()
        model.clickRay = (SIMD3(100, 0, 100), simd_normalize(SIMD3(-1, 0.3, -1)))
        model.beginSection(.origin(.yz), title: "YZ plane")
        model.setSectionOffset(30)
        for (name, style, print, ortho) in [("perspective", VisualStyle.standard, false, false), ("print", .standard, true, true),
                                            ("wire", .wireframe, false, true), ("hidden", .shadedWithHiddenEdges, false, true)] {
            let (picture, _, _) = try await render(model, name: name, style: style, print: print, orthographic: ortho)
            #expect(picture.width > 0 && picture.bgra.contains { $0 != 0 }, Comment(rawValue: name))
        }
    }
}

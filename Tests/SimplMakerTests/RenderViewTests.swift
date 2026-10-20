// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd
@testable import SimplMaker

/// The Render view as drawn: a solid floor in place of the grid, and a light that stays where it is set.
/// Set RENDER_DUMP_DIR to also write each picture there as a PNG.
@Suite @MainActor struct RenderViewTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 60 × 40 × 30 mm box standing on the floor, and a cylinder beside it.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "90 mm", height: "30", diameter: "20"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    struct Picture {
        var width: Int, height: Int
        var bgra: [UInt8]
        func color(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3(Float(bgra[i + 2]), Float(bgra[i + 1]), Float(bgra[i])) / 255
        }
    }

    private func render(_ model: DocumentModel, name: String, settings: RenderSettings?, grid: Bool = true,
                        yaw: Float = -.pi / 3, pitch: Float = 0.55, orthographic: Bool = true) async throws -> (Picture, Renderer, ViewportMTKView) {
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
        renderer.showGrid = grid
        renderer.showAxes = grid
        renderer.renderSettings = settings
        renderer.sceneBounds = model.sceneBounds
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
            if bytes == last && !ViewportSnapshot.isBlank(bytes) { break }
            last = bytes
        }
        try #require(picture.width > 0, "no frame came at the view's full size")
        if let dir = ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"] { try dump(picture, to: dir + "/\(name).png") }
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
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Where a point of the scene lands in the picture, in its pixels.
    private func pixel(of p: SIMD3<Float>, _ picture: Picture, _ renderer: Renderer, _ view: ViewportMTKView) -> (x: Int, y: Int) {
        let q = renderer.camera.project(p, viewSize: view.bounds.size)!
        let scale = CGFloat(picture.width) / view.bounds.width
        return (Int(q.x * scale), Int(q.y * scale))
    }

    @Test func theFloorReplacesTheGridAndTheBackdropIsTheFloorsOwnColour() async throws {
        let model = try await loaded()
        var settings = RenderSettings()
        settings.floor = .white
        let (picture, renderer, view) = try await render(model, name: "studio", settings: settings)
        // A spot of floor well away from the bodies, where the grid used to have its lines, is the floor's lit colour, everywhere the same.
        let a = pixel(of: SIMD3(-10, 80, 0), picture, renderer, view), b = pixel(of: SIMD3(-10, 83, 0), picture, renderer, view)
        let floorA = picture.color(a.x, a.y), floorB = picture.color(b.x, b.y)
        #expect(simd_distance(floorA, floorB) < 0.01, "no grid line crosses the floor")
        #expect(abs(floorA.x - settings.floorColor.x) < 0.04, "the floor is the colour the settings give: \(floorA) vs \(settings.floorColor)")
        // The corner of the picture is floor fading into the backdrop: between the two.
        let corner = picture.color(2, 2)
        #expect(corner.x > settings.backdropColor.x - 0.04 && corner.x < settings.floorColor.x + 0.04, "the backdrop: \(corner)")
    }

    @Test func withoutRenderSettingsTheViewIsAsItWas() async throws {
        let model = try await loaded()
        let (plain, _, _) = try await render(model, name: "plain", settings: nil)
        let (rendered, _, _) = try await render(model, name: "plain-rendered", settings: RenderSettings())
        #expect(abs(plain.color(2, 2).x - rendered.color(2, 2).x) > 0.3, "the usual background, not the floor")
    }

    @Test func theLightStaysWhereItIsSetWhenTheViewTurns() async throws {
        let model = try await loaded()
        var settings = RenderSettings()
        settings.direction = 0     // from the +X side
        settings.height = 20
        settings.brightness = 1.2
        settings.ambient = 0.2
        let lo = try #require(model.sceneBounds).min  // the box's near-bottom corner on the floor
        // Seen from two directions, the box's +X wall is the lit one both times (the highlight on it moves with the view).
        func wallBrightness(yaw: Float) async throws -> (lit: Float, dark: Float) {
            let (picture, renderer, view) = try await render(model, name: "light-\(Int(yaw * 100))", settings: settings, yaw: yaw, pitch: 0.25)
            let lit = pixel(of: SIMD3(lo.x + 60, lo.y + 20, 15), picture, renderer, view)    // the +X wall
            let dark = pixel(of: SIMD3(lo.x + 30, lo.y, 15), picture, renderer, view)    // the -Y wall, which both views see too
            return (picture.color(lit.x, lit.y).x, picture.color(dark.x, dark.y).x)
        }
        let a = try await wallBrightness(yaw: -.pi / 3)
        let b = try await wallBrightness(yaw: -.pi / 6)
        #expect(a.lit > a.dark + 0.1, "the wall toward the light is brighter: \(a)")
        #expect(b.lit > b.dark + 0.1, "and from another side too: \(b)")
    }

    @Test func theRenderViewIsOffInSketchAndExclusiveWithThePrintPreview() async throws {
        let model = try await loaded()
        model.setRenderView(true)
        #expect(model.renderView && model.showRenderOptions)
        model.setPrintPreview(true)
        #expect(!model.renderView && model.printPreview)
        model.setRenderView(true)
        #expect(model.renderView && !model.printPreview)
        model.visualStyle = .wireframe
        model.setRenderView(true)
        #expect(model.visualStyle.isShaded, "the render view needs a shaded style")
    }

    @Test func thePresetsSetTheLight() {
        var s = RenderSettings()
        s.apply(.dramatic)
        #expect(s.brightness > RenderSettings().brightness && s.ambient < RenderSettings().ambient)
        s.apply(.studio)
        #expect(s == RenderSettings())
    }
}

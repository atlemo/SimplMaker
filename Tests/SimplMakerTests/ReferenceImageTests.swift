// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import Foundation
import ImageIO
import Metal
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import SimplMaker

/// Insert ▸ Canvas: placing a reference image on a plane or face, and what the viewport is given to draw.
@Suite @MainActor struct ReferenceImageTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A PNG of the given size, red on the left half and transparent on the right.
    private func pngFile(_ name: String, width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func decodesToPremultipliedPixels() throws {
        let data = try Data(contentsOf: try pngFile("a.png", width: 8, height: 4))
        let image = try #require(ReferenceImage.decode(data))
        #expect(image.width == 8 && image.height == 4)
        let pixels = try #require(ReferenceImage.premultipliedPixels(image))
        // BGRA: the left half is solid red, the right half has no colour and no alpha.
        #expect(Array(pixels.bytes[0..<4]) == [0, 0, 255, 255])
        #expect(Array(pixels.bytes[(7 * 4)..<(8 * 4)]) == [0, 0, 0, 0])
    }

    @Test func insertingWhileSketchingKeepsTheSketchOpenAndUsesItsPlane() async throws {
        let model = DocumentModel()
        try await settle(model)
        model.beginSketch(on: .xz)
        try await settle(model)
        let sketchID = try #require(model.sketchSession?.featureID)
        let url = try pngFile("Side view.png", width: 100, height: 100)
        let plane = try #require(model.sketchSession.flatMap { _ in PlaneRef.xz })
        #expect(model.insertImage(from: url, on: plane, at: .zero, keepingSketch: true))
        try await settle(model)
        #expect(model.sketchSession?.featureID == sketchID, "the sketch stays open")
        #expect(model.selectedFeature == sketchID)
        let features = model.document.features
        #expect(features.last?.id == sketchID, "the canvas goes before the sketch, which is still last")
        guard case .image(let i)? = features.dropLast().last?.kind else { Issue.record("expected a canvas"); return }
        #expect(i.plane == .xz)
        #expect(model.imageDraws().count == 1, "errors: \(String(describing: model.result?.errors))")
    }

    @Test func insertingOnAPlaneAddsACanvasAndDrawsIt() async throws {
        let model = DocumentModel()
        try await settle(model)
        let url = try pngFile("Floor plan.png", width: 200, height: 100)
        #expect(model.insertImage(from: url, on: .xy, at: .zero))
        try await settle(model)
        let f = try #require(model.document.features.last)
        guard case .image(let i) = f.kind else { Issue.record("expected a canvas"); return }
        #expect(f.name == "Canvas1" && i.fileName == "Floor plan.png" && i.opacity == 0.5)
        #expect(i.pixelWidth == 200 && i.pixelHeight == 100 && model.selectedFeature == f.id)
        #expect(model.result?.errors.isEmpty == true)
        let draws = model.imageDraws()
        #expect(draws.count == 1 && draws[0].corners.count == 4 && draws[0].opacity == 0.5)
        #expect(model.imageFeatures.map(\.id) == [f.id])
    }

    @Test func aFileThatIsNotAnImageIsRefused() async throws {
        let model = DocumentModel()
        try await settle(model)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.png")
        try Data("not a picture".utf8).write(to: url)
        #expect(!model.insertImage(from: url, on: .xy, at: .zero))
        #expect(model.document.features.isEmpty && model.alert != nil)
    }

    @Test func opacityChangesWithoutRebuildingAndCanBeUndone() async throws {
        let model = DocumentModel()
        try await settle(model)
        #expect(model.insertImage(from: try pngFile("a.png", width: 20, height: 20), on: .xy, at: .zero))
        try await settle(model)
        let id = try #require(model.selectedFeature)
        let before = model.sceneRevision
        model.setImageOpacity(id, 0.8, final: false)  // dragging the slider
        #expect(model.imageDraws().first?.opacity == 0.8)
        model.setImageOpacity(id, 0.25)
        #expect(model.imageDraws().first?.opacity == 0.25)
        #expect(!model.isRegenerating)
        #expect(model.sceneRevision > before)
    }

    @Test func hiddenAndSuppressedCanvasesAreNotDrawn() async throws {
        let model = DocumentModel()
        try await settle(model)
        #expect(model.insertImage(from: try pngFile("a.png", width: 20, height: 10), on: .xy, at: .zero))
        try await settle(model)
        let id = try #require(model.selectedFeature)
        model.setHidden([id], true)
        #expect(model.imageDraws().isEmpty)
        model.setHidden([id], false)
        #expect(model.imageDraws().count == 1)
        model.updateFeature(id, "Suppress") { $0.suppressed = true }
        try await settle(model)
        #expect(model.imageDraws().isEmpty)
    }

    @Test func replacingThePictureKeepsItsPlaceAndFollowsItsProportions() async throws {
        let model = DocumentModel()
        try await settle(model)
        #expect(model.insertImage(from: try pngFile("a.png", width: 200, height: 100), on: .xy, at: SIMD2(5, 5)))
        try await settle(model)
        let id = try #require(model.selectedFeature)
        #expect(model.replaceImage(id, from: try pngFile("b.png", width: 100, height: 100)))
        try await settle(model)
        guard case .image(let i)? = model.document.features.first?.kind else { Issue.record("expected a canvas"); return }
        #expect(i.fileName == "b.png" && i.aspect == 1 && i.u == "5 mm")
        let height = try #require(model.result?.images[id]).height
        let width = try #require(model.result?.images[id]).width
        #expect(abs(height - width) < 1e-9)
    }

    @Test func theToolWaitsForAPlaneOrFaceBeforeAskingForTheImage() {
        #expect(DesignTool.canvas.needsPlane && DesignTool.canvas.accepts(.plane) && DesignTool.canvas.accepts(.face))
        #expect(!DesignTool.canvas.accepts(.edge))
        #expect(DesignTool.construct.contains(.canvas))
    }
}

/// What the viewport actually puts on screen for a Canvas.
@Suite @MainActor struct ReferenceImageRenderTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A solid red PNG.
    private func redPNG() throws -> URL {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The colour (r, g, b) on screen at the model-space point, looking straight down.
    private func screenColor(_ view: ViewportMTKView, _ renderer: Renderer, _ world: SIMD3<Float>) async throws -> (Int, Int, Int) {
        view.framebufferOnly = false
        let scale = view.window?.backingScaleFactor ?? 2
        let p = try #require(renderer.camera.project(world, viewSize: view.bounds.size))
        // The GPU finishes after draw returns (and slower when tests run side by side): read until it settles.
        var last: [UInt8]?
        var pixel = [UInt8](repeating: 0, count: 4)
        for _ in 0..<40 {
            view.draw(view.bounds)
            try await Task.sleep(for: .milliseconds(100))
            guard let texture = view.fullSizeTexture else { continue }
            texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(Int(p.x * scale), Int(p.y * scale), 1, 1), mipmapLevel: 0)
            if pixel == last && pixel[3] != 0 { break }  // (a drawable not drawn into yet is clear; a drawn one is opaque)
            last = pixel
        }
        try #require(last != nil, "no frame came at the view's full size")
        return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))  // BGRA
    }

    @Test func aCanvasIsBlendedOverTheBackgroundAtItsOpacity() async throws {
        let model = DocumentModel(document: CADDocument())
        try await settle(model)
        #expect(model.insertImage(from: try redPNG(), on: .xy, at: .zero))  // 100 mm wide, centred on the origin
        try await settle(model)
        let id = try #require(model.selectedFeature)
        model.selectedFeature = nil

        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        renderer.showGrid = false
        renderer.showAxes = false
        renderer.camera.setStandard(.top)
        renderer.camera.target = .zero
        renderer.camera.distance = 400

        model.setImageOpacity(id, 1)
        renderer.setOverlay(model.sketchOverlay())
        let solid = try await screenColor(view, renderer, SIMD3(10, 10, 0))
        #expect(solid.0 > 240 && solid.1 < 15 && solid.2 < 15, "fully opaque: plain red, got \(solid)")

        model.setImageOpacity(id, 0.5)
        renderer.setOverlay(model.sketchOverlay())
        let half = try await screenColor(view, renderer, SIMD3(10, 10, 0))

        model.setImageOpacity(id, 0)
        renderer.setOverlay(model.sketchOverlay())
        let none = try await screenColor(view, renderer, SIMD3(10, 10, 0))
        #expect(abs(none.0 - none.1) < 20 && abs(none.1 - none.2) < 20, "fully see-through: just the background, got \(none)")
        // Half way between the picture and the background, whichever the background is (it follows light/dark mode).
        #expect(abs(half.0 - (solid.0 + none.0) / 2) < 12 && abs(half.1 - (solid.1 + none.1) / 2) < 12
                && abs(half.2 - (solid.2 + none.2) / 2) < 12, "half: red mixed with the background \(none), got \(half)")

        // Outside the picture there's only the background.
        model.setImageOpacity(id, 1)
        renderer.setOverlay(model.sketchOverlay())
        let outside = try await screenColor(view, renderer, SIMD3(120, 10, 0))
        #expect(abs(outside.0 - outside.2) < 20, "outside the picture: background, got \(outside)")
    }
}

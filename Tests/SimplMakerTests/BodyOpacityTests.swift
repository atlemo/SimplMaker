// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CADCore
import Foundation
import Testing
import simd
@testable import SimplMaker

/// The Appearance panel's Opacity: a see-through body shows what is behind it, and the choice is saved and undone.
@Suite @MainActor struct BodyOpacityTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A 60 × 60 × 4 slab 20 mm above a 20 × 20 × 10 block, seen from straight above: the slab hides the block.
    private func loaded() async throws -> DocumentModel {
        var d = CADDocument()
        d.features = [
            Feature(id: "block", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "10 mm"))),
            Feature(id: "slab", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "60 mm", height: "4 mm"))),
            Feature(id: "lift", name: "Move1", .move(MoveFeature(bodies: ["slab"], dz: "20 mm"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        return model
    }

    /// The colour at the middle of the block's top, seen from above, with the slab's opacity as given.
    private func blockColor(_ model: DocumentModel, slabOpacity: Float, grid: Bool = false, spread: UnsafeMutablePointer<Float>? = nil) async throws -> SIMD3<Float> {
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 600, height: 420), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.framebufferOnly = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let meshes = model.visibleMeshes
        let slab = try #require(meshes.firstIndex { $0.id == "slab" }), block = meshes.firstIndex { $0.id == "block" } ?? -1
        renderer.setScene(meshes)
        renderer.showGrid = grid
        renderer.showAxes = false
        renderer.bodyColors = meshes.indices.map { $0 == block ? SIMD4(1, 0, 0, 1) : SIMD4(0.2, 0.2, 0.9, 1) }
        renderer.bodyOpacity = meshes.indices.map { $0 == slab ? slabOpacity : 1 }
        renderer.sceneBounds = model.sceneBounds
        renderer.camera.orthographic = true
        renderer.camera.target = SIMD3(0, 0, 10)
        renderer.camera.distance = 200
        renderer.camera.yaw = 0
        renderer.camera.pitch = 1.55  // from above
        renderer.setOverlay(model.sketchOverlay())
        var color = SIMD3<Float>.zero
        var last: [UInt8] = []
        for _ in 0..<40 {
            view.draw(view.bounds)
            try await Task.sleep(for: .milliseconds(100))
            guard let texture = view.fullSizeTexture else { continue }
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            let q = try #require(renderer.camera.project(SIMD3(0, 0, 10), viewSize: view.bounds.size))
            let scale = CGFloat(texture.width) / view.bounds.width
            let i = (Int(q.y * scale) * texture.width + Int(q.x * scale)) * 4
            color = SIMD3(Float(bytes[i + 2]), Float(bytes[i + 1]), Float(bytes[i])) / 255
            if let spread {  // how much the picture varies along a short row through that point: the grid lines
                let row = (-25...25).map { Float(bytes[i + $0 * 4 + 1]) / 255 }
                spread.pointee = (row.max() ?? 0) - (row.min() ?? 0)
            }
            if bytes == last && !ViewportSnapshot.isBlank(bytes) { break }
            last = bytes
        }
        // Set RENDER_DUMP_DIR to also write the picture there, to look at it.
        if let dir = ProcessInfo.processInfo.environment["RENDER_DUMP_DIR"], let texture = view.fullSizeTexture {
            var rgba = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&rgba, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
            if let provider = CGDataProvider(data: Data(rgba) as CFData),
               let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texture.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
               let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/opacity-\(Int(slabOpacity * 100)).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        withExtendedLifetime(window) {}
        return color
    }

    @Test func aSeeThroughSlabShowsTheBlockBehindIt() async throws {
        let model = try await loaded()
        let solid = try await blockColor(model, slabOpacity: 1)
        let faint = try await blockColor(model, slabOpacity: 0.3)
        #expect(solid.z > solid.x + 0.2, "a solid blue slab hides the red block: \(solid)")
        #expect(faint.x > solid.x + 0.15, "the red block shows through the faint slab: \(faint) vs \(solid)")
    }

    @Test func theChoiceIsSavedUndoneAndLimited() async throws {
        let model = try await loaded()
        let undo = UndoManager()
        undo.groupsByEvent = false  // without a run loop every change would land in one undo step
        model.undoManager = undo
        func step(_ change: () -> Void) { undo.beginUndoGrouping(); change(); undo.endUndoGrouping() }
        #expect(model.displayOpacity(of: "slab") == 1)
        model.previewBodyOpacity(0.4, of: ["slab"])
        #expect(model.displayOpacity(of: "slab") == 0.4 && model.document.bodyOpacity.isEmpty, "a preview changes nothing saved")
        step { model.setBodyOpacity(0.4, of: ["slab"]) }
        #expect(model.document.bodyOpacity["slab"] == 0.4 && model.displayOpacity(of: "slab") == 0.4)
        let back = try CADDocument.decode(try model.document.encoded())
        #expect(back.bodyOpacity["slab"] == 0.4)
        step { model.setBodyOpacity(0, of: ["block"]) }
        #expect(model.document.bodyOpacity["block"] == DocumentModel.minimumOpacity, "never fully gone: it could not be picked")
        step { model.setBodyOpacity(1, of: ["slab"]) }
        #expect(model.document.bodyOpacity["slab"] == nil, "solid is the default and is not stored")
        undo.undo()
        #expect(model.document.bodyOpacity["slab"] == 0.4)
    }

    @Test func nothingIsOutlinedWhileTheSliderIsDragged() async throws {
        let model = try await loaded()
        model.selection = [PickID(body: 1, face: 0)]
        #expect(!model.highlighted.isEmpty, "a selected body is outlined")
        model.previewBodyOpacity(0.5, of: ["slab"])
        #expect(model.highlighted.isEmpty, "the outline is hidden while the opacity is previewed")
        model.setBodyOpacity(0.5, of: ["slab"])
        #expect(!model.highlighted.isEmpty, "and comes back when the slider is let go")
    }

    /// The ground grid under a slab shows through by what the opacity leaves: a body at 97 % lets a little through, not all of it.
    @Test func theGridShowsThroughByWhatTheOpacityLeaves() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "slab", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "60 mm", height: "4 mm")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        var solid: Float = 0, nearly: Float = 0, half: Float = 0
        _ = try await blockColor(model, slabOpacity: 1, grid: true, spread: &solid)
        _ = try await blockColor(model, slabOpacity: 0.97, grid: true, spread: &nearly)
        _ = try await blockColor(model, slabOpacity: 0.5, grid: true, spread: &half)
        #expect(half > nearly * 4, "half see-through shows far more of the grid than 97 %: \(half) vs \(nearly)")
        #expect(nearly < half * 0.2 + 0.005, "97 % shows only a faint grid: \(nearly) vs half \(half)")
        #expect(solid <= nearly + 0.003, "a solid slab hides the grid: \(solid)")
    }
}

// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Lines drawn only to be seen (the grid, axes, previews) must not hide what's picked beneath them:
/// hovering a sketch plane across a grid line used to flicker between the plane and nothing.
@Suite @MainActor struct PickThroughGridTests {
    @Test func aGridLineOverAPlaneStillPicksThePlane() async throws {
        let model = DocumentModel(document: CADDocument())
        for _ in 0..<400 where model.result == nil || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        model.startSketch()  // shows the origin planes
        #expect(model.showsOriginPlanes)

        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        renderer.showGrid = true
        renderer.setOverlay(model.sketchOverlay())
        renderer.camera.setStandard(.top)
        renderer.camera.target = SIMD3(12, 12, 0)
        renderer.camera.distance = 80

        var picked: UInt32?
        renderer.onPick = { id, _ in picked = id }
        func pick(_ world: SIMD3<Float>) async throws -> UInt32? {
            picked = nil
            let scale = window.backingScaleFactor
            let p = try #require(renderer.camera.project(world, viewSize: view.bounds.size))
            renderer.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
            view.draw(view.bounds)
            for _ in 0..<200 where picked == nil { try await Task.sleep(for: .milliseconds(5)) }
            return picked
        }

        let onGridLine = try await pick(SIMD3(10, 5, 0))   // the grid has a line every 10 mm
        let betweenLines = try await pick(SIMD3(15, 5, 0))
        #expect(betweenLines == OriginPlane.xy.pickID.raw)
        #expect(onGridLine == OriginPlane.xy.pickID.raw, "the grid line must not hide the plane from picking")
        model.cancelSketchPlanePick()
    }
}

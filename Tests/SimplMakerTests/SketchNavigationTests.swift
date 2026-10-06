// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import Testing
@testable import SimplMaker

/// The mouse moves the view in sketch mode as in Design mode: left-drag on empty space orbits, right-drag pans.
@Suite @MainActor struct SketchNavigationTests {
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func sketchView() async throws -> (ViewportMTKView, Renderer, NSWindow) {
        let model = DocumentModel(document: CADDocument())
        for _ in 0..<400 where model.result == nil || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        model.beginSketch(on: .xy)
        renderer.camera.look(along: SIMD3(0, 0, 1), at: SIMD3(200, 200, 0))  // the click lands on empty ground
        return (view, renderer, window)
    }

    @Test func draggingEmptyGroundWithTheSelectToolOrbitsTheView() async throws {
        let (view, renderer, window) = try await sketchView()
        let yaw = renderer.camera.yaw, pitch = renderer.camera.pitch
        view.mouseDown(with: event(.leftMouseDown, 400, 300, window))
        view.mouseDragged(with: event(.leftMouseDragged, 300, 250, window))
        #expect(renderer.camera.yaw != yaw && renderer.camera.pitch != pitch, "the view turns, as outside a sketch")
    }

    @Test func rightDragPansTheViewWithTheCursor() async throws {
        let (view, renderer, window) = try await sketchView()
        let yaw = renderer.camera.yaw, pitch = renderer.camera.pitch
        let size = view.bounds.size
        let top = SIMD3<Float>(200, 260, 0), bottom = SIMD3<Float>(200, 140, 0)  // above and below the middle of the view
        let t0 = try #require(renderer.camera.project(top, viewSize: size)), b0 = try #require(renderer.camera.project(bottom, viewSize: size))

        view.rightMouseDown(with: event(.rightMouseDown, 400, 300, window))
        view.rightMouseDragged(with: event(.rightMouseDragged, 300, 250, window))  // 100 left, 50 down (window y is up)

        let t1 = try #require(renderer.camera.project(top, viewSize: size)), b1 = try #require(renderer.camera.project(bottom, viewSize: size))
        #expect(abs((t1.x - t0.x) + 100) < 0.01 && abs((b1.x - b0.x) + 100) < 0.01, "everything moves left with the pointer")
        #expect(abs((t1.y - t0.y) - 50) < 0.01 && abs((b1.y - b0.y) - 50) < 0.01, "and down with it")
        #expect(renderer.camera.yaw == yaw && renderer.camera.pitch == pitch, "without turning")
    }

    @Test func outsideASketchTheLeftDragStillOrbits() async throws {
        let model = DocumentModel(document: CADDocument())
        for _ in 0..<400 where model.result == nil || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let yaw = renderer.camera.yaw
        view.mouseDown(with: event(.leftMouseDown, 400, 300, window))
        view.mouseDragged(with: event(.leftMouseDragged, 300, 300, window))
        #expect(renderer.camera.yaw != yaw)
    }
}

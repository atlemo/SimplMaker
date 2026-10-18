// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import simd
import Testing
@testable import SimplMaker

/// The mouse moves the view in sketch mode as in Design mode: left-drag on empty space orbits, right-drag pans.
@Suite @MainActor struct SketchNavigationTests {
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ window: NSWindow,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0,
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

    @Test func optionDragTurnsTheSketchOnItsPaperWithoutTippingIt() async throws {
        let (view, renderer, window) = try await sketchView()
        let yaw = renderer.camera.yaw, pitch = renderer.camera.pitch, target = renderer.camera.target
        // The pointer goes a quarter turn counter-clockwise round the middle (400, 300): from the right of it to above it.
        view.mouseDown(with: event(.leftMouseDown, 600, 300, window, flags: .option))
        view.mouseDragged(with: event(.leftMouseDragged, 400, 500, window, flags: .option))
        #expect(abs(renderer.camera.roll - .pi / 2) < 1e-4, "\(renderer.camera.roll)")
        #expect(renderer.camera.yaw == yaw && renderer.camera.pitch == pitch && renderer.camera.target == target)
        // What was along the sketch's x axis now runs up the screen.
        let size = view.bounds.size
        let o = try #require(renderer.camera.project(SIMD3(200, 200, 0), viewSize: size))
        let x = try #require(renderer.camera.project(SIMD3(300, 200, 0), viewSize: size))
        #expect(abs(x.x - o.x) < 0.01 && x.y < o.y - 1)
    }

    @Test func shiftOptionDragLandsOnRoundAngles() async throws {
        let (view, renderer, window) = try await sketchView()
        let step = ViewportMTKView.rollSnap
        view.mouseDown(with: event(.leftMouseDown, 600, 300, window, flags: [.option, .shift]))
        // About 20° counter-clockwise round (400, 300): 200 points out, 73 up.
        view.mouseDragged(with: event(.leftMouseDragged, 400 + 200 * cos(0.35), 300 + 200 * sin(0.35), window, flags: [.option, .shift]))
        #expect(abs(renderer.camera.roll - step) < 1e-4, "\(renderer.camera.roll) is the nearest 15°, step \(step)")
        // Two more degrees: still short of halfway to the next, so it stays; the movement isn't lost.
        view.mouseDragged(with: event(.leftMouseDragged, 400 + 200 * cos(0.38), 300 + 200 * sin(0.38), window, flags: [.option, .shift]))
        #expect(abs(renderer.camera.roll - step) < 1e-4)
        view.mouseDragged(with: event(.leftMouseDragged, 400 + 200 * cos(0.5), 300 + 200 * sin(0.5), window, flags: [.option, .shift]))
        #expect(abs(renderer.camera.roll - 2 * step) < 1e-4)
        view.mouseUp(with: event(.leftMouseUp, 400, 300, window))
    }

    @Test func rollingAlsoLeavesTheSketchPointedAtTheRightPlace() async throws {
        let (view, renderer, window) = try await sketchView()
        renderer.camera.roll(by: 0.7)
        // A point in the sketch plane still projects, and the ray back through it hits that point.
        let size = view.bounds.size
        let world = SIMD3<Float>(230, 170, 0)
        let p = try #require(renderer.camera.project(world, viewSize: size))
        let ray = renderer.camera.ray(at: p, viewSize: size)
        let t = -ray.origin.z / ray.direction.z
        let hit = ray.origin + t * ray.direction
        #expect(simd_length(hit - world) < 0.01)
        _ = window
    }

    @Test func optionDragOutsideASketchDoesNothing() async throws {
        let model = DocumentModel(document: CADDocument())
        for _ in 0..<400 where model.result == nil || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let pose = renderer.camera.pose
        view.mouseDown(with: event(.leftMouseDown, 600, 300, window, flags: .option))
        view.mouseDragged(with: event(.leftMouseDragged, 400, 500, window, flags: .option))
        #expect(renderer.camera.pose == pose, "Z stays up in a 3D view")
    }
}

/// The view cube offers two curved arrows while sketching, each turning the sketch a quarter.
@Suite @MainActor struct SketchTurnButtonTests {
    @Test func theArrowsShowOnlyWhileSketchingAndTurnTheWayTheyPoint() {
        let cube = ViewCubeView(frame: NSRect(origin: .zero, size: ViewCubeView.size))
        var turns: [Int] = []
        cube.turn = { turns.append($0) }
        let arrows = cube.turnButtons
        #expect(arrows.count == 2 && arrows.allSatisfy { $0.isHidden })
        cube.offersTurning = true
        #expect(arrows.allSatisfy { !$0.isHidden })
        for b in arrows { b.performClick(nil) }
        #expect(turns == [1, -1], "counter-clockwise first")
        cube.offersTurning = false
        #expect(arrows.allSatisfy { $0.isHidden })
    }

    @Test func anArrowChangesLookWhileHovered() {
        let cube = ViewCubeView(frame: NSRect(origin: .zero, size: ViewCubeView.size))
        let window = NSWindow(contentRect: cube.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = cube
        cube.offersTurning = true
        func move(to p: NSPoint) {
            cube.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: cube.convert(p, to: nil), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 0, pressure: 0)!)
        }
        func bytes(_ b: NSButton) -> Data { b.image!.tiffRepresentation! }
        let before = cube.turnButtons.map(bytes)
        move(to: NSPoint(x: cube.turnButtons[0].frame.midX, y: cube.turnButtons[0].frame.midY))
        #expect(bytes(cube.turnButtons[0]) != before[0] && bytes(cube.turnButtons[1]) == before[1], "only the hovered arrow changes")
        move(to: NSPoint(x: 1, y: 1))
        #expect(cube.turnButtons.map(bytes) == before, "back to normal when the pointer leaves")
    }
}

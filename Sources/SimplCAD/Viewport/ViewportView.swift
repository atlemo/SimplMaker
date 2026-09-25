// The 3D viewport: an MTKView subclass for input, wrapped for SwiftUI.
//
// Navigation (see README):
//   trackpad: two-finger scroll = orbit, ⇧ + scroll = pan, pinch = zoom
//   mouse:    left-drag = orbit, right/middle-drag = pan, wheel = zoom
//   click = select face/edge (⇧/⌘ to add), Esc = clear selection
//
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MetalKit
import SwiftUI

final class ViewportMTKView: MTKView {
    var renderer: Renderer?
    var onHover: ((PickID?) -> Void)?
    var onClick: ((PickID?, _ additive: Bool) -> Void)?
    var onClearSelection: (() -> Void)?

    private var lastDrag: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }  // origin top-left, like the ID texture

    override func draw(_ dirtyRect: NSRect) { renderer?.draw(in: self) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self))
    }

    private func requestPick(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)  // flipped: origin top-left, like the ID texture
        let scale = window?.backingScaleFactor ?? 2
        renderer?.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
        needsDisplay = true
    }

    func pickResult(_ raw: UInt32) {
        guard let renderer, renderer.hovered != raw else { return }
        renderer.hovered = raw
        onHover?(raw == 0 ? nil : PickID(raw: raw))
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { requestPick(event) }
    override func mouseExited(with event: NSEvent) { pickResult(0) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = convert(event.locationInWindow, from: nil)
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) { drag(event) { self.renderer?.camera.orbit(dx: $0, dy: $1) } }
    override func mouseUp(with event: NSEvent) {
        if !dragged, let renderer {
            let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            onClick?(renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered), additive)
        }
        lastDrag = nil
    }

    override func rightMouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil); dragged = false }
    override func rightMouseDragged(with event: NSEvent) { drag(event, pan) }
    override func otherMouseDown(with event: NSEvent) { lastDrag = convert(event.locationInWindow, from: nil); dragged = false }
    override func otherMouseDragged(with event: NSEvent) { drag(event, pan) }

    private func pan(_ dx: Float, _ dy: Float) {
        renderer?.camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
    }

    private func drag(_ event: NSEvent, _ apply: (Float, Float) -> Void) {
        let p = convert(event.locationInWindow, from: nil)
        guard let last = lastDrag else { lastDrag = p; return }
        let dx = Float(p.x - last.x), dy = Float(p.y - last.y)
        if abs(dx) + abs(dy) > 0 { dragged = true }
        apply(dx, -dy)  // view is flipped: screen-up is negative y
        lastDrag = p
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        if event.hasPreciseScrollingDeltas {  // trackpad
            let dx = Float(event.scrollingDeltaX), dy = Float(event.scrollingDeltaY)
            if event.modifierFlags.contains(.shift) {
                renderer.camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
            } else {
                renderer.camera.orbit(dx: -dx, dy: dy)
            }
        } else {
            renderer.camera.zoom(pow(1.1, Float(-event.scrollingDeltaY)))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(Float(1 / (1 + event.magnification)))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClearSelection?() } else { super.keyDown(with: event) }  // Esc
    }
}

/// SwiftUI wrapper. `sceneRevision` and `selection` are passed in so SwiftUI calls
/// updateNSView exactly when the geometry or selection changes.
struct ViewportView: NSViewRepresentable {
    let model: DocumentModel
    let sceneRevision: Int
    let selection: [PickID]
    let fitRevision: Int

    final class Coordinator {
        var sceneRevision = -1
        var fitRevision = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ViewportMTKView {
        let view = ViewportMTKView(frame: .zero, device: nil)
        guard let renderer = Renderer() else { return view }
        view.device = renderer.device
        view.renderer = renderer
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.clearColor = MTLClearColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        renderer.onPick = { [weak view] raw in view?.pickResult(raw) }
        view.onHover = { [model] id in model.hover(id) }
        view.onClick = { [model] id, additive in model.click(id, additive: additive) }
        view.onClearSelection = { [model] in model.clearSelection() }
        return view
    }

    func updateNSView(_ view: ViewportMTKView, context: Context) {
        guard let renderer = view.renderer else { return }
        if context.coordinator.sceneRevision != sceneRevision {
            context.coordinator.sceneRevision = sceneRevision
            renderer.setScene(model.meshes)
            renderer.hovered = 0
        }
        if context.coordinator.fitRevision != fitRevision, let b = model.sceneBounds {
            context.coordinator.fitRevision = fitRevision
            renderer.camera.fit(min: b.min, max: b.max)
        }
        renderer.selected = selection.map(\.raw)
        view.needsDisplay = true
    }
}

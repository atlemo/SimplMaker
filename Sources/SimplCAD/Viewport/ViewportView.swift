// The 3D viewport: an MTKView subclass for input, wrapped for SwiftUI.
//
// Navigation (see README):
//   trackpad: two-finger scroll = orbit, ⇧ + scroll = pan, pinch = zoom
//   mouse:    left-drag on empty space = orbit, right/middle-drag = pan, wheel = zoom
//   click = select face/edge/profile (⇧/⌘ to add), Esc = clear selection
// In sketch mode, clicks go to the active sketch tool; see SketchSession.
//
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import MetalKit
import SwiftUI

final class ViewportMTKView: MTKView {
    var renderer: Renderer?
    weak var model: DocumentModel?

    private var lastDrag: NSPoint?
    private var lastPoint: NSPoint?
    private var dragged = false
    private var sketchDrag = false
    private var labels: [EntityID: DimensionLabelView] = [:]

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }  // origin top-left, like the ID texture

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self)
        updateLabels()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self))
    }

    // MARK: picking and sketch-plane coordinates

    private func location(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    private func requestPick(at p: NSPoint) {
        let scale = window?.backingScaleFactor ?? 2
        renderer?.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
        needsDisplay = true
    }

    func pickResult(_ raw: UInt32) {
        guard let renderer, renderer.hovered != raw else { return }
        renderer.hovered = raw
        model?.hover(raw == 0 ? nil : PickID(raw: raw))
        if model?.sketchSession != nil { sketchEvent(.moved, at: nil, additive: false) }
        needsDisplay = true
    }

    /// Cursor position on the active sketch plane, in sketch (u, v) coordinates.
    private func sketchUV(_ p: NSPoint) -> SIMD2<Double>? {
        guard let renderer, let frame = model?.sketchSession?.frame else { return nil }
        let ray = renderer.camera.ray(at: p, viewSize: bounds.size)
        let o = SIMD3<Double>(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
        let d = SIMD3<Double>(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z))
        let n = frame.normal
        let denom = (d * n).sum()
        guard abs(denom) > 1e-9 else { return nil }
        let t = ((frame.origin - o) * n).sum() / denom
        let hit = o + t * d - frame.origin
        return SIMD2((hit * frame.xAxis).sum(), (hit * frame.yAxis).sum())
    }

    @discardableResult
    private func sketchEvent(_ phase: SketchMouse.Phase, at p: NSPoint?, additive: Bool) -> Bool {
        guard let model, let renderer else { return false }
        let point = p ?? lastPoint
        let hovered = renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered)
        let handled = model.sketchMouse(SketchMouse(phase: phase, uv: point.flatMap { sketchUV($0) },
                                                    pick: hovered, additive: additive))
        refreshOverlay()
        return handled
    }

    // MARK: mouse

    override func mouseMoved(with event: NSEvent) {
        let p = location(event)
        lastPoint = p
        requestPick(at: p)
        if model?.sketchSession != nil { sketchEvent(.moved, at: p, additive: false) }
    }

    override func mouseExited(with event: NSEvent) { pickResult(0) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = location(event)
        lastDrag = p
        dragged = false
        sketchDrag = false
        if model?.sketchSession != nil {
            let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
            sketchDrag = sketchEvent(.down, at: p, additive: additive)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if sketchDrag {
            let p = location(event)
            lastPoint = p
            sketchEvent(.dragged, at: p, additive: false)
            return
        }
        drag(event) { self.renderer?.camera.orbit(dx: $0, dy: $1) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { lastDrag = nil; sketchDrag = false }
        if sketchDrag {
            sketchEvent(.up, at: location(event), additive: false)
            return
        }
        guard !dragged, let renderer, let model, model.sketchSession == nil else { return }
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        model.click(renderer.hovered == 0 ? nil : PickID(raw: renderer.hovered), additive: additive)
        refreshOverlay()
    }

    override func rightMouseDown(with event: NSEvent) { lastDrag = location(event); dragged = false }
    override func rightMouseDragged(with event: NSEvent) { drag(event, pan) }
    override func otherMouseDown(with event: NSEvent) { lastDrag = location(event); dragged = false }
    override func otherMouseDragged(with event: NSEvent) { drag(event, pan) }

    private func pan(_ dx: Float, _ dy: Float) {
        renderer?.camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
    }

    private func drag(_ event: NSEvent, _ apply: (Float, Float) -> Void) {
        let p = location(event)
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

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let plainKey = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if let session = model.sketchSession, plainKey {
            switch event.keyCode {
            case 53: session.escape(); refreshOverlay(); return                                      // Esc
            case 51, 117: model.sketchCommand { $0.deleteSelection() }; refreshOverlay(); return     // ⌫ ⌦
            case 36, 76: model.finishSketch(); return                                                 // Return
            default: break
            }
            if let key = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = SketchTool.allCases.first(where: { $0.key == key }) {
                model.setSketchTool(tool)
                refreshOverlay()
                return
            }
        } else if event.keyCode == 53 {
            model.clearSelection()
            refreshOverlay()
            return
        }
        super.keyDown(with: event)
    }

    func refreshOverlay() {
        guard let renderer, let model else { return }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = model.highlighted
        needsDisplay = true
    }

    // MARK: dimension labels

    private func updateLabels() {
        guard let renderer, let model else { return }
        let wanted = model.dimensionLabels()
        let ids = Set(wanted.map(\.id))
        for (id, view) in labels where !ids.contains(id) {
            view.removeFromSuperview()
            labels[id] = nil
        }
        for l in wanted {
            let view: DimensionLabelView
            if let existing = labels[l.id] {
                view = existing
            } else {
                view = DimensionLabelView(frame: .zero)
                let id = l.id
                view.onClick = { [weak model] in model?.sketchSession?.editingDimension = id }
                addSubview(view)
                labels[l.id] = view
            }
            view.stringValue = l.text
            view.isEditingHighlight = l.editing
            view.sizeToFit()
            if let p = renderer.camera.project(l.world, viewSize: bounds.size) {
                view.isHidden = false
                view.setFrameOrigin(NSPoint(x: p.x - view.frame.width / 2, y: p.y - view.frame.height / 2))
            } else {
                view.isHidden = true
            }
        }
    }
}

/// A small clickable value label for a sketch dimension.
final class DimensionLabelView: NSTextField {
    var onClick: (() -> Void)?
    var isEditingHighlight = false {
        didSet {
            backgroundColor = isEditingHighlight ? NSColor.systemYellow.withAlphaComponent(0.85)
                                                 : NSColor.textBackgroundColor.withAlphaComponent(0.85)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        textColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// SwiftUI wrapper. The revision numbers are passed in so SwiftUI calls updateNSView exactly
/// when geometry, selection, overlay or camera requests change.
struct ViewportView: NSViewRepresentable {
    let model: DocumentModel
    let sceneRevision: Int
    let overlayRevision: Int
    let highlighted: [UInt32]
    let fitRevision: Int
    let cameraRevision: Int

    final class Coordinator {
        var sceneRevision = -1
        var fitRevision = -1
        var cameraRevision = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ViewportMTKView {
        let view = ViewportMTKView(frame: .zero, device: nil)
        guard let renderer = Renderer() else { return view }
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.clearColor = MTLClearColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        renderer.onPick = { [weak view] raw in view?.pickResult(raw) }
        return view
    }

    func updateNSView(_ view: ViewportMTKView, context: Context) {
        guard let renderer = view.renderer else { return }
        let c = context.coordinator
        if c.sceneRevision != sceneRevision {
            c.sceneRevision = sceneRevision
            renderer.setScene(model.meshes)
            renderer.hovered = 0
        }
        if c.fitRevision != fitRevision, let b = model.sceneBounds {
            c.fitRevision = fitRevision
            renderer.camera.fit(min: b.min, max: b.max)
        }
        if c.cameraRevision != cameraRevision, let req = model.cameraRequest {
            c.cameraRevision = cameraRevision
            renderer.camera.look(along: req.normal, at: req.target)
        }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = highlighted
        view.needsDisplay = true
    }
}

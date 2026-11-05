// The Metal view: hosts the shared Renderer in a UIKit MTKView and turns touches into camera moves, picks and sketching.
//
// Outside a sketch (finger first):
//   one finger drag      orbit
//   two finger drag      pan
//   pinch                zoom, about the point between the fingers
//   two finger rotate    spin the view (the same rule as the trackpad's rotate on the Mac)
//   tap                  pick the face, edge or profile under the finger; the model decides what that means
//
// In a sketch the same two-finger moves still move the view, and one finger works the sketch (see `SketchTouch`):
//   tap                  the tool's next click, at that spot
//   drag                 with a drawing tool: press where the shape starts, drag, lift where it ends
//                        with Select: drag a point or curve; empty space orbits, as on the Mac
//
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import MetalKit
import SwiftUI

/// The viewport's view: it only reports where fingers come down (so the pick under the first one is on its way before any gesture starts).
final class PadMetalView: MTKView {
    var onTouchDown: ((CGPoint) -> Void)?
    /// A key of a hardware keyboard, while the viewport has the keyboard; true when it was used.
    var onKey: ((UIKey) -> Bool)?
    /// Edit ▸ Copy and Paste (⌘C, ⌘V from the keyboard or the system's edit menu): bodies, not text.
    var onCopy: (() -> Bool)?
    var onPaste: (() -> Bool)?
    var canPaste: (() -> Bool)?
    override var canBecomeFirstResponder: Bool { true }
    /// Whether the touch in progress is the Apple Pencil's: it is precise, so it snaps and picks over a smaller reach.
    var usingPencil = false

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): return true
        case #selector(paste(_:)): return canPaste?() ?? false
        default: return super.canPerformAction(action, withSender: sender)
        }
    }
    override func copy(_ sender: Any?) { _ = onCopy?() }
    override func paste(_ sender: Any?) { _ = onPaste?() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.count == 1, event?.allTouches?.count == 1, let t = touches.first {
            if !isFirstResponder { _ = becomeFirstResponder() }  // taking hold of the view ends typing in a field
            usingPencil = t.type == .pencil
            onTouchDown?(t.location(in: self))
        }
        super.touchesBegan(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses {
            if let key = press.key, onKey?(key) == true { unhandled.remove(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
}

struct PadViewport: UIViewRepresentable {
    let model: DocumentModel
    /// What the viewport redraws on: SwiftUI calls `updateUIView` when one of these changes.
    let sceneRevision: Int
    let overlayRevision: Int
    let fitRevision: Int
    let cameraRevision: Int
    let highlighted: [UInt32]
    let orthographic: Bool
    let visualStyle: VisualStyle
    let explodeOffsets: [SIMD3<Float>]
    let sketching: Bool
    let showGrid: Bool
    let showAxes: Bool
    /// How much of the view the floating panels and the tool bar cover (left, right, bottom; the bar below the navigation bar).
    let panelInsets: (left: CGFloat, right: CGFloat, bottom: CGFloat)
    let toolbarHeight: CGFloat
    let state: PadViewState
    var printPreview = false
    var printLayer = 0.2
    var printNozzle = 0.4
    /// The Render view's floor and light; nil: not rendering.
    var renderSettings: RenderSettings?
    /// The Render view's turntable: the camera circles the part by itself.
    var spinning = false
    var sectionPlane: SIMD4<Float>?
    var sketchSlice: (origin: SIMD3<Float>, normal: SIMD3<Float>)?

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate, UIPencilInteractionDelegate {
        var renderer: Renderer?
        var model: DocumentModel?
        var state: PadViewState?
        var sceneRevision = -1
        var fitRevision = -1
        /// The tool a sketch was using before the Pencil's tap switched to Select.
        var lastDrawingTool: SketchTool = .line
        var cameraRevision = 0
        var explodeOffsets: [SIMD3<Float>] = []
        var sketching = false
        var insets: (left: CGFloat, right: CGFloat, bottom: CGFloat) = (0, 0, 0)
        var toolbarHeight: CGFloat = 0
        var dark: Bool?
        let navigation = Preferences.navigationConfig
        weak var view: MTKView?
        var touch = SketchTouch()
        var sketchCamera = SketchCameraMemory()
        var menuInteraction: UIEditMenuInteraction?
        /// A long press waits for the pick under it, then opens the menu for what it found.
        var pendingMenu: CGPoint?
        var menu: UIMenu?
        var hoverPickPending = false
        var animation: Task<Void, Never>?
        var spin: Task<Void, Never>?
        /// What a one-finger drag outside a sketch is doing: orbiting, or dragging one of the on-screen handles.
        var drag: ViewDrag = .orbit
        var pendingTap: (point: CGPoint, additive: Bool)?
        var lastTap: (time: TimeInterval, point: CGPoint)?

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { view.setNeedsDisplay() }
        }
        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                updateSketchGrid(view)
                updateCameraInsets(view, insets, toolbar: toolbarHeight)
                state?.renderer = renderer
                state?.cameraMayHaveMoved(size: view.bounds.size)
                if let state, state.topInset != view.safeAreaInsets.top + toolbarHeight { state.topInset = view.safeAreaInsets.top + toolbarHeight }
                renderer?.draw(in: view)
            }
        }

        // MARK: Pictures

        /// The next frame, as PNG data.
        func capturePNG(_ done: @escaping @MainActor @Sendable (Data?) -> Void) {
            guard let renderer, let view else { return done(nil) }
            renderer.captureHandler = done
            view.setNeedsDisplay()
        }

        // MARK: Camera motion

        /// Moves the camera smoothly to `goal`; a finger taking hold of the view ends it where it is, and with Reduce Motion on it jumps.
        func animateCamera(to goal: CameraPose, duration: TimeInterval = 0.5) {
            guard let renderer, let view else { return }
            stopCameraAnimation()
            let start = renderer.camera.pose
            guard !start.isClose(to: goal) else { return }
            if UIAccessibility.isReduceMotionEnabled {
                renderer.camera.pose = goal
                view.setNeedsDisplay()
                return
            }
            let began = Date()
            animation = Task { @MainActor [weak self] in
                var last = start
                while !Task.isCancelled {
                    guard let self, let renderer = self.renderer, let view = self.view else { return }
                    if renderer.camera.pose != last { break }  // moved by something else in between: let it be
                    let t = Float(min(Date().timeIntervalSince(began) / duration, 1))
                    last = start.blended(to: goal, CameraPose.eased(t))
                    renderer.camera.pose = last
                    view.setNeedsDisplay()
                    if t >= 1 { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
                if !Task.isCancelled { self?.animation = nil }
            }
        }

        func stopCameraAnimation() { animation?.cancel(); animation = nil }

        /// The Render view's turntable.
        func setSpinning(_ on: Bool) {
            if !on { spin?.cancel(); spin = nil; return }
            guard spin == nil else { return }
            spin = Task { @MainActor [weak self] in
                var last = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard let self, let renderer = self.renderer, let view = self.view else { return }
                    let now = Date()
                    let dt = Float(min(now.timeIntervalSince(last), 0.1))
                    last = now
                    if self.animation != nil { continue }
                    renderer.camera.yaw = remainder(renderer.camera.yaw - (2 * .pi / 45) * dt, 2 * .pi)
                    view.setNeedsDisplay()
                }
            }
        }

        // MARK: Look

        /// Centres the picture in what the panels leave free, and sizes a fit to it (the Mac does the same with its panels).
        func updateCameraInsets(_ view: MTKView, _ panels: (left: CGFloat, right: CGFloat, bottom: CGFloat), toolbar: CGFloat) {
            guard let renderer, view.bounds.width > 1, view.bounds.height > 1 else { return }
            let w = view.bounds.width, h = view.bounds.height
            let top = min(view.safeAreaInsets.top + toolbar, h * 0.3)
            let left = min(panels.left, w * 0.45), right = min(panels.right, w * 0.45), bottom = min(panels.bottom, h * 0.3)
            renderer.camera.centerShift = SIMD2(Float((left - right) / w), Float((bottom - top) / h))
            renderer.camera.visibleFraction = SIMD2(Float((w - left - right) / w), Float((h - top - bottom) / h))
        }

        /// The palette follows light and dark mode, and a sketch gets its paper colour.
        func applyAppearance(_ view: MTKView) {
            guard let renderer else { return }
            let isDark = view.traitCollection.userInterfaceStyle == .dark
            renderer.palette = .make(dark: isDark, increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                                     paper: sketching ? Preferences.sketchPaperSetting.color(dark: isDark) : nil)
            let b = renderer.palette.background
            view.clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y), blue: Double(b.z), alpha: 1)
            dark = isDark
            view.setNeedsDisplay()
        }

        // MARK: Sketch plane

        /// Where a point of the view falls on the sketch plane, in the sketch's (u, v) millimetres.
        func sketchUV(_ p: CGPoint, in view: MTKView) -> SIMD2<Double>? {
            guard let renderer, let frame = model?.sketchSession?.frame else { return nil }
            let ray = renderer.camera.ray(at: p, viewSize: view.bounds.size)
            let o = SIMD3<Double>(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z))
            let d = SIMD3<Double>(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z))
            let n = frame.normal
            let denom = (d * n).sum()
            guard abs(denom) > 1e-9 else { return nil }
            let t = ((frame.origin - o) * n).sum() / denom
            let hit = o + t * d - frame.origin
            return SIMD2((hit * frame.xAxis).sum(), (hit * frame.yAxis).sum())
        }

        private func mmPerPoint(in view: MTKView, at p: CGPoint) -> Double? {
            guard let a = sketchUV(p, in: view), let b = sketchUV(CGPoint(x: p.x + 1, y: p.y), in: view) else { return nil }
            return simdLength(b - a)
        }

        /// The grid in the sketch's plane, over the part of it that is in view.
        func updateSketchGrid(_ view: MTKView) {
            guard let renderer else { return }
            guard let session = model?.sketchSession,
                  let mm = mmPerPoint(in: view, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) else {
                if renderer.sketchGrid != nil { renderer.setSketchGrid(nil) }
                return
            }
            let steps = GridSteps.steps(mmPerPixel: mm)
            let b = view.bounds
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: b.width, y: 0), CGPoint(x: 0, y: b.height),
                           CGPoint(x: b.width, y: b.height), CGPoint(x: b.midX, y: b.midY)].compactMap { sketchUV($0, in: view) }
            let reach = 60 * steps.major  // a plane seen edge-on reaches to the horizon
            let center = corners.last ?? .zero
            func span(_ values: [Double], _ mid: Double) -> ClosedRange<Double> {
                let lo = max((values.min() ?? mid) - steps.major, mid - reach), hi = min((values.max() ?? mid) + steps.major, mid + reach)
                return (lo / steps.major).rounded(.down) * steps.major...(hi / steps.major).rounded(.up) * steps.major
            }
            let grid = SketchGrid(frame: session.frame, minor: steps.minor, major: steps.major,
                                  u: span(corners.map(\.x), center.x), v: span(corners.map(\.y), center.y), lines: renderer.showGrid)
            if renderer.sketchGrid != grid { renderer.setSketchGrid(grid) }
        }

        // MARK: Sketch touches

        /// One sketch event at a point of the view: the model's pointer API, with a finger's snapping reach (bigger than a pointer's).
        @discardableResult
        func sketchEvent(_ phase: SketchMouse.Phase, at p: CGPoint, in view: MTKView) -> Bool {
            guard let model, let renderer else { return false }
            let pencil = (view as? PadMetalView)?.usingPencil == true
            var tolerance: Double?, gridStep: Double?
            if let mm = mmPerPoint(in: view, at: p) {
                tolerance = (pencil ? 6 : 14) * mm
                if Preferences.snapsToGrid { gridStep = GridSteps.steps(mmPerPixel: mm).snap }
            }
            let handled = model.sketchMouse(SketchMouse(phase: phase, uv: sketchUV(p, in: view), pick: nil, additive: false,
                                                        tolerance: tolerance, gridStep: gridStep, snapping: true))
            renderer.setOverlay(model.sketchOverlay())
            view.setNeedsDisplay()
            return handled
        }

        /// A finger on the sketch: see the header for what each tool does with it.
        func sketchPan(_ g: UIPanGestureRecognizer, in view: MTKView) {
            guard let model, let session = model.sketchSession, let renderer else { return }
            let location = g.location(in: view)
            switch g.state {
            case .began:
                let start = CGPoint(x: location.x - g.translation(in: view).x, y: location.y - g.translation(in: view).y)
                touch = SketchTouch(start: start, hadClicks: !session.clicks.isEmpty, mode: .draw)
                sketchEvent(.moved, at: start, in: view)
                if session.tool == .select {
                    // The model says whether there is something to drag; empty space orbits instead.
                    touch.mode = sketchEvent(.down, at: start, in: view) ? .drag : .orbit
                } else if !touch.hadClicks {
                    sketchEvent(.down, at: start, in: view)  // the first point goes where the finger came down
                }
                g.setTranslation(.zero, in: view)
                continue_(location, g, view, session)
            case .changed:
                continue_(location, g, view, session)
            case .ended, .cancelled:
                switch touch.mode {
                case .orbit: break
                case .drag: sketchEvent(.up, at: location, in: view)
                case .draw:
                    let far = hypot(location.x - touch.start.x, location.y - touch.start.y) > SketchTouch.dragThreshold
                    if g.state == .ended, touch.hadClicks || far {
                        sketchEvent(.moved, at: location, in: view)
                        sketchEvent(.down, at: location, in: view)
                    }
                    sketchEvent(.up, at: location, in: view)
                }
                touch = SketchTouch()
            default: break
            }
            _ = renderer
        }

        private func continue_(_ location: CGPoint, _ g: UIPanGestureRecognizer, _ view: MTKView, _ session: SketchSession) {
            guard let renderer else { return }
            switch touch.mode {
            case .orbit:
                let t = g.translation(in: view)
                g.setTranslation(.zero, in: view)
                navigation.navigate(&renderer.camera, .orbit, input: .drag, dx: Float(t.x), dy: Float(t.y), viewHeight: Float(view.bounds.height))
                view.setNeedsDisplay()
            case .drag: sketchEvent(.dragged, at: location, in: view)
            case .draw: sketchEvent(.moved, at: location, in: view)
            }
        }

        // MARK: Gestures

        @objc func orbit(_ g: UIPanGestureRecognizer) {
            guard let view, let renderer, let model else { return }
            if model.sketchSession != nil { return sketchPan(g, in: view) }
            let p = g.location(in: view)
            switch g.state {
            case .began:
                let start = CGPoint(x: p.x - g.translation(in: view).x, y: p.y - g.translation(in: view).y)
                drag = beginViewDrag(at: start, in: view)
                g.setTranslation(.zero, in: view)
                if case .orbit = drag { break }
                continueViewDrag(at: p, in: view)
                return
            case .changed:
                if case .orbit = drag { break }
                continueViewDrag(at: p, in: view)
                return
            case .ended, .cancelled:
                endViewDrag(in: view)
                return
            default: return
            }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            navigation.navigate(&renderer.camera, .orbit, input: .drag, dx: Float(t.x), dy: Float(t.y), viewHeight: Float(view.bounds.height))
            view.setNeedsDisplay()
        }

        // MARK: Dragging handles

        private func world(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }

        private func ray(at p: CGPoint, in view: MTKView) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
            guard let renderer else { return nil }
            let r = renderer.camera.ray(at: p, viewSize: view.bounds.size)
            return (world(r.origin), world(r.direction))
        }

        /// How long 1 mm along a line looks on screen, so a size can go in round steps.
        private func pointsPerMM(from a: SIMD3<Double>, along d: SIMD3<Double>, in view: MTKView) -> Double? {
            guard let renderer else { return nil }
            let b = a + d
            guard let pa = renderer.camera.project(SIMD3(Float(a.x), Float(a.y), Float(a.z)), viewSize: view.bounds.size),
                  let pb = renderer.camera.project(SIMD3(Float(b.x), Float(b.y), Float(b.z)), viewSize: view.bounds.size) else { return nil }
            return Double(hypot(pb.x - pa.x, pb.y - pa.y))
        }

        /// What the finger that came down at `p` has hold of: the Move manipulator, a feature's handle, a hole's dot, a plane's edge, the
        /// section's handle, or nothing (it turns the view). The pick under it was asked for when it touched down.
        private func beginViewDrag(at p: CGPoint, in view: MTKView) -> ViewDrag {
            guard let renderer, let model else { return .orbit }
            if let layout = manipulatorLayout(view), let part = layout.hit(p), let start = model.manipulatorDragStart,
               let d = ManipulatorDrag(part: part, at: p, layout: layout, start: start) {
                model.beginManipulatorDrag(part)
                renderer.setOverlay(model.sketchOverlay())
                return .manipulator(d)
            }
            let pick = PickID(raw: renderer.hovered)
            if renderer.hovered == PickID.moveHandle.raw { model.beginHoleMove(); return .holeMove }
            if pick.kind == .planeEdge { model.beginPlaneResize(pick); return .planeResize }
            if renderer.hovered == PickID.sectionHandle.raw, let r = ray(at: p, in: view) {
                model.beginSectionDrag(rayOrigin: r.origin, direction: r.direction)
                return .section
            }
            if pick.kind == .handle { model.beginHandleDrag(slot: pick.handleSlot); return .handle }
            return .orbit
        }

        private func continueViewDrag(at p: CGPoint, in view: MTKView) {
            guard let renderer, let model, let r = ray(at: p, in: view) else { return }
            switch drag {
            case .orbit: return
            case .manipulator(var d):
                if let v = d.values(at: p, camera: renderer.camera, viewSize: view.bounds.size) { model.previewManipulator(v) }
            case .holeMove:
                var mm: Double?
                if let (id, hole) = model.selectedHole, let face = model.holeFace(id, hole), let a = model.holeMoveDot { mm = pointsPerMM(from: a, along: face.xAxis, in: view) }
                model.moveHole(rayOrigin: r.origin, direction: r.direction, pointsPerMM: mm)
            case .planeResize:
                var mm: Double?
                if let l = model.planeResizeLine { mm = pointsPerMM(from: l.point, along: l.direction, in: view) }
                model.dragPlaneEdge(rayOrigin: r.origin, direction: r.direction, pointsPerMM: mm)
            case .section:
                model.dragSection(rayOrigin: r.origin, direction: r.direction, snapping: true)
            case .handle:
                var mm: Double?
                if let h = model.dragHandle { mm = pointsPerMM(from: h.base, along: h.direction, in: view) }
                model.dragHandle(rayOrigin: r.origin, direction: r.direction, pointsPerMM: mm)
            }
            renderer.setOverlay(model.sketchOverlay())
            view.setNeedsDisplay()
        }

        private func endViewDrag(in view: MTKView) {
            guard let renderer, let model else { return }
            switch drag {
            case .orbit: break
            case .manipulator: model.endManipulatorDrag()
            case .holeMove: model.endHoleMove()
            case .planeResize: model.endPlaneResize()
            case .section: model.endSectionDrag()
            case .handle: model.endHandleDrag()
            }
            drag = .orbit
            renderer.setOverlay(model.sketchOverlay())
            view.setNeedsDisplay()
        }

        /// The Move/Rotate manipulator's layout on the selected Move feature, in this view's points.
        func manipulatorLayout(_ view: MTKView) -> ManipulatorLayout? {
            guard let renderer, let model, let place = model.manipulatorPlacement else { return nil }
            return ManipulatorLayout(middle: place.middle, turn: place.turn, frame: place.frame, camera: renderer.camera, viewSize: view.bounds.size)
        }

        /// A finger came down: ask what is under it, so the pick is back by the time a drag has begun.
        func touchDown(_ p: CGPoint, in view: MTKView) {
            guard let renderer, model?.sketchSession == nil else { return }
            let scale = CGFloat(view.pixelScale)
            renderer.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
            view.setNeedsDisplay()
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let view, let renderer else { return }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            navigation.navigate(&renderer.camera, .pan, input: .drag, dx: Float(t.x), dy: Float(t.y), viewHeight: Float(view.bounds.height))
            view.setNeedsDisplay()
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let view, let renderer else { return }
            let anchor = ZoomAnchor(point: g.location(in: view), viewSize: view.bounds.size)
            navigation.pinch(&renderer.camera, magnification: Float(g.scale - 1), cursor: anchor)
            g.scale = 1
            view.setNeedsDisplay()
        }

        @objc func rotate(_ g: UIRotationGestureRecognizer) {
            guard let view, let renderer else { return }
            // UIKit's rotation is clockwise; the Mac's (and `NavigationConfig.rotate`) is counter-clockwise.
            navigation.rotate(&renderer.camera, degrees: Float(-g.rotation * 180 / .pi), sketching: model?.sketchSession != nil)
            g.rotation = 0
            view.setNeedsDisplay()
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view, let renderer, let model else { return }
            let p = g.location(in: view)
            if model.sketchSession != nil {  // a click at that spot, then the finger is already up
                let now = ProcessInfo.processInfo.systemUptime
                if let last = lastTap, now - last.time < 0.35, hypot(p.x - last.point.x, p.y - last.point.y) < 24,
                   let session = model.sketchSession {
                    lastTap = nil
                    sketchEvent(.moved, at: p, in: view)
                    // A double tap on a curve takes the whole joined chain; on a text it edits the words.
                    if session.tool == .select || session.tool == .text, let h = session.hover, session.beginEditingText(anchoredAt: h) {
                        renderer.setOverlay(model.sketchOverlay()); view.setNeedsDisplay(); return
                    }
                    if session.tool == .select, session.hover.flatMap({ session.sketch.curve($0) }) != nil {
                        session.selectConnected(additive: false)
                        renderer.setOverlay(model.sketchOverlay()); view.setNeedsDisplay(); return
                    }
                }
                lastTap = (now, p)
                sketchEvent(.moved, at: p, in: view)
                sketchEvent(.down, at: p, in: view)
                sketchEvent(.up, at: p, in: view)
                return
            }
            let scale = CGFloat(view.pixelScale)
            renderer.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
            pendingTap = (p, false)
            view.setNeedsDisplay()
        }

        /// A pick came back: it is the answer to a tap, or only what is under a finger.
        func picked(_ raw: UInt32) {
            guard let view, let renderer, let model else { return }
            renderer.hovered = raw
            if let p = pendingMenu { pendingMenu = nil; showMenu(at: p, pick: raw, in: view); return }
            if hoverPickPending {
                hoverPickPending = false
                if model.sketchSession == nil, pendingTap == nil {
                    let pick = raw == 0 ? nil : PickID(raw: raw)
                    model.hover(pick)
                    renderer.selected = model.highlighted
                    view.setNeedsDisplay()
                    return
                }
            }
            guard let tap = pendingTap else { return }
            pendingTap = nil
            let p = tap.point
            let now = ProcessInfo.processInfo.systemUptime
            let r = renderer.camera.ray(at: p, viewSize: view.bounds.size)
            if let last = lastTap, now - last.time < 0.35, hypot(p.x - last.point.x, p.y - last.point.y) < 24 {
                lastTap = nil  // the second tap of a double tap: edit what is under it, in place of a click
                let f = renderer.camera.forward
                model.doubleClick(raw == 0 ? nil : PickID(raw: raw), viewDirection: world(f), additive: false)
                renderer.setOverlay(model.sketchOverlay()); view.setNeedsDisplay()
                return
            }
            lastTap = (now, p)
            model.clickRay = (world(r.origin), world(r.direction))
            let next = renderer.camera.ray(at: CGPoint(x: p.x + 1, y: p.y), viewSize: view.bounds.size)
            model.clickRayNext = (world(next.origin), world(next.direction))
            if model.pickingRenderFocus, let ray = model.clickRay {  // Select focus point: the click puts the sharp spot where it lands
                if let hit = model.focusPoint(origin: ray.0, direction: ray.1) { model.setRenderFocus(hit) }
            } else {
                var pick = raw == 0 ? nil : PickID(raw: raw)
                // While a plane is being asked for, the grid floor (the XY plane) answers too.
                if pick == nil, renderer.showGrid, model.showsOriginPlanes, let ray = model.clickRay,
                   ray.direction.z.magnitude > 1e-9, -ray.origin.z / ray.direction.z > 0 {
                    pick = OriginPlane.xy.pickID
                }
                model.click(pick, additive: false)
            }
            renderer.setOverlay(model.sketchOverlay()); view.setNeedsDisplay()
        }

        // MARK: Apple Pencil

        /// A double tap of the Pencil (or its squeeze): in a sketch it switches between Select and the tool that was in use, outside
        /// a sketch it undoes. The system's own setting for the gesture (switch tool, undo…) is respected where it asks for something else.
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) { pencilAction() }
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            if squeeze.phase == .ended { pencilAction() }
        }

        private func pencilAction() {
            guard let model, let view else { return }
            if let session = model.sketchSession {
                if session.tool == .select { session.setTool(lastDrawingTool) }
                else { lastDrawingTool = session.tool; session.setTool(.select) }
                renderer?.setOverlay(model.sketchOverlay()); view.setNeedsDisplay()
            } else {
                model.undoManager?.undo()
            }
        }

        // MARK: Keyboard

        /// A key from a hardware keyboard, as the Mac's viewport takes it: Esc, Return and ⌫ for what is going on, number keys into a shape's
        /// size, and the sketch tools' letters.
        func handleKey(_ key: UIKey) -> Bool {
            guard let view, let renderer, let model else { return false }
            let plain = key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
            func refresh() { renderer.setOverlay(model.sketchOverlay()); renderer.selected = model.highlighted; view.setNeedsDisplay() }
            if let session = model.sketchSession, plain {
                switch key.keyCode {
                case .keyboardEscape: session.escape(); refresh(); return true
                case .keyboardDeleteOrBackspace, .keyboardDeleteForward:
                    if let field = session.inputFields.last(where: { session.typed[$0] != nil }), key.keyCode == .keyboardDeleteOrBackspace {
                        session.setTyped(field, String((session.typed[field] ?? "").dropLast())); model.overlayRevision += 1  // takes back a typed digit
                    } else if session.isPatterning { model.commitSketch(session.deletePattern()) }
                    else if session.isMirroring { model.commitSketch(session.deleteMirror()) }
                    else if session.isOffsetting { session.cancelOffset() }
                    else { model.sketchCommand { $0.deleteSelection() } }
                    refresh(); return true
                case .keyboardReturnOrEnter, .keypadEnter:
                    if session.typed.isEmpty, !session.isPatterning, !session.isMirroring, !session.isOffsetting { model.finishSketch() }
                    else { model.commitSketchTyped(); refresh() }
                    return true
                case .keyboardDownArrow where session.tool == .polygon, .keyboardUpArrow where session.tool == .polygon:
                    session.adjustSides(by: key.keyCode == .keyboardUpArrow ? 1 : -1); refresh(); return true
                default: break
                }
                let fields = session.inputFields
                if !fields.isEmpty, key.characters.count == 1, "0123456789.-".contains(key.characters) {
                    let field = fields.first { session.typed[$0] == nil } ?? fields[0]
                    session.setTyped(field, (session.typed[field] ?? "") + key.characters)
                    model.overlayRevision += 1
                    return true
                }
                if let c = key.charactersIgnoringModifiers.lowercased().first, let tool = SketchTool.forKey(c, current: session.tool) {
                    model.setSketchTool(tool); refresh(); return true
                }
                return false
            }
            if key.keyCode == .keyboardEscape {
                if model.pickingRenderFocus { model.togglePickingRenderFocus() }
                else if model.isPickingSketchPlane { model.cancelSketchPlanePick() }
                else if model.pendingTool != nil { model.cancelTool() }
                else if model.selection.isEmpty, model.dragHandle != nil || model.featureWithoutHandle != nil { model.finishFeatureEdit() }
                else { model.clearSelection() }
                refresh(); return true
            }
            if plain, key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
               model.pendingTool != nil || model.dragHandle != nil || model.featureWithoutHandle != nil {
                if model.pendingTool != nil { model.confirmTool() } else { model.finishFeatureEdit() }
                refresh(); return true
            }
            return false
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let view, let renderer else { return }
            let p = g.location(in: view)
            pendingMenu = p
            let scale = CGFloat(view.pixelScale)
            renderer.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
            view.setNeedsDisplay()
        }

        /// A pointer or the Pencil hovering: what is under it lights up, and in a sketch it moves the preview.
        @objc func hover(_ g: UIHoverGestureRecognizer) {
            guard let view, let renderer, let model else { return }
            let p = g.location(in: view)
            switch g.state {
            case .began, .changed:
                if model.sketchSession != nil {
                    sketchEvent(.moved, at: p, in: view)
                } else if !hoverPickPending, drag.isOrbit {
                    hoverPickPending = true
                    let scale = CGFloat(view.pixelScale)
                    renderer.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
                    view.setNeedsDisplay()
                }
            case .ended, .cancelled:
                if model.sketchSession == nil { renderer.hovered = 0; model.hover(nil); view.setNeedsDisplay() }
            default: break
            }
        }

        /// The long press's pick came back: the menu for what is under the finger.
        private func showMenu(at p: CGPoint, pick raw: UInt32, in view: MTKView) {
            guard let renderer, let model else { return }
            let pick = raw == 0 ? nil : PickID(raw: raw)
            let r = renderer.camera.ray(at: p, viewSize: view.bounds.size)
            let ray = (world(r.origin), world(r.direction))
            let next = renderer.camera.ray(at: CGPoint(x: p.x + 1, y: p.y), viewSize: view.bounds.size)
            model.clickRayNext = (world(next.origin), world(next.direction))
            var items = model.contextItems(for: pick, ray: ray)
            if model.sketchSession == nil, model.pendingTool == nil {
                items += [.separator, .action(model.sectionActive ? "Turn Off Section Analysis" : "Section Analysis", symbol: DesignTool.sectionAnalysis.symbol) {
                    model.setSectionAnalysis(!model.sectionActive)
                }]
                items += [.separator, .action(model.explodeOn ? "Leave Exploded View" : "Exploded View", symbol: "rectangle.expand.vertical") { model.setExplodedView(!model.explodeOn) }]
                items += [.separator, .action(model.renderView ? "Leave Render View" : "Render View", symbol: "camera") { model.setRenderView(!model.renderView) }]
                if model.renderView, !model.showRenderOptions {
                    items += [.action("Show Render Options", symbol: "slider.horizontal.3") { model.showRenderOptions = true }]
                }
                if model.visualStyle.isShaded {
                    items += [.separator, .action(model.printPreview ? "Leave 3D Print Preview" : "FDM 3D Print Preview", symbol: "square.stack.3d.up") { model.setPrintPreview(!model.printPreview) }]
                }
            }
            menu = ContextMenuBuilder.menu(items) { [weak self] in
                guard let self, let view = self.view, let renderer = self.renderer, let model = self.model else { return }
                renderer.setOverlay(model.sketchOverlay()); view.setNeedsDisplay()
            }
            menuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
        }

        nonisolated func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                             suggestedActions: [UIMenuElement]) -> UIMenu? {
            MainActor.assumeIsolated { menu }
        }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            // Two fingers may pan, pinch and rotate at once, as in every other app that has a canvas.
            !(a is UITapGestureRecognizer) && !(b is UITapGestureRecognizer)
                && !(a is UIPanGestureRecognizer && b is UIPanGestureRecognizer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = PadMetalView(frame: .zero, device: nil)
        let c = context.coordinator
        c.view = view
        c.model = model
        c.state = state
        state.capture = { [weak c] done in c?.capturePNG(done) }
        state.lookAlong = { [weak c] n in
            guard let c, let renderer = c.renderer else { return }
            var goal = renderer.camera
            goal.look(along: n, at: goal.target)
            c.animateCamera(to: goal.pose, duration: 0.3)
        }
        state.orbit = { [weak c] dx, dy in
            guard let c, let renderer = c.renderer, let view = c.view else { return }
            c.stopCameraAnimation()
            renderer.camera.orbit(dx: dx, dy: dy)
            view.setNeedsDisplay()
        }
        state.turn = { [weak c] direction in
            guard let c, let renderer = c.renderer else { return }
            var goal = renderer.camera.pose
            goal.roll = renderer.camera.quarterTurnedRoll(direction)
            c.animateCamera(to: goal, duration: 0.25)
        }
        guard let renderer = Renderer() else { return view }
        c.renderer = renderer
        view.device = renderer.device
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.sampleCount = renderer.sampleCount
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = c
        view.accessibilityIdentifier = "viewport"
        c.applyAppearance(view)

        let orbit = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.orbit))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch))
        let rotate = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.rotate))
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap))
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold))
        hold.minimumPressDuration = 0.5
        let hover = UIHoverGestureRecognizer(target: c, action: #selector(Coordinator.hover))
        let pencil = UIPencilInteraction(delegate: c)
        view.addInteraction(pencil)
        let menu = UIEditMenuInteraction(delegate: c)
        view.addInteraction(menu)
        c.menuInteraction = menu
        for g in [orbit, pan, pinch, rotate, tap, hold, hover] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }

        // A pick comes back from the GPU a frame later: hand what it found to the model, which selects it.
        renderer.onPick = { [weak c] raw, _ in c?.picked(raw) }
        view.onTouchDown = { [weak c, weak view] p in if let view { c?.touchDown(p, in: view) } }
        view.onKey = { [weak c] key in c?.handleKey(key) ?? false }
        view.onCopy = { [weak model] in model?.copyBodies() ?? false }
        view.onPaste = { [weak model] in model?.pasteBodies() ?? false }
        view.canPaste = { DocumentModel.pasteboardHasBodies() }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        guard let renderer = c.renderer else { return }
        c.model = model
        renderer.camera.orthographic = orthographic
        renderer.visualStyle = visualStyle
        renderer.showAxes = showAxes
        renderer.showGrid = showGrid
        if c.sketching != sketching || c.dark != (view.traitCollection.userInterfaceStyle == .dark) {
            c.sketching = sketching
            c.applyAppearance(view)
        }
        // Closing a sketch turns the flat view back to the one it was opened from; noted before any camera command below.
        let before = c.sketchCamera.update(sketching: model.sketchSession != nil, camera: renderer.camera.pose)
        if c.sceneRevision != sceneRevision || c.explodeOffsets != explodeOffsets {
            c.sceneRevision = sceneRevision
            c.explodeOffsets = explodeOffsets
            renderer.setScene(model.visibleMeshes, offsets: explodeOffsets)
            renderer.sceneBounds = model.explodedSceneBounds
            renderer.hovered = 0
            renderer.hoverGroup = []
        }
        // Every update: a colour being picked changes nothing else.
        renderer.bodyColors = model.visibleMeshes.map { m in
            model.displayColor(of: m.id).map { c -> SIMD4<Float> in
                let (r, g, b) = c.components
                return SIMD4(Float(r), Float(g), Float(b), 1)
            }
        }
        renderer.bodyMaterials = model.visibleMeshes.map { m in
            switch model.displayMaterial(of: m.id) {
            case nil: 0
            case .metal: 1
            case .glass: 2
            case .wood: 3
            case .plastic: 4
            }
        }
        renderer.focusPoint = model.renderFocusPoint.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
        renderer.bodyRoughness = model.visibleMeshes.map { m in model.displayRoughness(of: m.id).map { Float($0) } ?? -1 }
        renderer.printPreview = printPreview
        renderer.printLayer = Float(printLayer)
        renderer.printNozzle = Float(printNozzle)
        renderer.renderSettings = renderSettings
        c.setSpinning(spinning)
        renderer.sectionPlane = sectionPlane
        renderer.sketchSlice = sketchSlice
        if let before, !model.sketchClosedKeepingView { c.animateCamera(to: before) }
        let aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
        c.insets = panelInsets
        c.toolbarHeight = toolbarHeight
        c.updateCameraInsets(view, panelInsets, toolbar: toolbarHeight)
        if c.fitRevision != fitRevision {
            c.fitRevision = fitRevision
            if let b = model.explodedSceneBounds { renderer.camera.fit(min: b.min, max: b.max, aspect: aspect) }
        }
        // The camera moves the model asks for: looking square at a new sketch's plane, a standard view.
        if c.cameraRevision != cameraRevision, let cmd = model.cameraCommand {
            c.cameraRevision = cameraRevision
            c.stopCameraAnimation()
            switch cmd.command {
            case .look(let target, let normal):
                renderer.camera.look(along: normal, at: target)
            case .lookFit(let lo, let hi, let normal):
                renderer.camera.look(along: normal, at: (lo + hi) / 2)
                renderer.camera.fit(min: lo, max: hi, aspect: aspect)
            case .standard(let v):
                renderer.camera.setStandard(v)
                if let b = model.explodedSceneBounds { renderer.camera.fit(min: b.min, max: b.max, aspect: aspect) }
            }
        }
        renderer.setOverlay(model.sketchOverlay())
        renderer.selected = highlighted
        renderer.wholeBodies = model.picksWholeBodies
        view.setNeedsDisplay()
    }
}

/// What one finger on a sketch is doing: where it came down, and what that means for the tool in use.
struct SketchTouch {
    enum Mode {
        /// A drawing tool: press where the shape starts, drag, lift where it ends.
        case draw
        /// Select, on a point or curve: the finger drags it.
        case drag
        /// Select, on empty space: the finger turns the view.
        case orbit
    }
    /// Points the finger has to travel before a press-and-lift counts as a drag rather than a tap.
    static let dragThreshold: CGFloat = 12
    var start: CGPoint = .zero
    /// The tool already had a first point placed when the finger came down.
    var hadClicks = false
    var mode: Mode = .draw
}

/// What a one-finger drag outside a sketch has hold of.
enum ViewDrag {
    var isOrbit: Bool { if case .orbit = self { return true } else { return false } }
    case orbit
    case manipulator(ManipulatorDrag)
    case holeMove
    case planeResize
    case section
    case handle
}

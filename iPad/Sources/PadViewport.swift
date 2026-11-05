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
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.count == 1, event?.allTouches?.count == 1, let t = touches.first { onTouchDown?(t.location(in: self)) }
        super.touchesBegan(touches, with: event)
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

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        var renderer: Renderer?
        var model: DocumentModel?
        var sceneRevision = -1
        var fitRevision = -1
        var cameraRevision = 0
        var explodeOffsets: [SIMD3<Float>] = []
        var sketching = false
        var insets: (left: CGFloat, right: CGFloat, bottom: CGFloat) = (0, 0, 0)
        var toolbarHeight: CGFloat = 0
        var dark: Bool?
        let navigation = Preferences.navigationConfig
        weak var view: MTKView?
        var touch = SketchTouch()
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
                renderer?.draw(in: view)
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
            var tolerance: Double?, gridStep: Double?
            if let mm = mmPerPoint(in: view, at: p) {
                tolerance = 14 * mm
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
        for g in [orbit, pan, pinch, rotate, tap] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }

        // A pick comes back from the GPU a frame later: hand what it found to the model, which selects it.
        renderer.onPick = { [weak c] raw, _ in c?.picked(raw) }
        view.onTouchDown = { [weak c, weak view] p in if let view { c?.touchDown(p, in: view) } }
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
        if c.sceneRevision != sceneRevision || c.explodeOffsets != explodeOffsets {
            c.sceneRevision = sceneRevision
            c.explodeOffsets = explodeOffsets
            renderer.setScene(model.visibleMeshes, offsets: explodeOffsets)
            renderer.sceneBounds = model.explodedSceneBounds
        }
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
    case orbit
    case manipulator(ManipulatorDrag)
    case holeMove
    case planeResize
    case section
    case handle
}

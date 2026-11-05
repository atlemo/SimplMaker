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
            guard let view, let renderer else { return }
            if model?.sketchSession != nil { return sketchPan(g, in: view) }
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            navigation.navigate(&renderer.camera, .orbit, input: .drag, dx: Float(t.x), dy: Float(t.y), viewHeight: Float(view.bounds.height))
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
            guard let view, let renderer else { return }
            let p = g.location(in: view)
            if model?.sketchSession != nil {  // a click at that spot, then the finger is already up
                sketchEvent(.moved, at: p, in: view)
                sketchEvent(.down, at: p, in: view)
                sketchEvent(.up, at: p, in: view)
                return
            }
            let scale = CGFloat(view.pixelScale)
            renderer.pickRequest = SIMD2(Int(p.x * scale), Int(p.y * scale))
            view.setNeedsDisplay()
        }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            // Two fingers may pan, pinch and rotate at once, as in every other app that has a canvas.
            !(a is UITapGestureRecognizer) && !(b is UITapGestureRecognizer)
                && !(a is UIPanGestureRecognizer && b is UIPanGestureRecognizer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
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
        renderer.onPick = { [weak c] raw, _ in
            c?.model?.click(raw == 0 ? nil : PickID(raw: raw), additive: false)
        }
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

// The Metal view: hosts the shared Renderer in a UIKit MTKView and turns touches into camera moves and picks.
//
// Touch model (finger first):
//   one finger drag      orbit
//   two finger drag      pan
//   pinch                zoom, about the point between the fingers
//   two finger rotate    spin the view (the same rule as the trackpad's rotate on the Mac)
//   tap                  select the face or edge under the finger; a tap on empty space clears it (the model decides what a tap does)
//
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import MetalKit
import SwiftUI

struct PadViewport: UIViewRepresentable {
    let model: DocumentModel
    /// What the viewport redraws on: SwiftUI calls `updateUIView` when one of these changes.
    let sceneRevision: Int
    let fitRevision: Int
    let highlighted: [UInt32]
    let orthographic: Bool
    let visualStyle: VisualStyle
    let explodeOffsets: [SIMD3<Float>]

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        var renderer: Renderer?
        var model: DocumentModel?
        var sceneRevision = -1
        var fitRevision = -1
        var explodeOffsets: [SIMD3<Float>] = []
        let navigation = Preferences.navigationConfig
        weak var view: MTKView?

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { view.setNeedsDisplay() }
        }
        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { renderer?.draw(in: view) }
        }

        // MARK: Gestures

        @objc func orbit(_ g: UIPanGestureRecognizer) {
            guard let view, let renderer else { return }
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
            navigation.rotate(&renderer.camera, degrees: Float(-g.rotation * 180 / .pi))
            g.rotation = 0
            view.setNeedsDisplay()
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view, let renderer else { return }
            let p = g.location(in: view)
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
        view.clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        view.accessibilityIdentifier = "viewport"

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
        if c.sceneRevision != sceneRevision || c.explodeOffsets != explodeOffsets {
            c.sceneRevision = sceneRevision
            c.explodeOffsets = explodeOffsets
            renderer.setScene(model.visibleMeshes, offsets: explodeOffsets)
            renderer.sceneBounds = model.explodedSceneBounds
        }
        if c.fitRevision != fitRevision {
            c.fitRevision = fitRevision
            if let b = model.explodedSceneBounds {
                let size = view.bounds.size
                renderer.camera.fit(min: b.min, max: b.max, aspect: Float(max(size.width, 1) / max(size.height, 1)))
            }
        }
        renderer.selected = highlighted
        view.setNeedsDisplay()
    }
}

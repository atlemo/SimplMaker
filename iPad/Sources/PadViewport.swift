// The Metal view: hosts the shared Renderer in a UIKit MTKView.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import MetalKit
import SwiftUI

struct PadViewport: UIViewRepresentable {
    let scene: PadScene

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: Renderer?
        var revision = -1
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }
        func draw(in view: MTKView) { renderer?.draw(in: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
        guard let renderer = Renderer() else { return view }
        context.coordinator.renderer = renderer
        view.device = renderer.device
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.sampleCount = renderer.sampleCount
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        guard let renderer = c.renderer, c.revision != scene.revision, let b = scene.bounds else { return }
        c.revision = scene.revision
        renderer.setScene(scene.meshes)
        renderer.sceneBounds = b
        let size = view.bounds.size
        renderer.camera.fit(min: b.min, max: b.max, aspect: Float(max(size.width, 1) / max(size.height, 1)))
        view.setNeedsDisplay()
    }
}

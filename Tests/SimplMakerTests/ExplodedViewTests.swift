import AppKit
import CADCore
import Foundation
import Testing
import simd
@testable import SimplMaker

@Suite struct ExplodedViewTests {
    private func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> (min: SIMD3<Float>, max: SIMD3<Float>) { (lo, hi) }

    /// Three plates stacked on Z, thick, thin and thick, 100 mm tall in all.
    let stack = [(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(10, 10, 40)),
                 (min: SIMD3<Float>(0, 0, 40), max: SIMD3<Float>(10, 10, 45)),
                 (min: SIMD3<Float>(0, 0, 45), max: SIMD3<Float>(10, 10, 100))]

    @Test func nothingMovesAtZeroOrWithOneBody() {
        #expect(ExplodedView.offsets(boxes: stack, amount: 0, direction: .all).allSatisfy { $0 == .zero })
        #expect(ExplodedView.offsets(boxes: [stack[0]], amount: 1, direction: .all) == [.zero])
    }

    @Test func layersOpenByTheSameDistanceWhateverTheirSize() {
        let o = ExplodedView.offsets(boxes: stack, amount: 0.5, direction: .z)
        // The middle layer stays; the others move one equal step each way (0.5 x 100 mm / 2 gaps = 25 mm).
        #expect(o[1] == .zero)
        #expect(o[0] == SIMD3(0, 0, -25) && o[2] == SIMD3(0, 0, 25))
        #expect(o[1].z - o[0].z == o[2].z - o[1].z)
    }

    @Test func bodiesAtOneLevelMoveTogether() {
        let boxes = [stack[0], stack[2], (min: SIMD3<Float>(20, 0, 0), max: SIMD3<Float>(30, 10, 40)), stack[1]]
        let o = ExplodedView.offsets(boxes: boxes, amount: 1, direction: .z)
        #expect(o[0] == o[2], "two bodies at the bottom share a layer")
        #expect(o[0].z < o[3].z && o[3].z < o[1].z)
    }

    @Test func anAxisKeepsTheOtherDirectionsStill() {
        let o = ExplodedView.offsets(boxes: stack, amount: 1, direction: .x)
        #expect(o.allSatisfy { $0 == .zero }, "all in one layer on X: nothing to open")
        let all = ExplodedView.offsets(boxes: stack, amount: 1, direction: .all)
        #expect(all.allSatisfy { $0.x == 0 && $0.y == 0 })
        #expect(all[0].z < 0 && all[2].z > 0)
    }
}

/// The exploded view as drawn: each body sits where its offset puts it.
@Suite @MainActor struct ExplodedViewRenderTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func bodiesAreDrawnWhereTheirOffsetsPutThem() async throws {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "60 mm", length: "40 mm", height: "30 mm"))),
            Feature(id: "c", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "90 mm", width: "20 mm", length: "20 mm", height: "30 mm"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        #expect(model.canExplode)
        model.setExplodedView(true)
        model.explodeAmount = 1
        model.explodeDirection = .x
        let offsets = model.explodeOffsets
        #expect(offsets.count == 2)
        #expect(offsets[0].x < -1 && offsets[1].x > 1 && offsets[0].y == 0 && offsets[0].z == 0)
        model.explodeOn = false
        #expect(model.explodeOffsets.isEmpty)
        model.explodeOn = true

        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 560), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        view.colorPixelFormat = Renderer.colorFormat
        view.depthStencilPixelFormat = Renderer.depthFormat
        view.framebufferOnly = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        renderer.setScene(model.visibleMeshes, offsets: offsets)
        renderer.showGrid = false
        renderer.showAxes = false
        renderer.camera.orthographic = true
        renderer.camera.target = SIMD3(60, 20, 15)
        renderer.camera.distance = 600
        renderer.camera.yaw = -.pi / 2
        renderer.camera.pitch = 1.2

        var bytes: [UInt8] = [], width = 0
        var last: [UInt8] = []
        for _ in 0..<40 {
            view.draw(view.bounds)
            try await Task.sleep(for: .milliseconds(100))
            guard let texture = view.fullSizeTexture else { continue }
            bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            width = texture.width
            if bytes == last && !ViewportSnapshot.isBlank(bytes) { break }
            last = bytes
        }
        try #require(width > 0)
        let scale = CGFloat(width) / view.bounds.width
        func pixel(_ p: SIMD3<Float>) -> [UInt8] {
            let q = renderer.camera.project(p, viewSize: view.bounds.size)!
            let i = (Int(q.y * scale) * width + Int(q.x * scale)) * 4
            return Array(bytes[i..<i + 3])
        }
        let background = Array(bytes[0..<3])
        #expect(pixel(SIMD3(30, 20, 30) + offsets[0]) != background, "the first box is drawn at its shifted place")
        #expect(pixel(SIMD3(100, 10, 30) + offsets[1]) != background, "the second box is drawn at its shifted place")
        #expect(pixel(SIMD3(30, 20, 30)) == background, "and no longer where it was")
        withExtendedLifetime(window) {}
    }
}

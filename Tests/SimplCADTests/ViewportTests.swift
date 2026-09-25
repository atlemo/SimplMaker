// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import Testing
@testable import SimplCAD

@Suite struct ViewportTests {
    @Test func swiftLayoutsMatchShaderStructs() {
        #expect(MemoryLayout<FaceVertex>.stride == 28)       // packed_float3 ×2 + uint
        #expect(MemoryLayout<SegmentInstance>.stride == 28)  // packed_float3 ×2 + uint
        #expect(MemoryLayout<Uniforms>.stride == 160)
        #expect(MemoryLayout<DrawParams>.stride == 64)
    }

    @Test func shadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // no GPU on this machine
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        for name in ["faceVertex", "faceFragment", "regionVertex", "regionFragment", "segmentVertex", "segmentFragment"] {
            #expect(library.makeFunction(name: name) != nil, "\(name)")
        }
    }

    @Test @MainActor func rendererBuildsPipelines() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        #expect(Renderer() != nil)
    }

    @Test func pickIDsRoundTrip() {
        let f = PickID(body: 3, face: 1234)
        #expect(!f.isEdge && f.body == 3 && f.element == 1234 && f.raw != 0)
        let e = PickID(body: 0, edge: 0)
        #expect(e.isEdge && e.body == 0 && e.element == 0)
        #expect(PickID(body: 1021, face: 0xFFFFF).kind == .face)
        #expect(PickID(sketchPoint: 7).kind == .sketchPoint && PickID(sketchPoint: 7).element == 7)
        #expect(PickID(sketchCurve: 0).kind == .sketchCurve)
        #expect(PickID(region: 3).kind == .region && PickID(region: 3).element == 3)
        #expect(PickID(raw: 0).kind == .none)
    }
}

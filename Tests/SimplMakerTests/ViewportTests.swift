// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Metal
import Testing
@testable import SimplMaker

@Suite struct ViewportTests {
    @Test func swiftLayoutsMatchShaderStructs() {
        #expect(MemoryLayout<FaceVertex>.stride == 28)       // packed_float3 ×2 + uint
        #expect(MemoryLayout<SegmentInstance>.stride == 28)  // packed_float3 ×2 + uint
        #expect(MemoryLayout<Uniforms>.stride == 176)          // …, 4 × float4 colours, then wholeBodies + 3 pad uints
        #expect(MemoryLayout<DrawParams>.stride == 96)          // 3 × float4, then 10 scalars (thickness … dashLength), padded
    }

    @Test func shadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // no GPU on this machine
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        for name in ["faceVertex", "faceFragment", "regionVertex", "regionFragment", "planeFragment",
                     "segmentVertex", "segmentFragment", "pickSample"] {
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
        #expect(PickID.handle.kind == .handle)
        #expect(PickID(plane: 2).kind == .plane && PickID(plane: 2).element == 2)
        #expect(PickID(plane: 0).kind == .plane && PickID(plane: 0) != PickID.handle)
        #expect(PickID(raw: 0).kind == .none)
        for edge in 0..<4 {
            let side = PickID(planeEdge: edge, plane: 5)
            #expect(side.kind == .planeEdge && side.element == 5 && side.planeEdge == edge)
            #expect(side != PickID(plane: 5) && side != PickID.handle)
        }
    }

    @Test @MainActor func aConstructionPlaneOffersItsFourSidesToDrag() {
        var o = SketchOverlay()
        let ids = (0..<4).map { PickID(planeEdge: $0, plane: 0).raw }
        SketchOverlayBuilder.constructionPlane(.xy, extent: PlaneExtent(uMin: -2, uMax: 10, vMin: -1, vMax: 4), id: 9, edgeIDs: ids, into: &o)
        #expect(o.planeEdges.map(\.id) == ids)
        // Bottom runs along v = vMin from uMin to uMax; the left side is the last, at u = uMin.
        #expect(o.planeEdges[0].ax == -2 && o.planeEdges[0].bx == 10 && o.planeEdges[0].ay == -1 && o.planeEdges[0].by == -1)
        #expect(o.planeEdges[3].ax == -2 && o.planeEdges[3].bx == -2 && o.planeEdges[3].ay == 4 && o.planeEdges[3].by == -1)
        var none = SketchOverlay()
        SketchOverlayBuilder.constructionPlane(.xy, extent: PlaneExtent(side: 10), id: 9, edgeIDs: nil, into: &none)
        #expect(none.planeEdges.isEmpty && none.planeOutline.count == 4)
    }

    @Test func originPlanesRoundTripThroughPicksAndLabels() {
        for plane in OriginPlane.allCases {
            #expect(OriginPlane(pick: plane.pickID) == plane)
            #expect(OriginPlane(labelID: plane.labelID) == plane)
            #expect(plane.planeRef == [PlaneRef.xy, .xz, .yz][plane.rawValue])
        }
        #expect(OriginPlane(pick: PickID.handle) == nil)
        #expect(OriginPlane(labelID: "d1") == nil)
        #expect(OriginPlane.displaySize(for: nil) == 25)
        #expect(OriginPlane.displaySize(for: (min: SIMD3(-10, 0, 0), max: SIMD3(100, 40, 10))) == 60)
    }

    @Test @MainActor func originPlaneOverlayHasThreePickableSquares() {
        var o = SketchOverlay()
        SketchOverlayBuilder.originPlanes(size: 25, into: &o)
        #expect(o.planeVertices.count == 12 && o.planeIndices.count == 18 && o.planeOutline.count == 12)
        #expect(Set(o.planeVertices.map(\.id)) == Set(OriginPlane.allCases.map(\.pickID.raw)))
        let far = o.planeVertices[2]  // the XY square's corner opposite the origin
        #expect(far.px == 25 && far.py == 25 && far.pz == 0)
        let yz = o.planeVertices[10]
        #expect(yz.px == 0 && yz.py == 25 && yz.pz == 25)
        #expect(SketchOverlayBuilder.originPlaneLabels(size: 25).map(\.text) == ["XY", "XZ", "YZ"])
    }
}

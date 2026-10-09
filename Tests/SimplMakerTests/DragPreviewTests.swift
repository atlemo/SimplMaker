// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// Dragging an arrow on an early feature rebuilds everything after it on every step; a thread there (a third of a second)
/// would make the drag crawl, so the steps leave it out and the drop builds it.
@Suite @MainActor struct DragPreviewTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(2))
        for _ in 0..<4000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(2)) }
    }

    private func threadedBlockModel() async throws -> DocumentModel {
        let block = Feature(id: "b", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "30 mm", length: "30 mm", height: "15 mm")))
        var doc = CADDocument()
        doc.features = [block]
        let top = try #require(Regenerator.regenerate(doc).body("b")).faceFrame("b.top")
        let d = SIMD3<Double>(0, 0, 15) - top.origin
        let hole = Feature(id: "h", name: "Hole", .hole(HoleFeature(face: FaceRef(body: "b", face: "b.top"),
                                                                    u: "\((d * top.xAxis).sum())", v: "\((d * top.yAxis).sum())",
                                                                    diameter: "6.8", depth: nil)))
        doc.features = [block, hole]
        let wall = try #require(Regenerator.regenerate(doc).body("b")?.faceNames.first { $0.hasPrefix("h.hole.wall") })
        doc.features.append(Feature(id: "th", name: "Thread", .thread(ThreadFeature(face: FaceRef(body: "b", face: wall), size: "M8x1.25"))))
        let model = DocumentModel(document: doc)
        try await settle(model)
        return model
    }

    private func hasThread(_ model: DocumentModel) -> Bool {
        model.result?.body("b")?.faceNames.contains { $0.hasPrefix("th.thread") } == true
    }

    @Test func aDragLeavesTheThreadOutUntilTheDrop() async throws {
        let model = try await threadedBlockModel()
        #expect(hasThread(model) && model.result?.errors.isEmpty == true)
        model.selectedFeature = "b"
        let handle = try #require(model.dragHandles.first)
        model.beginHandleDrag(slot: handle.slot)
        for k in 0..<4 {
            let p = handle.base + handle.direction * (handle.value + Double(k) * 0.5)
            model.dragHandle(rayOrigin: p + SIMD3(0, -300, 0), direction: SIMD3(0, 1, 0))
            try await settle(model)
            #expect(!hasThread(model) && model.result?.errors.isEmpty == true, "step \(k): a plain drilled hole while dragging")
            #expect(!model.previewInvalid)
        }
        model.endHandleDrag()
        try await settle(model)
        #expect(hasThread(model) && model.result?.errors.isEmpty == true, "the drop builds the thread")
    }

    @Test func aStepIsQuickWhateverTheThreadCosts() async throws {
        let model = try await threadedBlockModel()
        model.selectedFeature = "b"
        let handle = try #require(model.dragHandles.first)
        model.beginHandleDrag(slot: handle.slot)
        var slowest = 0.0
        for k in 0..<6 {
            let t = Date()
            let p = handle.base + handle.direction * (handle.value + Double(k) * 0.5)
            model.dragHandle(rayOrigin: p + SIMD3(0, -300, 0), direction: SIMD3(0, 1, 0))
            try await settle(model)
            slowest = max(slowest, Date().timeIntervalSince(t))
        }
        model.endHandleDrag()
        try await settle(model)
        #expect(slowest < 0.15, "the slowest step of the drag took \(slowest) s")
    }
}

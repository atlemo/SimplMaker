// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// The slowest step of a drag of six steps, in seconds.
    private func slowestStep(_ model: DocumentModel) async throws -> Double {
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
        return slowest
    }

    /// Waits (up to a minute) until the main actor answers promptly. A step is mostly turns on it, and when the tests run side
    /// by side the others keep it busy (pictures, windows), so a step can take far longer than its own work.
    private func quietMainActor() async throws {
        let deadline = Date().addingTimeInterval(60)
        var prompt = 0
        while prompt < 25 && Date() < deadline {
            let t = Date()
            try await Task.sleep(for: .milliseconds(2))
            prompt = Date().timeIntervalSince(t) < 0.01 ? prompt + 1 : 0
        }
    }

    @Test func aStepIsQuickWhateverTheThreadCosts() async throws {
        let model = try await threadedBlockModel()
        // A step that built the thread would take about 0.2 s every time; one that leaves it out takes a few ms. A slow step
        // can still be the other tests getting in, so the quickest of three drags counts.
        var best = Double.infinity
        for _ in 0..<3 where best >= 0.15 {
            try await quietMainActor()
            best = min(best, try await slowestStep(model))
        }
        #expect(best < 0.15, "the slowest step of the quickest drag took \(best) s")
    }
}

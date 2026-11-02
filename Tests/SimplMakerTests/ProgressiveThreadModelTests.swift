// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

/// An edit that makes the model build a thread shows the model without it first, then with it.
@Suite @MainActor struct ProgressiveThreadModelTests {
    /// A box whose width is a parameter, with a drilled hole and a thread in it.
    private func threadedBox() throws -> CADDocument {
        let block = Feature(id: "b", name: "Box", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "w", length: "30 mm", height: "15 mm")))
        var doc = CADDocument(parameters: [Parameter("w", "30 mm")])
        doc.features = [block]
        let top = try #require(Regenerator.regenerate(doc).body("b")).faceFrame("b.top")
        let d = SIMD3<Double>(0, 0, 15) - top.origin
        let hole = Feature(id: "h", name: "Hole", .hole(HoleFeature(face: FaceRef(body: "b", face: "b.top"),
                                                                    u: "\((d * top.xAxis).sum())", v: "\((d * top.yAxis).sum())",
                                                                    diameter: "6.8", depth: nil)))
        doc.features = [block, hole]
        let wall = try #require(Regenerator.regenerate(doc).body("b")?.faceNames.first { $0.hasPrefix("h.hole.wall") })
        doc.features.append(Feature(id: "th", name: "Thread", .thread(ThreadFeature(face: FaceRef(body: "b", face: wall), size: "M8x1.25"))))
        return doc
    }

    private func hasThread(_ model: DocumentModel) -> Bool {
        model.result?.body("b")?.faceNames.contains { $0.hasPrefix("th.thread") } == true
    }

    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(2))
        for _ in 0..<4000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func anEditShowsTheModelBeforeItsThreads() async throws {
        let model = DocumentModel(document: try threadedBox())
        model.progressiveThreads = 0
        try await settle(model)
        #expect(hasThread(model) && model.result?.errors.isEmpty == true)

        model.setParameter("w", expression: "34 mm")
        var sawDraft = false
        for _ in 0..<4000 where model.isRegenerating {
            if model.isRegenerating, model.result != nil, !hasThread(model), model.result?.errors.isEmpty == true,
               abs((model.result?.parameters.values["w"]?.value ?? 0) - 34) < 1e-9 { sawDraft = true }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(sawDraft, "the new width shows before the thread is built")
        #expect(hasThread(model) && model.result?.errors.isEmpty == true, "and the thread follows")
        #expect(!model.isRegenerating)
    }

    @Test func aNewerEditSkipsTheThreadsOfAnOlderOne() async throws {
        let model = DocumentModel(document: try threadedBox())
        model.progressiveThreads = 0
        try await settle(model)
        model.setParameter("w", expression: "33 mm")
        model.setParameter("w", expression: "35 mm")  // queued behind the first
        try await settle(model)
        #expect(hasThread(model) && model.result?.errors.isEmpty == true)
        #expect(abs((model.result?.parameters.values["w"]?.value ?? 0) - 35) < 1e-9)
    }
}

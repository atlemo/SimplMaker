// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The Combine tool, and moving a whole sketch.
@Suite @MainActor struct CombineToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func combineCutsTheSecondBodyOutOfTheFirst() async throws {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
            Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "10", length: "10", height: "20"))),
        ]
        let model = DocumentModel(document: d)
        try await settle(model)
        #expect(model.result?.bodies.count == 2)
        model.run(.combine)
        #expect(model.pendingTool == .combine && model.toolPrompt == "Click the body to cut from, join to or intersect with")
        model.toolClick(.combine, PickID(body: 0, face: 0))
        model.toolClick(.combine, PickID(body: 1, face: 0))
        #expect(model.pendingTool == .combine, "waits for more tools until Return")
        model.confirmTool()
        guard case .combine(let c)? = model.document.features.last?.kind else { Issue.record("expected a combine"); return }
        #expect(c.target == "a" && c.tools == ["b"] && c.operation == .cut)
        try await settle(model)
        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let volume = try #require(r.body("a")).volume
        #expect(r.bodies.map(\.id) == ["a"] && abs(volume - (4000 - 1000)) < 1e-6, "\(volume)")
    }

    @Test func aSketchMovesWithAHandle() async throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 5)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.move(sketches: ["sk"])
        guard case .move(let m)? = model.document.features.last?.kind else { Issue.record("expected a move"); return }
        #expect(m.sketches == ["sk"] && m.bodies.isEmpty)
        try await settle(model)
        #expect(model.dragHandle?.label == "Move X")
        #expect(model.commitHandle("15"))
        try await settle(model)
        let frame = try #require(model.result?.sketches["sk"]?.frame)
        #expect(abs(frame.origin.x - 15) < 1e-9)
    }
}

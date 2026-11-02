// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// Locking bodies and sketches against picking and editing.
@Suite @MainActor struct LockTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func model(undo: UndoManager? = nil) async throws -> DocumentModel {
        var s = Sketch()
        s.addRectangle(0, 0, 40, 20)
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10"))),
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
        ]
        let m = DocumentModel(document: d)
        m.undoManager = undo
        try await settle(m)
        return m
    }

    @Test func aLockedBodyCannotBePickedOrSelected() async throws {
        let m = try await model()
        let face = PickID(body: 0, face: 0)
        m.click(face, additive: false)
        #expect(m.selection == [face])

        m.setLocked(["a"], true)
        #expect(m.isLocked("a") && m.selection.isEmpty, "locking drops it from the selection")
        m.click(face, additive: false)
        m.hover(face)
        #expect(m.selection.isEmpty && m.hovered == nil)
        m.selectBody("a")
        #expect(m.selection.isEmpty)

        m.setLocked(["a"], false)
        m.click(face, additive: false)
        #expect(m.selection == [face])
    }

    @Test func aLockedBodyDoesNotLightUpWhileSketching() async throws {
        let m = try await model()
        m.setLocked(["a"], true)
        m.editSketch("sk")
        #expect(m.sketchSession != nil)
        let face = PickID(body: 0, face: 0)
        #expect(m.isLockedPick(face))
        m.hover(face)
        #expect(m.hovered == nil)
        #expect(!m.isLockedPick(PickID(sketchCurve: 0)), "the sketch's own curves still pick")
    }

    @Test func aLockedSketchCannotBeEditedOrDeleted() async throws {
        let m = try await model()
        m.setLocked(["sk"], true)
        m.editSketch("sk")
        #expect(m.sketchSession == nil)
        m.deleteFeature("sk")
        #expect(m.document.features.contains { $0.id == "sk" })
        let region = PickID(region: 0, slot: 1)
        #expect(m.isLockedPick(region))
        m.setLocked(["sk"], false)
        m.editSketch("sk")
        #expect(m.sketchSession?.featureID == "sk")
    }

    @Test func lockingIsUndoableSavedAndNeedsNoRebuild() async throws {
        let undo = UndoManager()
        let m = try await model(undo: undo)
                m.setLocked(["a", "sk"], true)
        #expect(m.document.locked == ["a", "sk"] && !m.isRegenerating, "a lock rebuilds nothing")
        let back = try JSONDecoder().decode(CADDocument.self, from: JSONEncoder().encode(m.document))
        #expect(back.locked == ["a", "sk"])
        undo.undo()
        #expect(m.document.locked.isEmpty)
    }

    @Test func onlyBodiesAndSketchesLock() async throws {
        let m = try await model()
        m.setLocked(["nothing"], true)
        #expect(m.document.locked.isEmpty)
    }
}

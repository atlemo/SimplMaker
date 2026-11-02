// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Edit ▸ Copy and Paste of bodies.
@Suite @MainActor struct BodyClipboardTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("simplmaker.test.\(UUID().uuidString)")) }

    @Test func aCopiedBodyPastesAsAnotherBodyWithItsNameColourAndMaterial() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        let plate = try #require(model.bodies.first)
        let volume = try #require(model.result?.body(plate.id)?.volume)
        model.setBodyColor(BodyColor(red: UInt8(200), green: UInt8(30), blue: UInt8(30)), of: [plate.id])
        model.setBodyMaterial(.metal, of: [plate.id])
        let pasteboard = board()

        #expect(!model.copyBodies(to: pasteboard), "nothing is selected")
        model.selection = [PickID(wholeBody: 0)]
        #expect(model.copyBodies(to: pasteboard))
        #expect(DocumentModel.pasteboardHasBodies(pasteboard))

        #expect(model.pasteBodies(from: pasteboard))
        try await settle(model)
        #expect(model.bodies.count == 2)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let pasted = try #require(model.bodies.last)
        #expect(pasted.name == "\(plate.name) copy")
        #expect(abs((model.result?.body(pasted.id)?.volume ?? 0) - volume) < 1e-3)
        #expect(model.document.bodyColors[pasted.id] == BodyColor(red: UInt8(200), green: UInt8(30), blue: UInt8(30)))
        #expect(model.document.bodyMaterials[pasted.id] == .metal, "the material goes with the colour")
        // The Move tool is open on the pasted body, ready to slide it off the original.
        let moveID = try #require(model.selectedFeature)
        guard case .move(let move)? = model.document.features.first(where: { $0.id == moveID })?.kind else {
            Issue.record("the selected feature should be a Move"); return
        }
        #expect(move.bodies == [pasted.id])
        #expect(model.newFeature == moveID)

        // Pasting again adds a third, with its own name.
        #expect(model.pasteBodies(from: pasteboard))
        try await settle(model)
        #expect(model.bodies.map(\.name) == [plate.name, "\(plate.name) copy", "\(plate.name) copy 2"])
    }

    @Test func bodiesPasteIntoAnotherPart() async throws {
        let source = DocumentModel(document: .demo())
        try await settle(source)
        let target = DocumentModel()
        try await settle(target)
        let pasteboard = board()
        source.selection = [PickID(body: 0, face: 1)]  // a face copies its body
        #expect(source.copyBodies(to: pasteboard))
        #expect(target.pasteBodies(from: pasteboard))
        try await settle(target)
        #expect(target.bodies.count == 1)
        #expect(target.bodies.first?.name == source.bodies.first?.name)
    }

    @Test func pastingWithNothingCopiedChangesNothing() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        let before = model.document
        #expect(!model.pasteBodies(from: board()))
        #expect(model.document == before)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The Appearance panel colours the selected bodies, without rebuilding the model.
@Suite @MainActor struct AppearanceTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func twoBoxes() -> CADDocument {
        var d = CADDocument()
        d.features = [
            Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy))),
            Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "40 mm"))),
        ]
        return d
    }

    @Test func selectedBodiesTakeTheColour() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        #expect(model.appearanceTargets.isEmpty)
        model.click(PickID(body: 1, face: 0), additive: false)
        #expect(model.appearanceTargets == ["b"], "a face stands for its body")
        model.selectBody("a", additive: true)
        #expect(model.appearanceTargets == ["a", "b"], "in body order")

        let before = model.result?.duration
        let copper = try #require(BodyColor(hex: "#C07A4F"))
        model.setBodyColor(copper, of: model.appearanceTargets)
        #expect(model.document.bodyColors == ["a": copper, "b": copper])
        #expect(!model.isRegenerating && model.result?.duration == before, "colours need no rebuild")

        model.setBodyColor(nil, of: ["a"])
        #expect(model.displayColor(of: "a") == nil && model.displayColor(of: "b") == copper, "back to the default")
    }

    @Test func withThePanelOpenSelectedBodiesAreOutlinedNotFilled() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        model.click(PickID(body: 1, face: 0), additive: false)
        #expect(model.highlighted == [PickID(body: 1, face: 0).raw], "panel closed: the face lights up")
        model.showAppearance = true
        #expect(model.outlinesSelectedBodies)
        #expect(model.highlighted == [PickID(wholeBody: 1).raw], "panel open: the body, so its colour shows")
        model.selectBody("a")
        #expect(model.highlighted == [PickID(wholeBody: 0).raw])
    }

    @Test func aColourBeingPickedShowsWithoutChangingTheDocument() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        let blue = try #require(BodyColor(hex: "#3A78D0"))
        model.previewBodyColor(blue, of: ["a"])
        #expect(model.displayColor(of: "a") == blue && model.displayColor(of: "b") == nil)
        #expect(model.document.bodyColors.isEmpty)
        model.setBodyColor(blue, of: ["a"])
        #expect(model.colorPreview == nil && model.document.bodyColors == ["a": blue])
    }

    @Test func theAKeyTogglesThePanelOutsideSketchMode() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        model.toggleAppearance()
        #expect(model.showAppearance)
        model.toggleAppearance()
        #expect(!model.showAppearance)

        model.openAppearance(for: "b")
        #expect(model.showAppearance && model.selectedBody == "b", "Appearance… on a body selects it")

        model.showAppearance = false
        model.beginSketch(on: .xy)
        model.toggleAppearance()
        #expect(!model.showAppearance, "in a sketch, A draws an arc")
        model.finishSketch()
        try await settle(model)
    }
}

/// Every Create and Modify tool has its own letter in the menus, apart from A (Appearance).
@Suite struct MenuLetterTests {
    @Test func toolLettersAreUnique() {
        let keys = DesignTool.allCases.map(\.key)
        #expect(Set(keys).count == keys.count, "two tools share a letter")
        #expect(!keys.contains("a"), "A opens the Appearance panel")
        #expect(keys.allSatisfy { $0.isLowercase && $0.isLetter })
        for tool in DesignTool.allCases {
            #expect(tool.help.hasPrefix("\(tool.rawValue) (\(String(tool.key).uppercased())):"), "the tooltip names the key")
        }
    }
}

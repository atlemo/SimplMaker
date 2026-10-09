// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

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

    @Test func openingThePanelCancelsAWaitingTool() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        model.run(.shell)
        #expect(model.pendingTool == .shell)
        model.toggleAppearance()
        #expect(model.showAppearance && model.pendingTool == nil, "clicks now pick bodies to colour")
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

/// Highlights are made from the body's own colour, as in Fusion.
@Suite @MainActor struct BodyTintTests {
    @Test func highlightsFollowTheBodysColour() {
        let palette = ViewportPalette.make(dark: false, increaseContrast: false)
        let plain = Renderer.tint(nil, palette: palette)
        #expect(plain.faceSelected == palette.faceSelected && plain.edgeSelected == palette.selection, "no colour: blue as before")

        let red = SIMD4<Float>(0.82, 0.23, 0.19, 1)
        let r = Renderer.tint(red, palette: palette)
        #expect(r.face == red && r.edgeSelected == red, "red borders")
        #expect(r.faceSelected.x > red.x && r.faceSelected.x > r.faceSelected.z, "lighter, and still red")
        #expect(r.faceHover.x < r.faceSelected.x, "hover is lighter than the colour, less than selection")

        let white = SIMD4<Float>(0.95, 0.95, 0.94, 1)
        let w = Renderer.tint(white, palette: palette)
        #expect(w.faceSelected.x < white.x && w.edgeSelected.x < w.faceSelected.x, "a light colour darkens instead")
    }
}

/// Every Create and Modify tool has its own letter in the menus, apart from A (Appearance); a tool that came after
/// the letters ran out (Draft, Split Body) has ⇧ with one.
@Suite struct MenuLetterTests {
    @Test func toolLettersAreUnique() {
        let chords = DesignTool.allCases.map { KeyChord($0.defaultKey, $0.defaultModifiers) }
        #expect(Set(chords).count == chords.count, "two tools share a letter")
        #expect(!chords.contains(KeyChord("a")), "A opens the Appearance panel")
        #expect(DesignTool.allCases.allSatisfy { $0.defaultKey.isLowercase && $0.defaultKey.isLetter })
        let plain = DesignTool.allCases.filter { $0.defaultModifiers.isEmpty }.map(\.defaultKey)
        #expect(Set(plain).count == plain.count, "two tools share a plain letter")
        #expect(Set(DesignTool.allCases.filter { !$0.defaultModifiers.isEmpty }) == [.draft, .split, .layOnFloor])
        for tool in DesignTool.allCases {
            let label = KeyChord(tool.defaultKey, tool.defaultModifiers).label
            #expect(tool.help.hasPrefix("\(tool.rawValue) (\(label)):"), "the tooltip names the key")
        }
    }
}

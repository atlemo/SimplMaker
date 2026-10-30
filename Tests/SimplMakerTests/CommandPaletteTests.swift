// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The ⌘K command palette: what it offers and how it finds it.
@Suite @MainActor struct CommandPaletteTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func item(_ title: String, group: String = "Create", keywords: String = "") -> PaletteItem {
        PaletteItem(id: title, title: title, group: group, keywords: keywords, perform: {})
    }

    @Test func aTitleStartBeatsAWordStartBeatsLettersInOrder() {
        let items = [item("Offset Selection"), item("Fillet", keywords: "round"), item("Round Corner"), item("Extrude"), item("Rib")]
        #expect(PaletteSearch.rank("ext", items).map(\.title) == ["Extrude"])
        #expect(PaletteSearch.rank("xtr", items).map(\.title) == ["Extrude"], "letters in order")
        #expect(PaletteSearch.rank("round", items).map(\.title) == ["Round Corner", "Fillet"], "the title first, then a keyword")
        #expect(PaletteSearch.rank("corner", items).map(\.title) == ["Round Corner"], "a later word of the title")
    }

    @Test func everyWordHasToMatchAndAnEmptyQueryListsEverything() {
        let items = [item("Export STL", group: "File"), item("Export STEP", group: "File"), item("Show Grid", group: "View")]
        #expect(PaletteSearch.rank("export st", items).count == 2)
        #expect(PaletteSearch.rank("export grid", items).isEmpty)
        #expect(PaletteSearch.rank("file", items).map(\.title) == ["Export STL", "Export STEP"], "the group counts")
        #expect(PaletteSearch.rank("  ", items).count == 3)
        #expect(PaletteSearch.rank("zzz", items).isEmpty)
    }

    @Test func theToolsOfADesignWindowAreThereWithTheirShortcuts() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        let items = model.paletteItems()
        let extrude = try #require(items.first { $0.title == "Extrude" })
        #expect(extrude.group == "Create" && extrude.detail == Shortcuts.label(.tool(.extrude)))
        #expect(items.contains { $0.title == "Fillet" } && items.contains { $0.title == "Export…" } && items.contains { $0.title == "Fit All" })
        #expect(!items.contains { $0.title == "Line" }, "the sketch tools are only offered while sketching")
        #expect(items.contains { $0.title.hasPrefix("Edit ") && $0.group == "Feature" })
        #expect(Set(items.map(\.id)).count == items.count, "no two items share an id")
    }

    @Test func whileSketchingTheSketchToolsReplaceTheDesignTools() async throws {
        let model = DocumentModel()
        try await settle(model)
        model.beginSketch(on: .xy)
        let items = model.paletteItems()
        #expect(items.contains { $0.title == "Line" } && items.contains { $0.title == "Finish Sketch" })
        #expect(!items.contains { $0.title == "Extrude" })
        #expect(PaletteSearch.rank("fillet", items).first?.title == "Round Corner", "found by the name people know")
    }

    @Test func aToggleSaysWhereItStandsAndPerformingItFlipsIt() async throws {
        let model = DocumentModel()
        try await settle(model)
        let before = model.orthographic
        let ortho = try #require(model.paletteItems().first { $0.title == "Orthographic Projection" })
        #expect(ortho.detail == (before ? "On" : "Off"))
        ortho.perform()
        #expect(model.orthographic == !before)
    }

    @Test func theCommandIsInTheShortcutsList() {
        #expect(ShortcutCommand.all.contains(.palette))
        #expect(Shortcuts.label(.palette) == "⌘K")
        let chords = ShortcutCommand.all.filter { $0.scope == .app }.compactMap(\.defaultChord)
        #expect(Set(chords.map(\.label)).count == chords.count, "⌘K is not taken by another command")
    }
}

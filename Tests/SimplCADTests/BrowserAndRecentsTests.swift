// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

@Suite @MainActor struct BrowserAndRecentsTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func selectingInTheViewportHighlightsTheBodyOrSketchInTheBrowser() async throws {
        let model = DocumentModel(document: .demo())
        try await settle(model)
        #expect(model.browserHighlights.isEmpty)
        model.click(PickID(body: 0, face: 0), additive: false)
        #expect(model.browserHighlights == ["plate"], "a face highlights its body")
        model.click(PickID(body: 0, edge: 0), additive: false)
        #expect(model.browserHighlights == ["plate"], "so does an edge")
        let slot = try #require(model.sketchSlots.firstIndex(of: "base")) + 1
        model.click(PickID(region: 0, slot: slot), additive: false)
        #expect(model.browserHighlights == ["base"], "a profile highlights its sketch")
        model.clearSelection()
        #expect(model.browserHighlights.isEmpty)
        try await settle(model)
    }

    @Test func recentPartsKeepTheirOrderAndSkipMissingFiles() throws {
        let saved = UserDefaults.standard.stringArray(forKey: RecentParts.key)
        let savedRemoved = UserDefaults.standard.stringArray(forKey: RecentParts.removedKey)
        defer {
            UserDefaults.standard.set(saved, forKey: RecentParts.key)
            UserDefaults.standard.set(savedRemoved, forKey: RecentParts.removedKey)
        }
        UserDefaults.standard.removeObject(forKey: RecentParts.key)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A.simplcad"), b = dir.appendingPathComponent("B.simplcad")
        for url in [a, b] { try Data("{}".utf8).write(to: url) }

        RecentParts.note(a)
        RecentParts.note(b)
        RecentParts.note(a)  // opened again: back to the top, not twice
        #expect(Array(RecentParts.urls.prefix(2)).map(\.lastPathComponent) == ["A.simplcad", "B.simplcad"])
        try FileManager.default.removeItem(at: b)
        #expect(!RecentParts.urls.contains { $0.lastPathComponent == "B.simplcad" }, "a deleted file drops out")
        RecentParts.remove(a)
        #expect(!RecentParts.urls.contains { $0.lastPathComponent == "A.simplcad" }, "removed, even from macOS's own list")
        RecentParts.note(a)
        #expect(RecentParts.urls.first?.lastPathComponent == "A.simplcad", "opening it again brings it back")
    }
}

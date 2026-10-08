// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

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
        let a = dir.appendingPathComponent("A.simplmaker"), b = dir.appendingPathComponent("B.simplmaker")
        for url in [a, b] { try Data("{}".utf8).write(to: url) }

        RecentParts.note(a)
        RecentParts.note(b)
        RecentParts.note(a)  // opened again: back to the top, not twice
        #expect(Array(RecentParts.urls.prefix(2)).map(\.lastPathComponent) == ["A.simplmaker", "B.simplmaker"])
        try FileManager.default.removeItem(at: b)
        #expect(!RecentParts.urls.contains { $0.lastPathComponent == "B.simplmaker" }, "a deleted file drops out")
        RecentParts.remove(a)
        #expect(!RecentParts.urls.contains { $0.lastPathComponent == "A.simplmaker" }, "removed, even from macOS's own list")
        RecentParts.note(a)
        #expect(RecentParts.urls.first?.lastPathComponent == "A.simplmaker", "opening it again brings it back")
    }
}

/// Bodies and sketches keep the names given to them, without rebuilding the model.
@Suite @MainActor struct RenameInBrowserTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func bodiesAndSketchesTakeNewNames() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        let before = model.result?.duration
        model.renameBody("b", to: "Lid")
        model.renameFeature("b", to: "Lid box")
        #expect(model.bodies.first?.name == "Lid" && model.document.features[0].name == "Lid box")
        #expect(!model.isRegenerating && model.result?.duration == before, "names need no rebuild")
        let back = try CADDocument.decode(try model.document.encoded())
        #expect(back.bodyNames == ["b": "Lid"])
        model.renameBody("b", to: " ")
        #expect(model.bodies.first?.name == "Body1", "an empty name goes back to the default")
        #expect(model.renameParameter("nope", to: "x") != nil)
    }
}

/// A parameter can be a length, an angle or a plain number.
@Suite @MainActor struct ParameterUnitTests {
    @Test func switchingUnitsMovesPlainValues() async throws {
        var d = CADDocument(parameters: [Parameter("tilt", "10 mm"), Parameter("twice", "tilt * 2")])
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy)))]
        let model = DocumentModel(document: d)
        model.setParameterUnit("tilt", .angle)
        #expect(model.document.parameters[0].unit == .angle && model.document.parameters[0].expression == "10 deg")
        model.setParameterUnit("twice", .angle)
        #expect(model.document.parameters[1].expression == "tilt * 2", "an expression stays as it is")
        model.setParameterUnit("tilt", .none)
        #expect(model.document.parameters[0].expression == "10")
        let values = ParameterEvaluator.evaluate([Parameter("n", "12,5", unit: .none)])
        #expect(values.values["n"]?.value == 12.5)
    }

    @Test func typingAnAngleMakesTheParameterAnAngle() async throws {
        var d = CADDocument(parameters: [Parameter("angle", "10 mm")])
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy)))]
        let model = DocumentModel(document: d)
        model.setParameter("angle", expression: "60 deg")
        #expect(model.document.parameters[0].unit == .angle)
        model.setParameter("angle", expression: "5 mm")
        #expect(model.document.parameters[0].unit == .length)
        model.setParameter("angle", expression: "7")
        #expect(model.document.parameters[0].unit == .length, "a bare number keeps the unit")
    }
}

/// Dragging a parameter's name moves the sketch being edited, and dropping the preview puts it back.
@Suite @MainActor struct SketchParameterScrubTests {
    @Test func theSketchFollowsAScrubbedParameter() async throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let line = s.addLine(a, b)
        s.dimension(.length(line), "w", id: "len")
        var d = CADDocument(parameters: [Parameter("w", "10 mm")])
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        func length() -> Double { (session.sketch.measure(.length(line))) ?? -1 }
        #expect(abs(length() - 10) < 1e-6)
        model.previewParameter("w", expression: "25 mm")
        #expect(abs(length() - 25) < 1e-6, "the sketch follows while scrubbing")
        model.previewParameter("w", expression: "30 mm")
        #expect(abs(length() - 30) < 1e-6)
        model.cancelParameterPreview()
        #expect(abs(length() - 10) < 1e-6, "dropped: back to the document's value")
        #expect(model.document.parameters[0].expression == "10 mm")
        try await Task.sleep(for: .milliseconds(5))  // let the rebuilds finish before the test ends
        for _ in 0..<1000 where model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// A dimension can be deleted, and the sketch keeps the size it had.
@Suite @MainActor struct SketchDimensionDeleteTests {
    @Test func deletingADimensionKeepsTheGeometry() async throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let line = s.addLine(a, b)
        s.dimension(.length(line), "10 mm", id: "len")
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        model.sketchCommand { $0.deleteDimension("len") }
        #expect(session.sketch.dimensions.isEmpty)
        guard case .sketch(let sf)? = model.document.features.first?.kind else { Issue.record("no sketch"); return }
        #expect(sf.sketch.dimensions.isEmpty && abs((sf.sketch.measure(.length(line)) ?? 0) - 10) < 1e-6)
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Clicking a body in the browser selects the body, not the feature that made it.
@Suite @MainActor struct BrowserBodySelectionTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aBodyIsSelectedWithoutATool() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.selectBody("b")
        #expect(model.selectedBody == "b" && model.selectedFeature == nil)
        #expect(model.dragHandle == nil && model.pendingTool == nil, "no handle, no tool")
        #expect(model.highlighted == [PickID(wholeBody: 0).raw] && model.browserHighlights == ["b"])

        // Move takes the selected body straight away; Extrude doesn't mistake it for a face.
        model.run(.extrude)
        #expect(model.alert == nil && model.pendingTool == .extrude)
        model.cancelTool()
        model.selectBody("b")
        model.run(.move)
        guard case .move(let m)? = model.document.features.last?.kind else { Issue.record("expected a move"); return }
        #expect(m.bodies == ["b"])
    }
}

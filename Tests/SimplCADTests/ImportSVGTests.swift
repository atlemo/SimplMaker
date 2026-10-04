// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// File → Import SVG as Sketch….
@Suite @MainActor struct ImportSVGTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func svgFile(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\">\(body)</svg>"
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A 40 × 20 plate with a round hole, and a rounded button beside it.
    private let plate = "<path d=\"M0 0H40V20H0Z M10 10m-4 0a4 4 0 1 0 8 0a4 4 0 1 0-8 0\"/><rect x=\"50\" y=\"0\" width=\"20\" height=\"20\" rx=\"4\"/>"

    @Test func importMakesASketchWithProfiles() async throws {
        let model = DocumentModel()
        try await settle(model)
        let imported = await model.importSVG(from: try svgFile("Plate.svg", plate))
        #expect(imported)
        guard let f = model.document.features.last, case .sketch(let sf) = f.kind else { Issue.record("expected a sketch"); return }
        #expect(sf.plane == .xy && f.name == "Sketch1")
        #expect(model.selectedFeature == f.id && model.sketchSession == nil)
        try await settle(model)
        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let sk = try #require(r.sketches[f.id])
        // The plate (with the hole cut out of it), the hole's disc, and the button.
        #expect(sk.regions.count == 3, "\(sk.regions.map(\.area))")
        let areas = sk.regions.map(\.area).sorted()
        let plateArea = 40.0 * 20 - .pi * 16
        let buttonArea = 400 - 16 * (4 - Double.pi)
        for expected in [plateArea, .pi * 16, buttonArea] {
            #expect(areas.contains { abs($0 - expected) < 0.05 }, "\(expected) in \(areas)")
        }
    }

    @Test func undoRemovesTheImport() async throws {
        let model = DocumentModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        try await settle(model)
        undo.beginUndoGrouping()
        _ = await model.importSVG(from: try svgFile("Plate.svg", plate))
        undo.endUndoGrouping()
        #expect(model.document.features.count == 1)
        undo.undo()
        #expect(model.document.features.isEmpty)
    }

    @Test func importsIntoTheSketchBeingEdited() async throws {
        let model = DocumentModel()
        try await settle(model)
        model.beginSketch(on: .xz)
        let session = try #require(model.sketchSession)
        let before = session.sketch.points.count
        let imported = await model.importSVG(from: try svgFile("Plate.svg", plate))
        #expect(imported)
        #expect(model.document.features.count == 1, "no second sketch")
        #expect(model.sketchSession === session && session.sketch.points.count > before)
        guard case .sketch(let sf)? = model.document.features.first?.kind else { Issue.record("expected a sketch"); return }
        #expect(sf.plane == .xz && sf.sketch.curves.count == session.sketch.curves.count && !sf.sketch.curves.isEmpty)
    }

    @Test func aFileThatIsNotSVGShowsWhy() async throws {
        let model = DocumentModel()
        try await settle(model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).svg")
        try Data("not an svg".utf8).write(to: url)
        let imported = await model.importSVG(from: url)
        #expect(!imported)
        #expect(model.document.features.isEmpty)
        #expect(model.alert?.title.contains("couldn't be imported") == true)
    }

    @Test func textInTheFileIsReported() async throws {
        let model = DocumentModel()
        try await settle(model)
        _ = await model.importSVG(from: try svgFile("Label.svg", "<rect width=\"10\" height=\"10\"/><text>Hi</text>"))
        #expect(model.alert?.message.contains("text") == true)
        #expect(model.document.features.count == 1)
    }
}

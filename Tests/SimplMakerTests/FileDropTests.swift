// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Files dropped on the window are imported like File ▸ Import does it.
@Suite @MainActor struct FileDropTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitForFeatures(_ model: DocumentModel, _ count: Int) async throws {
        for _ in 0..<2000 where model.document.features.count < count || model.isImporting { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func droppedFileProvidersImportAStepAndAnSVG() async throws {
        let model = DocumentModel()
        try await settle(model)
        let dir = try tempDir()
        let box = try KBody.primitive(.box(width: 20, length: 10, height: 5), on: .xy, featureID: "b")
        let step = dir.appendingPathComponent("Dropped.step")
        try KBody.exportSTEP([box], to: step)
        let svg = dir.appendingPathComponent("Shape.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20mm\" height=\"10mm\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"10\"/></svg>".utf8).write(to: svg)

        let providers = [step, svg].map { NSItemProvider(object: $0 as NSURL) }
        #expect(model.importDropped(providers: providers))
        try await waitForFeatures(model, 2)
        let kinds = model.document.features.map { f -> String in
            switch f.kind { case .importBody: return "import"; case .sketch: return "sketch"; default: return "other" }
        }
        #expect(kinds == ["import", "sketch"], "\(kinds)")
    }

    @Test func anUnsupportedFileIsExplainedAndNothingIsAdded() async throws {
        let model = DocumentModel()
        try await settle(model)
        let url = try tempDir().appendingPathComponent("Notes.txt")
        try Data("hello".utf8).write(to: url)
        model.importDropped([url])
        #expect(model.alert?.title == "Notes.txt can't be imported")
        #expect(model.document.features.isEmpty)
    }

    @Test func extensionsAreMatchedWithoutRegardToCase() {
        #expect(DroppedFileKind(URL(fileURLWithPath: "/a/B.STP")) != nil)
        #expect(DroppedFileKind(URL(fileURLWithPath: "/a/B.Dxf")) != nil)
        #expect(DroppedFileKind(URL(fileURLWithPath: "/a/B.png")) == nil)
    }
}

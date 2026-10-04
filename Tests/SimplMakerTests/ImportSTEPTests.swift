// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// File → Import STEP… and the inspector's Replace File….
@Suite @MainActor struct ImportSTEPTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A box of the given size written to a STEP file.
    private func stepFile(_ name: String, width: Double) throws -> URL {
        let box = try KBody.primitive(.box(width: width, length: 10, height: 5), on: .xy, featureID: "b")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try KBody.exportSTEP([box], to: url)
        return url
    }

    @Test func importAddsABodyNamedAfterTheFile() async throws {
        let model = DocumentModel()
        try await settle(model)
        let url = try stepFile("Bracket.step", width: 20)
        let imported = await model.importSTEP(from: url)
        #expect(imported)
        guard let f = model.document.features.last, case .importBody(let i) = f.kind else { Issue.record("expected an import"); return }
        #expect(i.fileName == "Bracket.step" && f.name == "Import1")
        #expect(model.selectedFeature == f.id && model.document.bodyNames[f.id] == "Bracket")
        try await settle(model)
        let r = try #require(model.result)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(model.bodies.map(\.name) == ["Bracket"])
        #expect(abs((r.body(f.id)?.volume ?? 0) - 1000) < 1e-6)

        // A new version of the file replaces the geometry and keeps the feature.
        let v2 = try stepFile("Bracket v2.stp", width: 40)
        let replaced = await model.replaceImport(f.id, from: v2)
        #expect(replaced)
        try await settle(model)
        #expect(model.document.features.count == 1)
        #expect(abs((model.result?.body(f.id)?.volume ?? 0) - 2000) < 1e-6)
    }

    @Test func aFileThatIsNotSTEPShowsWhy() async throws {
        let model = DocumentModel()
        try await settle(model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).step")
        try Data("not a step file".utf8).write(to: url)
        let imported = await model.importSTEP(from: url)
        #expect(!imported)
        #expect(model.document.features.isEmpty)
        #expect(model.alert?.title.contains("couldn't be imported") == true)
    }
}

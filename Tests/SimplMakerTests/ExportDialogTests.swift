// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct ExportDialogTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func twoBoxes() -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy))),
                      Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, operation: .newBody)))]
        return d
    }

    private func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("simplmaker-export-dialog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func individualPartsGetOneFileEachNamedAfterTheBody() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for stl in [true, false] {
            let written = model.writeIndividually(model.bodies, stl: stl, into: dir)
            #expect(written.map(\.lastPathComponent).sorted() == (stl ? ["Body1.stl", "Body2.stl"] : ["Body1.step", "Body2.step"]))
            for url in written { #expect((try? Data(contentsOf: url).count) ?? 0 > 100) }
        }
    }

    @Test func fileNamesAreSafeDifferentAndNeverOverExistingFiles() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("Lid.stl"))
        let urls = DocumentModel.exportFileURLs(for: ["Lid", "Base", "base", "a/b"], extension: "stl", in: dir)
        #expect(urls.map(\.lastPathComponent) == ["Lid 2.stl", "Base.stl", "base 2.stl", "b.stl"])
    }

    @Test func cancellingTheDialogWritesNothing() async throws {
        let model = DocumentModel(document: twoBoxes())
        try await settle(model)
        var asked: Int?
        model.exportChoice = { asked = $0; return nil }
        model.exportWithDialog()
        #expect(asked == 2)
        #expect(model.alert == nil)
    }

    @Test func nothingToExportSaysSoWithoutAsking() async throws {
        let model = DocumentModel(document: CADDocument())
        try await settle(model)
        var asked = false
        model.exportChoice = { _ in asked = true; return nil }
        model.exportWithDialog()
        #expect(!asked && model.alert?.title == "There's nothing to export")
    }
}

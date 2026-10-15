// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// File → Import → STEP… and STL…, and the inspector's Replace File….
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

    @Test func anSTLFileImportsAsABodyToo() async throws {
        let model = DocumentModel()
        try await settle(model)
        let box = try KBody.primitive(.box(width: 20, length: 10, height: 5), on: .xy, featureID: "b")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Block.stl")
        try KBody.exportSTL([box], to: url)
        #expect(await model.importSTEP(from: url))
        try await settle(model)
        let f = try #require(model.document.features.last)
        #expect(model.document.bodyNames[f.id] == "Block")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        #expect(abs((model.result?.body(f.id)?.volume ?? 0) - 1000) < 1e-3)

        // A mesh with a hole in it is refused with a reason.
        let open = dir.appendingPathComponent("Open.stl")
        try Data("solid o\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid o".utf8).write(to: open)
        #expect(!(await model.importSTEP(from: open)))
        #expect(model.alert?.message.contains("watertight") == true, "\(model.alert?.message ?? "")")
        #expect(model.document.features.count == 1)
    }

    /// A sphere of 20 mm across written as a fine STL mesh, with more triangles than the importer is comfortable with.
    /// Made away from the main actor: the export takes about a second, and the tests running alongside need the main actor.
    @concurrent nonisolated private func bigSTL() async throws -> (url: URL, triangles: Int) {
        let sphere = try KBody.primitive(.sphere(diameter: 20), on: .xy, featureID: "s")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Ball.stl")
        try KBody.exportSTL([sphere], to: url, deflection: 0.0005)
        return (url, try #require(KBody.stlTriangleCount(try Data(contentsOf: url))))
    }

    @Test func aBigMeshCanBeReducedOnImport() async throws {
        let model = DocumentModel()
        try await settle(model)
        let (url, triangles) = try await bigSTL()
        #expect(triangles > DocumentModel.comfortableSTLTriangles, "\(triangles) triangles")
        var asked: (String, Int)?
        model.meshReduction = { name, count in asked = (name, count); return .reduce(to: 4_000) }
        #expect(await model.importSTEP(from: url))
        #expect(asked?.0 == "Ball.stl" && asked?.1 == triangles)
        try await settle(model)
        let f = try #require(model.document.features.last)
        guard case .importBody(let i) = f.kind else { Issue.record("expected an import"); return }
        // What the part keeps is the reduced mesh, not the file.
        let kept = try #require(KBody.stlTriangleCount(i.data))
        #expect(kept <= 4_000 && kept > 2_000, "\(kept) triangles kept")
        #expect(i.fileName == "Ball.stl")
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
        let exact = 4.0 / 3.0 * Double.pi * 1000
        let volume = model.result?.body(f.id)?.volume ?? 0
        #expect(volume > exact * 0.97 && volume < exact * 1.01, "\(volume) vs \(exact)")
    }

    @Test func cancellingTheQuestionImportsNothing() async throws {
        let model = DocumentModel()
        try await settle(model)
        let (url, _) = try await bigSTL()
        model.meshReduction = { _, _ in .cancel }
        #expect(!(await model.importSTEP(from: url)))
        #expect(model.document.features.isEmpty)
        #expect(model.alert == nil)
    }

    @Test func aSmallMeshIsNotQuestioned() async throws {
        let model = DocumentModel()
        try await settle(model)
        var asked = false
        model.meshReduction = { _, _ in asked = true; return .cancel }
        let box = try KBody.primitive(.box(width: 20, length: 10, height: 5), on: .xy, featureID: "b")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).stl")
        try KBody.exportSTL([box], to: url)
        #expect(await model.importSTEP(from: url))
        #expect(!asked)
    }

    @Test func theSizesOnOfferStayBelowTheMeshAndTheFirstIsTheLargestComfortableOne() {
        let big = DocumentModel.meshReductionChoices(for: 400_000)
        #expect(big.sizes.map(\.triangles) == [60_000, 30_000, 10_000] && big.sizes[big.first].triangles == 30_000)
        let medium = DocumentModel.meshReductionChoices(for: 50_000)
        #expect(medium.sizes.map(\.triangles) == [30_000, 10_000] && medium.sizes[medium.first].triangles == 30_000)
        let small = DocumentModel.meshReductionChoices(for: 20_000)
        #expect(small.sizes.map(\.triangles) == [10_000] && small.first == 0)
    }

    @Test func reducingAMeshShowsProgressInsteadOfTheStartCard() async throws {
        let model = DocumentModel()
        try await settle(model)
        let (url, _) = try await bigSTL()
        model.meshReduction = { _, _ in .reduce(to: 4_000) }
        var seen: [String] = []
        var fractions: [Double] = []
        let importing = Task { await model.importSTEP(from: url) }
        var finished = false
        Task { _ = await importing.value; finished = true }
        while !finished {
            if let p = model.importProgress {
                if seen.last != p.title { seen.append(p.title) }
                if let f = p.fraction { fractions.append(f) }
            }
            if model.isImporting || model.importProgress != nil { #expect(model.document.features.isEmpty) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen == ["Reducing the mesh…", "Building the solid…"], "\(seen)")
        // (Other tests reduce meshes at the same time and share the kernel's counter, so only the range is checked.)
        #expect(!fractions.isEmpty && fractions.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(fractions.count) readings")
        #expect(model.importProgress == nil && !model.isImporting)
        #expect(model.document.features.count == 1)
        try await settle(model)  // the rebuild that shows the body, so the model isn't dropped while it is tessellating
    }

    @Test func aSecondImportWaitsUntilTheFirstIsDone() async throws {
        let model = DocumentModel()
        try await settle(model)
        let (big, _) = try await bigSTL()
        model.meshReduction = { _, _ in .reduce(to: 4_000) }
        let first = Task { await model.importSTEP(from: big) }
        while !model.isImporting { try await Task.sleep(for: .milliseconds(2)) }

        // While the first is being reduced, a second file, of any kind, is turned away with a reason.
        let small = try stepFile("Small.step", width: 5)
        #expect(!(await model.importSTEP(from: small)))
        #expect(model.alert?.title == "An import is already in progress", "\(model.alert?.title ?? "")")
        #expect(model.alert?.message.contains("Wait for it to finish") == true)
        #expect(!(await model.importSVG(from: small)))
        model.alert = nil
        model.importSTL()  // would open the file picker, so it must stop before that
        #expect(model.alert?.title == "An import is already in progress")
        model.alert = nil

        // The first one is not disturbed by that.
        #expect(await first.value)
        #expect(model.alert == nil)
        #expect(model.document.features.count == 1)
        try await settle(model)

        // Once it is done, the next goes in.
        #expect(await model.importSTEP(from: small))
        #expect(model.document.features.count == 2)
        try await settle(model)
        #expect(model.result?.errors.isEmpty == true, "\(model.result?.errors ?? [:])")
    }
}

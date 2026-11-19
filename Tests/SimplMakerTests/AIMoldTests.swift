// create_mold, get_mold and export_mold through the AI interface; the tools come with the Mold workspace.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite(.serialized) @MainActor struct AIMoldTests {
    private typealias Rig = (service: CADService, id: String, model: DocumentModel, rig: AIServiceTests.Rig)

    private func open() async throws -> Rig {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        model.undoManager = UndoManager()
        _ = try await rig.service.change(documentID: id, expectedRevision: nil,
                                         try AIOperationParser.parse(tool: "create_box", arguments: ["width": 30, "length": 20, "height": 20, "id": "b"]))
        return (rig.service, id, model, rig)
    }

    private func args(_ pairs: [String: JSONValue]) -> AIArguments { AIArguments(.object(pairs)) }

    private func withMoldEnabled(_ body: () async throws -> Void) async throws {
        try await Workspace.$moldOverride.withValue(true) {
            try await body()
        }
    }

    @Test func theToolsAreOfferedOnlyWithTheWorkspace() async throws {
        let t = try await open()
        let off = Workspace.$moldOverride.withValue(false) { AITools.make(service: t.service).map(\.name) }
        #expect(!off.contains("create_mold") && !off.contains("get_mold") && !off.contains("export_mold"))
        try await withMoldEnabled {
            let on = AITools.make(service: t.service).map(\.name)
            #expect(on.contains("create_mold") && on.contains("get_mold") && on.contains("export_mold"))
            #expect(AIDesignGuide.topic("make_a_mold") != nil)
        }
        Workspace.$moldOverride.withValue(false) { #expect(AIDesignGuide.topic("make_a_mold") == nil) }
    }

    @Test func aMoldIsMadeReadAndChanged() async throws {
        try await withMoldEnabled {
            let t = try await open()
            let made = try await t.service.createMold(documentID: t.id, expectedRevision: nil, args(["body_id": "b"]))
            let mold = try #require(made.mold)
            #expect(made.success && mold.status == "built" && mold.error == nil, "\(made.message)")
            #expect((mold.siliconeMl ?? 0) > 12 && (mold.siliconeMl ?? 0) < 20, "a 30 × 20 × 20 body is 12 mL: \(String(describing: mold.siliconeMl))")
            #expect(mold.halves?.count == 2 && mold.wall == "10 mm" && mold.keys)
            #expect(t.model.document.molds.count == 1)
            #expect(made.revision == t.model.documentRevision)

            // Changed by its id: only what is sent changes.
            let changed = try await t.service.createMold(documentID: t.id, expectedRevision: nil,
                                                         args(["mold_id": .string(mold.id), "wall": 14, "vents": [[3, 0, 18]], "pour": "+z", "keys": false]))
            let after = try #require(changed.mold)
            #expect(after.wall == "14 mm" && !after.keys && after.vents == [[3, 0, 18]] && after.name == mold.name && after.status == "built")
            #expect((after.blockMm?[0] ?? 0) > (mold.blockMm?[0] ?? 0))

            let read = try await t.service.getMolds(documentID: t.id)
            #expect(read.molds.map(\.id) == [mold.id] && read.molds.first?.siliconeMl == after.siliconeMl)

            let gone = try await t.service.createMold(documentID: t.id, expectedRevision: nil, args(["mold_id": .string(mold.id), "delete": true]))
            #expect(gone.mold == nil && t.model.document.molds.isEmpty)
        }
    }

    @Test func aMoldThatCannotBeBuiltIsSavedWithItsReason() async throws {
        try await withMoldEnabled {
            let t = try await open()
            let made = try await t.service.createMold(documentID: t.id, expectedRevision: nil, args(["body_id": "b", "parting": "x", "parting_offset": 100]))
            #expect(made.success && made.mold?.status == "failed" && made.mold?.error?.contains("does not cut") == true, "\(made.message)")
            #expect(t.model.document.molds.count == 1, "kept so it can be fixed")
        }
    }

    @Test func mistakesAreSaidInWords() async throws {
        try await withMoldEnabled {
            let t = try await open()
            func refusal(_ pairs: [String: JSONValue]) async -> AIError? {
                do { _ = try await t.service.createMold(documentID: t.id, expectedRevision: nil, args(pairs)) } catch { return error as? AIError }
                return nil
            }
            #expect(await refusal(["body_id": "nothing"])?.code == .featureNotFound)
            #expect(await refusal(["mold_id": "nothing"])?.code == .featureNotFound)
            #expect(await refusal([:])?.code == .invalidArguments, "neither a body nor a mold")
            #expect(await refusal(["body_id": "b", "pour": "sideways"])?.code == .invalidArguments)
            #expect(await refusal(["body_id": "b", "parting": "diagonal"])?.code == .invalidArguments)
            #expect(await refusal(["body_id": "b", "gate_point": [1, 2]])?.code == .invalidArguments)
            #expect(await refusal(["body_id": "b", "colour": "red"])?.code == .invalidArguments, "an unknown argument is refused")
            #expect(t.model.document.molds.isEmpty, "nothing is left behind by a refused call")
            let stale = try? await t.service.createMold(documentID: t.id, expectedRevision: -5, args(["body_id": "b"]))
            #expect(stale == nil)
        }
    }

    @Test func theHalvesAreExportedLaidOutForPrinting() async throws {
        try await withMoldEnabled {
            let t = try await open()
            _ = try await t.service.createMold(documentID: t.id, expectedRevision: nil, args(["body_id": "b"]))
            let name = "moldtest-\(UUID().uuidString.prefix(8))"
            let out = try await t.service.exportMold(documentID: t.id, moldID: nil, format: "stl", fileName: name)
            defer { try? FileManager.default.removeItem(atPath: out.path) }
            #expect(out.success && out.bytes > 1000 && out.path.hasSuffix("\(name).stl") && out.bodies.count == 2, "\(out)")
            let none = try? await t.service.exportMold(documentID: t.id, moldID: nil, format: "dxf", fileName: nil)
            #expect(none == nil)
        }
    }
}

// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The Split workspace's model: a split is made of a body, follows it, is edited and deleted, and shows its pieces.
@Suite(.serialized) @MainActor struct SplitStudioTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<2000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func settleSplits(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<2000 where model.splitBuilding || model.splitResults.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Models made by the test in hand: each is let finish what it started before the test ends (a rebuild still on its thread when the
    /// process exits crashes it).
    private static var made: [DocumentModel] = []

    private func finishing(_ body: () async throws -> Void) async throws {
        try await body()
        for model in Self.made {
            try await Task.sleep(for: .milliseconds(5))
            for _ in 0..<2000 where model.splitBuilding || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        }
        Self.made = []
        try await Task.sleep(for: .milliseconds(150))
    }

    /// A long box, 300 mm: too long for a 256 mm bed.
    private func part(length: String = "300 mm") async throws -> DocumentModel {
        var d = CADDocument()
        d.parameters = [Parameter("len", length)]
        d.features = [Feature(id: "box", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "len", length: "60 mm", height: "40 mm")))]
        let model = DocumentModel(document: d)
        Self.made.append(model)
        try await settle(model)
        return model
    }

    @Test func theSplitWorkspaceShowsEveryBodyUntilOneIsClicked() async throws {
        try await finishing {
            var d = CADDocument()
            d.features = [Feature(id: "a", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20 mm", length: "20 mm", height: "20 mm"))),
                          Feature(id: "b", name: "Box2", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "60 mm", width: "20 mm", length: "20 mm", height: "20 mm")))]
            let model = DocumentModel(document: d)
            Self.made.append(model)
            try await settle(model)
            model.setWorkspace(.split)
            #expect(model.choosingWorkspaceBody && Set(model.visibleMeshes.map(\.id)) == ["a", "b"])
            let mesh = try #require(model.meshes.first { $0.id == "a" }).mesh
            let xs = stride(from: 0, to: mesh.positions.count - 2, by: 3).map { mesh.positions[$0] }
            let ys = stride(from: 1, to: mesh.positions.count - 1, by: 3).map { mesh.positions[$0] }
            model.chooseWorkspaceBody(origin: SIMD3(Double((xs.min()! + xs.max()!) / 2), Double((ys.min()! + ys.max()!) / 2), 500), direction: SIMD3(0, 0, -1))
            #expect(!model.choosingWorkspaceBody && model.document.printSplits.first?.body == "a")
            try await settleSplits(model)
            #expect(model.visibleMeshes.allSatisfy { $0.id.hasPrefix("split~") }, "only the chosen body's pieces")
            model.deleteSplit(try #require(model.document.printSplits.first).id)
            #expect(model.choosingWorkspaceBody && Set(model.visibleMeshes.map(\.id)) == ["a", "b"])
        }
    }

    @Test func splittingABodyOpensTheWorkspaceAndBuildsThePieces() async throws {
        try await finishing {
            let model = try await part()
            model.makeSplit(of: "box")
            #expect(model.workspace == .split)
            let split = try #require(model.document.printSplits.first)
            #expect(split.body == "box" && split.name == "Body1 split" && model.activeSplitID == split.id)
            try await settleSplits(model)
            let result = try #require(model.splitResults[split.id])
            #expect(result.isBuilt && result.pieces.count == 2 && result.allFit, "\(result.error ?? "")")
            #expect(model.visibleMeshes.map(\.id) == [split.pieceID(1), split.pieceID(2)], "the viewport draws the pieces, not the body")
            #expect(model.splitTint(of: split.pieceID(1)) != nil)
            #expect(model.splitStatusText.contains("2 pieces") && model.splitStatusText.contains("fit"), "\(model.splitStatusText)")
            #expect(!model.showTimeline, "the Split workspace has no timeline")
        }
    }

    @Test func aSplitFollowsItsBodyWhenAParameterChanges() async throws {
        try await finishing {
            let model = try await part()
            model.makeSplit(of: "box")
            try await settleSplits(model)
            let id = try #require(model.activeSplitID)
            #expect(model.splitResults[id]?.pieces.count == 2)
            // A shorter part fits in one piece.
            model.setParameter("len", expression: "200 mm")
            try await settle(model)
            try await settleSplits(model)
            for _ in 0..<2000 where model.splitResults[id]?.pieces.count != 1 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.splitResults[id]?.pieces.count == 1)
        }
    }

    @Test func changingTheSettingsRebuildsAndIsOneUndoStep() async throws {
        try await finishing {
            let model = try await part()
            model.makeSplit(of: "box")
            try await settleSplits(model)
            let id = try #require(model.activeSplitID)
            // A small printer needs more pieces.
            model.updateSplit(id, "Change Printer") { $0.printer = "bambu-a1-mini" }
            for _ in 0..<2000 where model.splitBuilding || model.splitResults[id]?.pieces.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.splitResults[id]?.printerVolume == SIMD3(180, 180, 180))
            #expect(model.splitResults[id]?.pieces.count == 2, "300 mm fits two pieces on 180 mm with room for a pin (rotated: 174 mm usable)")
            model.updateSplit(id, "Change Cuts") { $0.counts = [4, 0, 0] }
            for _ in 0..<2000 where model.splitBuilding || model.splitResults[id]?.pieces.count != 4 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.splitResults[id]?.pieces.count == 4)
        }
    }

    @Test func cuttingByHandKeepsTheCutsThatAreThere() async throws {
        try await finishing {
            let model = try await part()
            model.makeSplit(of: "box")
            try await settleSplits(model)
            let id = try #require(model.activeSplitID)
            model.setSplitCutsByHand(id, true)
            #expect(model.activeSplit?.cuts?.map(\.position) == ["0 mm"], "the automatic cut across the middle is kept: \(String(describing: model.activeSplit?.cuts))")
            model.setSplitCutsByHand(id, false)
            #expect(model.activeSplit?.cuts == nil)
        }
    }

    @Test func deletingASplitLeavesTheBodyAndTheWorkspace() async throws {
        try await finishing {
            let model = try await part()
            model.makeSplit(of: "box")
            try await settleSplits(model)
            let id = try #require(model.activeSplitID)
            model.deleteSplit(id)
            #expect(model.document.printSplits.isEmpty && model.activeSplitID == nil && model.splitResults[id] == nil)
            #expect(model.choosingWorkspaceBody && model.visibleMeshes.map(\.id) == ["box"], "back to choosing: the body, to click")
            model.setWorkspace(.design)
            #expect(model.visibleMeshes.map(\.id) == ["box"])
            #expect(model.showTimeline == true, "the timeline comes back when the workspace is left")
        }
    }

    @Test func theWorkspaceSitsBetweenDesignAndMold() {
        let all = Workspace.allCases
        #expect(all.firstIndex(of: .split) == all.firstIndex(of: .design)! + 1)
        #expect(all.firstIndex(of: .mold) == all.firstIndex(of: .split)! + 1)
        #expect(Workspace.split.hasTools)
    }

    @Test func openingAPieceApartMovesEachPieceAwayFromTheMiddle() async throws {
        try await finishing {
            let model = try await part()
            model.makeSplit(of: "box")
            try await settleSplits(model)
            #expect(model.splitOpenOffsets.isEmpty, "closed")
            model.splitOpenAmount = 1
            let offsets = model.splitOpenOffsets
            #expect(offsets.count == 2 && offsets[0].x < 0 && offsets[1].x > 0 && offsets[0].y == 0)
        }
    }
}

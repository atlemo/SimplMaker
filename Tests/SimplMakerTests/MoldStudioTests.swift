// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The Mold workspace's model: a mold is made around a body, follows it, is edited and deleted, and shows its halves.
@Suite(.serialized) @MainActor struct MoldStudioTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<2000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Waits for the molds to be worked out.
    private func settleMolds(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<2000 where model.moldBuilding || model.moldResults.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Models made by the test in hand: each is let finish what it started before the test ends (a rebuild still on its thread when
    /// the process exits crashes it).
    private static var made: [DocumentModel] = []

    /// The workspace is only on offer while it is being built: these tests switch it on and put it back.
    private func withMoldEnabled(_ body: () async throws -> Void) async throws {
        try await Workspace.$moldOverride.withValue(true) {
            try await body()
            for model in Self.made {
                try await Task.sleep(for: .milliseconds(5))
                for _ in 0..<2000 where model.moldBuilding || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
            }
            Self.made = []
        }
    }

    private func part() async throws -> DocumentModel {
        var d = CADDocument()
        d.parameters = [Parameter("w", "30 mm")]
        d.features = [Feature(id: "box", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "w", length: "20 mm", height: "20 mm")))]
        let model = DocumentModel(document: d)
        Self.made.append(model)
        try await settle(model)
        return model
    }

    @Test func makingAMoldOpensTheWorkspaceAndBuildsTheHalves() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            #expect(model.workspace == .mold)
            let mold = try #require(model.document.molds.first)
            #expect(mold.body == "box" && mold.name == "Body1 mold" && model.activeMoldID == mold.id)
            try await settleMolds(model)
            let result = try #require(model.moldResults[mold.id])
            #expect(result.isBuilt, "\(result.error ?? "")")
            // The viewport draws the body, then the two halves, and the halves carry their tints.
            #expect(model.visibleMeshes.map(\.id) == ["box", mold.halfIDs.behind, mold.halfIDs.front])
            #expect(model.displayOpacity(of: "box") < 1)
            #expect(model.displayColor(of: mold.halfIDs.behind) != model.displayColor(of: mold.halfIDs.front))
            // Leaving it brings the part's own scene back.
            model.setWorkspace(.design)
            #expect(model.visibleMeshes.map(\.id) == ["box"])
            #expect(model.displayOpacity(of: "box") == 1)
        }
    }

    @Test func theShortestSideIsWhatTheMoldIsPartedAcross() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            #expect(model.document.molds.first?.parting == .middle(.y) || model.document.molds.first?.parting == .middle(.z))
        }
    }

    @Test func aSettingChangeRebuildsTheMoldAndIsOneUndoableChange() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            try await settleMolds(model)
            let id = try #require(model.activeMold?.id)
            let before = try #require(model.moldResults[id]).blockSize
            model.updateMold(id, "Change Wall") { $0.wall = "15 mm" }
            #expect(model.document.molds.first?.wall == "15 mm")
            try await settleMolds(model)
            for _ in 0..<2000 where model.moldResults[id]?.blockSize == before { try await Task.sleep(for: .milliseconds(5)) }
            let after = try #require(model.moldResults[id]).blockSize
            #expect(after.x > before.x, "a thicker wall makes a bigger block: \(before) → \(after)")
        }
    }

    @Test func theMoldFollowsItsBodyWhenAParameterChanges() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            try await settleMolds(model)
            let id = try #require(model.activeMold?.id)
            let before = try #require(model.moldResults[id]).blockSize.x
            model.setParameter("w", expression: "50 mm")
            try await settle(model)
            for _ in 0..<2000 where model.moldResults[id]?.blockSize.x == before { try await Task.sleep(for: .milliseconds(5)) }
            let after = try #require(model.moldResults[id]).blockSize.x
            #expect(abs(after - 70) < 1e-6, "50 mm body + 2 × 10 mm wall, was \(before) → \(after)")
        }
    }

    @Test func aMoldWhoseBodyIsGoneSaysSo() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.mutate("Make Mold") { $0.molds = [MoldSetup(id: "m", name: "Lost", body: "nothing")] }
            model.setWorkspace(.mold)
            try await settleMolds(model)
            #expect(model.moldResults["m"]?.error?.contains("gone") == true, "\(String(describing: model.moldResults["m"]?.error))")
            #expect(model.moldStatusText.contains("gone"))
        }
    }

    @Test func deletingAMoldTakesItsHalvesAway() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            try await settleMolds(model)
            let id = try #require(model.activeMold?.id)
            model.deleteMold(id)
            #expect(model.document.molds.isEmpty && model.moldResults[id] == nil && model.moldShownMeshes.isEmpty)
        }
    }

    @Test func aSecondMoldOfTheSameBodyGetsAnotherName() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            model.makeMold(of: "box")
            #expect(model.document.molds.map(\.name) == ["Body1 mold", "Body1 mold 2"])
        }
    }

    @Test func vendsAreAddedAtThePickedSpotAndTheGateCanBePlaced() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            try await settleMolds(model)
            model.toggleMoldPick(.vent)
            #expect(model.moldShownMeshes.count == 1, "only the body is shown while a spot is picked")
            model.placeMoldPoint(SIMD3(5, 3, 20))
            #expect(model.document.molds.first?.vents == [MoldPoint(5, 3, 20)])
            #expect(model.moldPicking == .vent, "the next click makes another vent")
            model.toggleMoldPick(.gate)
            model.placeMoldPoint(SIMD3(-4, 2, 20))
            #expect(model.document.molds.first?.gatePoint == MoldPoint(-4, 2, 20))
            #expect(model.moldPicking == nil, "the gate is one click")
        }
    }
}

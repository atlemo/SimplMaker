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

    /// Runs `body`, then lets every model it made finish what it started.
    private func withMoldEnabled(_ body: () async throws -> Void) async throws {
        try await body()
        for model in Self.made {
            try await Task.sleep(for: .milliseconds(5))
            for _ in 0..<2000 where model.moldBuilding || model.isRegenerating { try await Task.sleep(for: .milliseconds(5)) }
        }
        Self.made = []
        // The build's thread is still letting go of its bodies when the model says it is done: give it the moment it needs.
        try await Task.sleep(for: .milliseconds(150))
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
            #expect(model.visibleMeshes.map(\.id) == ["box", mold.halfIDs.behind, mold.halfIDs.front, "mold~\(mold.id)~gate"], "the body, the halves and a marker at the gate")
            #expect(model.displayOpacity(of: "box") < 1)
            #expect(model.displayColor(of: mold.halfIDs.behind) != model.displayColor(of: mold.halfIDs.front))
            // Leaving it brings the part's own scene back.
            model.setWorkspace(.design)
            #expect(model.visibleMeshes.map(\.id) == ["box"])
            #expect(model.displayOpacity(of: "box") == 1)
        }
    }

    @Test func aNewMoldStartsOnTheAxisWithoutAnUndercut() async throws {
        try await withMoldEnabled {
            var d = CADDocument()
            d.features = [
                Feature(id: "disc", name: "Disc", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "6 mm", diameter: "44 mm"))),
                Feature(id: "stem", name: "Stem", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "30 mm", diameter: "12 mm", operation: .join, target: "disc"))),
            ]
            let model = DocumentModel(document: d)
            Self.made.append(model)
            try await settle(model)
            model.makeMold(of: "disc")
            #expect(model.document.molds.first?.parting != .middle(.z), "\(String(describing: model.document.molds.first?.parting))")
            try await settleMolds(model)
            #expect(model.activeMoldResult?.analysis?.hasUndercuts == false)
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
            #expect(model.moldShownMeshes.map(\.id) == ["box", "mold~\(model.activeMold!.id)~gate"], "only the body and the marker while a spot is picked")
            model.placeMoldPoint(SIMD3(5, 3, 20))
            #expect(model.document.molds.first?.vents == [MoldPoint(5, 3, 20)])
            #expect(model.moldPicking == .vent, "the next click makes another vent")
            model.toggleMoldPick(.gate)
            model.placeMoldPoint(SIMD3(-4, 2, 20))
            #expect(model.document.molds.first?.gatePoint == MoldPoint(-4, 2, 20))
            #expect(model.moldPicking == nil, "the gate is one click")
        }
    }

    @Test func theCheckViewShowsTheBodyAloneColouredByRelease() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            try await settleMolds(model)
            model.toggleMoldCheck()
            #expect(model.moldShownMeshes.map(\.id).first == "box" && !model.moldShownMeshes.contains { $0.id.hasSuffix("~front") })
            #expect(model.displayOpacity(of: "box") == 1, "solid, so its colours can be read")
            let looks = model.faceLooks(for: model.visibleMeshes)
            #expect(looks.first?.count == model.meshes.first?.mesh.faceNames.count, "every face has a colour: \(looks.first?.count ?? -1)")
            #expect(Set(looks.first?.values.compactMap(\.color) ?? []).count >= 2, "the top and the sides differ")
            #expect(model.moldStatusText.contains("Green"))
            model.setWorkspace(.design)
            #expect(!model.moldCheckView, "leaving the workspace turns the view off")
        }
    }

    @Test func automaticVentsGoAtTheLobesTheGateDoesNotReach() async throws {
        try await withMoldEnabled {
            var d = CADDocument()
            d.features = [
                Feature(id: "b", name: "B", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "50 mm", length: "20 mm", height: "10 mm"))),
                Feature(id: "p1", name: "P1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "-12 mm", height: "25 mm", diameter: "6 mm", operation: .join, target: "b"))),
                Feature(id: "p2", name: "P2", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "12 mm", height: "21 mm", diameter: "6 mm", operation: .join, target: "b"))),
            ]
            let model = DocumentModel(document: d)
            Self.made.append(model)
            try await settle(model)
            model.makeMold(of: "b")
            try await settleMolds(model)
            model.addAutomaticVents()
            let mold = try #require(model.activeMold)
            #expect(mold.vents.count == 1 && abs(mold.vents[0].x - 12) < 0.5 && abs(mold.vents[0].z - 21) < 0.2, "\(mold.vents)")
            try await settleMolds(model)
            for _ in 0..<2000 where model.moldResults[mold.id]?.ventPoints.count != 1 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.moldShownMeshes.contains { $0.id.contains("~vent") }, "a marker for the vent")
            model.addAutomaticVents()
            #expect(model.document.molds.first?.vents.count == 1 && model.moldNote?.contains("already") == true)
        }
    }

    @Test func aBodyWithOneTopSaysNoVentsAreNeeded() async throws {
        try await withMoldEnabled {
            let model = try await part()
            model.makeMold(of: "box")
            try await settleMolds(model)
            model.addAutomaticVents()
            #expect(model.document.molds.first?.vents.isEmpty == true)
            #expect(model.moldNote?.contains("No trapped air") == true && model.moldStatusText.contains("No trapped air"))
        }
    }

    @Test func rigidResinRefusesAnUndercutAndTheCheckViewStillShowsIt() async throws {
        try await withMoldEnabled {
            var d = CADDocument()
            d.features = [
                Feature(id: "disc", name: "Disc", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "5 mm", diameter: "40 mm"))),
                Feature(id: "stem", name: "Stem", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "20 mm", diameter: "10 mm", operation: .join, target: "disc"))),
            ]
            let model = DocumentModel(document: d)
            Self.made.append(model)
            try await settle(model)
            model.makeMold(of: "disc")
            let id = try #require(model.activeMold?.id)
            model.updateMold(id, "Parting") { $0.parting = .middle(.z); $0.casting = .resin }
            for _ in 0..<2000 where model.moldBuilding || model.moldResults[id]?.error == nil { try await Task.sleep(for: .milliseconds(5)) }
            let r = try #require(model.moldResults[id])
            #expect(r.error?.contains("can not be released") == true, "\(r.error ?? "")")
            #expect(r.analysis?.hasUndercuts == true)
            model.toggleMoldCheck()
            let looks = model.faceLooks(for: model.visibleMeshes)
            let red = Renderer.FaceLook(color: DocumentModel.releaseColor(.undercut), material: 0, roughness: -1)
            #expect(looks.first?.values.contains(red) == true, "the undercut face is red")
        }
    }
}

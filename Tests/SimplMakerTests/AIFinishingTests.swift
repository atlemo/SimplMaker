// Fillets and chamfers made through the AI interface.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIFinishingTests {
    private func open() async -> (service: CADService, id: String, model: DocumentModel, undo: UndoManager, rig: AIServiceTests.Rig) {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        let undo = UndoManager()
        model.undoManager = undo
        return (rig.service, id, model, undo, rig)
    }

    private func refusal(_ body: () async throws -> Void) async -> AIError? {
        do { try await body() } catch { return error as? AIError }
        return nil
    }

    private func volume(_ model: DocumentModel) -> Double { model.result?.bodies.first?.body.volume ?? 0 }

    /// A 100 × 50 × 20 box, the id of its top face, and one of its 100 mm top edges.
    private func boxWithTop(_ t: (service: CADService, id: String, model: DocumentModel, undo: UndoManager, rig: AIServiceTests.Rig))
        async throws -> (top: String, longEdge: String) {
        _ = try await t.service.createBox(documentID: t.id, CADService.BoxRequest(width: "100", length: "50", height: "20", id: "base"))
        let body = try await t.service.getBody(documentID: t.id, bodyID: "base")
        let top = try #require(body.faces.first { $0.facing == "+z" }).id
        let edge = try #require(body.edges.first { $0.faces.contains(top) && abs($0.length - 100) < 1e-6 })
        return (top, edge.id)
    }

    @Test func aFilletRoundsOneEdgeAndIsOneUndoStep() async throws {
        let t = await open()
        let (_, edge) = try await boxWithTop(t)
        let before = volume(t.model)
        let r = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: [edge], size: "2", id: "round")
        let f = try #require(r.feature)
        #expect(f.type == "Fillet" && f.name == "Fillet1" && f.status == "ok" && r.message.contains("1 edge"))
        #expect(f.parameters["size"] == .quantity(expression: "2", value: 2, unit: "mm"))
        let removed = (1 - Double.pi / 4) * 4 * 100
        #expect(abs((before - volume(t.model)) - removed) < 0.5, "\(before - volume(t.model)) vs \(removed)")
        #expect(t.undo.undoActionName == "AI: Create Fillet")
        t.undo.undo()
        #expect(t.model.document.features.count == 1)
    }

    @Test func aConcaveFilletScoopsTheEdgeAndOnlyFilletsMayBeConcave() async throws {
        let t = await open()
        let (_, edge) = try await boxWithTop(t)
        let before = volume(t.model)
        let r = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: [edge], size: "2", concave: true, id: "cove")
        #expect(r.message.contains("concave"), "\(r.message)")
        // A quarter disc of radius 2 along 100 mm.
        #expect(abs((before - volume(t.model)) - Double.pi * 100) < 1)
        let chamfer = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: false, edges: [edge], size: "1", concave: true) }
        #expect(chamfer?.code == .invalidArguments)
    }

    @Test func aFaceStandsForEveryEdgeAroundIt() async throws {
        let t = await open()
        let (top, _) = try await boxWithTop(t)
        let r = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, faces: [top], size: "3")
        #expect(r.message.contains("4 edges"), "\(r.message)")
        #expect(t.model.result?.errors.isEmpty == true)
        let body = try await t.service.getBody(documentID: t.id, bodyID: "base")
        #expect(body.faces.contains { $0.shape == "cylinder" }, "the rounded edges are cylinders")
    }

    @Test func aChamferCutsAFlatBevel() async throws {
        let t = await open()
        let (_, edge) = try await boxWithTop(t)
        let before = volume(t.model)
        let r = try await t.service.createEdgeFinish(documentID: t.id, fillet: false, edges: [edge], size: "2")
        let f = try #require(r.feature)
        #expect(f.type == "Chamfer", "\(f.type)")
        #expect(f.parameters["mode"] == .text("equal_distance"), "\(String(describing: f.parameters["mode"]))")
        #expect(abs((before - volume(t.model)) - 200) < 0.5, "\(before - volume(t.model))")
    }

    @Test func aChamferWithTwoDistancesAndWithAnAngle() async throws {
        let t = await open()
        let (_, edge) = try await boxWithTop(t)
        let r = try await t.service.createEdgeFinish(documentID: t.id, fillet: false, edges: [edge], size: "2", mode: .twoDistances, second: "4")
        #expect(r.feature?.parameters["second"] == .quantity(expression: "4", value: 4, unit: "mm"))
        #expect(abs((100_000 - volume(t.model)) - 0.5 * 2 * 4 * 100) < 0.5)
        let missing = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: false, edges: [edge], size: "1", mode: .distanceAngle) }
        #expect(missing?.code == .invalidArguments && missing?.message.contains("second is required") == true)
    }

    @Test func badInputIsRefusedAndNothingChanges() async throws {
        let t = await open()
        let (_, edge) = try await boxWithTop(t)
        let revision = t.model.documentRevision
        let none = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, size: "1") }
        #expect(none?.code == .invalidArguments)
        let zero = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: [edge], size: "0") }
        #expect(zero?.code == .invalidValue)
        let ghost = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: ["edge:base/nope"], size: "1") }
        #expect(ghost?.code == .featureNotFound)
        let wrongKind = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: ["face:base/x"], size: "1") }
        #expect(wrongKind?.code == .invalidArguments)
        let noBody = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: ["edge:other/x"], size: "1") }
        #expect(noBody?.code == .featureNotFound)
        let secondOnFillet = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: [edge], size: "1", second: "2") }
        #expect(secondOnFillet?.code == .invalidArguments)
        #expect(t.model.documentRevision == revision && t.model.document.features.count == 1)
    }

    @Test func aRadiusThatCannotBeBuiltLeavesThePartAlone() async throws {
        let t = await open()
        let (top, _) = try await boxWithTop(t)
        let revision = t.model.documentRevision
        let error = await refusal { _ = try await t.service.createEdgeFinish(documentID: t.id, fillet: false, faces: [top], size: "60") }
        #expect(error?.code == .rebuildFailed, "\(String(describing: error))")
        #expect(t.model.documentRevision == revision && t.model.document.features.count == 1)
    }

    @Test func theSizeCanBeChangedLaterWithModifyFeature() async throws {
        let t = await open()
        let (_, edge) = try await boxWithTop(t)
        let r = try await t.service.createEdgeFinish(documentID: t.id, fillet: true, edges: [edge], size: "1", id: "round")
        let fid = try #require(r.feature?.id)
        let d = try await t.service.getFeature(documentID: t.id, featureID: fid)
        #expect(d.editable == ["size"])
        let m = try await t.service.modifyFeature(documentID: t.id, featureID: fid, settings: ["size": 3], unlink: false)
        #expect(m.changes.first?.after == .quantity(expression: "3 mm", value: 3, unit: "mm"))
        #expect(abs((100_000 - volume(t.model)) - (1 - Double.pi / 4) * 9 * 100) < 0.5)
    }

    @Test func aBatchCanFilletWhatAnEarlierStepMade() async throws {
        let t = await open()
        let (top, _) = try await boxWithTop(t)
        let r = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Rounded block", [
            CreateBoxOperation(box: CADService.BoxRequest(width: "40", length: "40", height: "10", id: "block")),
            EdgeFinishOperation(fillet: true, edges: [], faces: [top], size: "1", mode: .equalDistance, second: nil,
                                flipped: false, name: nil, id: nil),
        ])
        #expect(r.steps.count == 2 && t.model.document.features.count == 3, "\(r)")
        #expect(t.undo.undoActionName == "AI: Rounded block")
    }

    @Test func parsedFromToolArguments() throws {
        let op = try AIOperationParser.parse(tool: "create_chamfer", arguments: [
            "edges": ["edge:base/a"], "size": 1.5, "mode": "distance_angle", "second": 30, "flipped": true,
        ])
        let e = try #require(op as? EdgeFinishOperation)
        #expect(!e.fillet && e.size == "1.5 mm" && e.mode == .distanceAngle && e.second == "30 deg" && e.flipped)
        #expect(throws: AIError.self) { _ = try AIOperationParser.parse(tool: "create_fillet", arguments: ["edges": ["edge:a/b"], "size": 1, "mode": "two_distances"]) }
        #expect(throws: AIError.self) { _ = try AIOperationParser.parse(tool: "create_fillet", arguments: ["size": 1, "radius": 2]) }
    }

    @Test func aBatchThatStartsWithParametersLeavesAPartThatFollowsThem() async throws {
        let t = await open()
        let steps: [any AIOperation] = [
            try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "width", "value": 40]),
            try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "edge_r", "value": 2]),
            try AIOperationParser.parse(tool: "create_box", arguments: ["width": "width", "length": "width * 0.5", "height": 10, "id": "block"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Block", steps)
        #expect(t.model.document.parameters.map(\.name).sorted() == ["edge_r", "width"])
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "width", "value": 60]))
        let bounds = try #require(t.model.result?.bodies.first?.body.bounds)
        #expect(abs((bounds.max.x - bounds.min.x) - 60) < 0.1 && abs((bounds.max.y - bounds.min.y) - 30) < 0.1, "everything follows the parameter")
    }
}

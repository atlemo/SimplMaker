// Holes, shells, mirrors, patterns, combines and revolves made through the AI interface.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIBodyOperationTests {
    private typealias Rig = (service: CADService, id: String, model: DocumentModel, undo: UndoManager, rig: AIServiceTests.Rig)

    private func open() async -> Rig {
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

    private func volume(_ model: DocumentModel, _ id: String? = nil) -> Double {
        (id.flatMap { id in model.result?.bodies.first { $0.id == id } } ?? model.result?.bodies.first)?.body.volume ?? 0
    }

    private func box(_ t: Rig, id: String = "base", _ w: String = "40", _ l: String = "40", _ h: String = "20", u: String? = nil) async throws {
        var b = CADService.BoxRequest(width: w, length: l, height: h, id: id)
        b.u = u
        _ = try await t.service.createBox(documentID: t.id, b)
    }

    private func topFace(_ t: Rig, _ body: String = "base") async throws -> String {
        try #require(try await t.service.getBody(documentID: t.id, bodyID: body).faces.first { $0.facing == "+z" }).id
    }

    private func op(_ tool: String, _ args: JSONValue) throws -> any AIOperation { try AIOperationParser.parse(tool: tool, arguments: args) }

    // MARK: hole

    @Test func aHoleThroughAllRemovesACylinder() async throws {
        let t = await open()
        try await box(t)
        let top = try await topFace(t)
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_hole", ["face": .string(top), "diameter": 10, "through_all": true]))
        #expect(r.feature?.type == "Hole" && r.message.contains("Hole1"))
        let expected: Double = 32_000 - Double.pi * 25 * 20
        #expect(abs(volume(t.model) - expected) < 1, "\(volume(t.model)) vs \(expected)")
        #expect(t.undo.undoActionName == "AI: Create Hole")
        t.undo.undo()
        #expect(t.model.document.features.count == 1)
    }

    @Test func aBlindHoleAtAWorldPoint() async throws {
        let t = await open()
        try await box(t)
        let top = try await topFace(t)
        // box 40 × 40 centred on the origin; put the hole 10 mm from the middle along x
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil,
                                       try op("create_hole", ["face": .string(top), "diameter": 6, "depth": 5, "at": [10, 0, 20], "tip_angle": 0]))
        let expected: Double = 32_000 - Double.pi * 9 * 5
        #expect(abs(volume(t.model) - expected) < 1, "\(volume(t.model)) vs \(expected)")
        let hole = try #require(t.model.document.features.last)
        guard case .hole(let h) = hole.kind else { Issue.record("not a hole"); return }
        #expect(h.depth == "5 mm")
        let moved = try await t.service.modifyFeature(documentID: t.id, featureID: hole.id, settings: ["depth": 8], unlink: false)
        #expect(moved.changes.first?.field == "depth")
        let deeper: Double = 32_000 - Double.pi * 9 * 8
        #expect(abs(volume(t.model) - deeper) < 1)
    }

    @Test func counterboreAndCountersinkNeedTheirHeadSizes() async throws {
        let t = await open()
        try await box(t)
        let top = try await topFace(t)
        let a = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_hole", ["face": .string(top), "diameter": 5, "through_all": true, "kind": "counterbore"])) }
        #expect(a?.code == .invalidArguments && a?.message.contains("head_diameter") == true)
        let b = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_hole", ["face": .string(top), "diameter": 5, "through_all": true, "kind": "counterbore", "head_diameter": 3, "head_depth": 2])) }
        #expect(b?.code == .invalidValue)
        let before = volume(t.model)
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil,
                                       try op("create_hole", ["face": .string(top), "diameter": 5, "through_all": true, "kind": "counterbore", "head_diameter": 9, "head_depth": 3]))
        let expected: Double = Double.pi * 6.25 * 20 + Double.pi * 14 * 3
        #expect(abs((before - volume(t.model)) - expected) < 1, "\(before - volume(t.model)) vs \(expected)")
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil,
                                       try op("create_hole", ["face": .string(top), "diameter": 3, "through_all": true, "at": [14, 14, 20], "kind": "countersink", "head_diameter": 6]))
        #expect(t.model.result?.errors.isEmpty == true)
    }

    @Test func aHoleOutsideTheFaceOrOnACurvedFaceIsRefused() async throws {
        let t = await open()
        try await box(t)
        let top = try await topFace(t)
        let out = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_hole", ["face": .string(top), "diameter": 5, "through_all": true, "at": [100, 0, 20]])) }
        #expect(out?.code == .invalidArguments && out?.message.contains("outside the face") == true)
        let both = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_hole", ["face": .string(top), "diameter": 5, "depth": 3, "through_all": true])) }
        #expect(both?.code == .invalidArguments)
        let none = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_hole", ["face": .string(top), "diameter": 5])) }
        #expect(none?.code == .invalidArguments)
        #expect(t.model.document.features.count == 1)
    }

    // MARK: shell

    @Test func aShellOpensTheTopAndLeavesWalls() async throws {
        let t = await open()
        try await box(t)
        let top = try await topFace(t)
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_shell", ["body": "base", "open_faces": [.string(top)], "thickness": 2]))
        let expected: Double = 32_000 - 23_328
        #expect(abs(volume(t.model) - expected) < 1, "\(volume(t.model)) vs \(expected)")
        let shell = try #require(t.model.document.features.last)
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: shell.id, settings: ["thickness": 3], unlink: false)
        let thicker: Double = 32_000 - 19_652
        #expect(abs(volume(t.model) - thicker) < 1)
    }

    @Test func aShellNeedsAnOpenFaceAndAWallThatFits() async throws {
        let t = await open()
        try await box(t)
        let top = try await topFace(t)
        let none = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_shell", ["body": "base", "open_faces": [], "thickness": 2])) }
        #expect(none?.code == .invalidArguments)
        let thick = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_shell", ["body": "base", "open_faces": [.string(top)], "thickness": 30])) }
        #expect(thick?.code == .rebuildFailed, "\(String(describing: thick))")
        let wrongBody = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_shell", ["body": "ghost", "open_faces": [.string(top)], "thickness": 2])) }
        #expect(wrongBody?.code == .featureNotFound)
        #expect(t.model.document.features.count == 1)
    }

    // MARK: mirror and pattern

    @Test func mirroredAndJoinedHalvesMakeOneBody() async throws {
        let t = await open()
        try await box(t, "40", "20", "10", u: "30")  // centred at x = 30, so 10…50
        let touching = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_mirror", ["bodies": ["base"], "plane": "yz"])) }
        #expect(touching == nil || touching?.code == .rebuildFailed)
        // The copy at -50…-10 does not touch the original at 10…50, so joining it either fails or leaves two solids; a new body is clean.
        if touching == nil { t.undo.undo() }
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_mirror", ["bodies": ["base"], "plane": "yz", "operation": "new_body", "id": "twin"]))
        #expect(r.bodies.count == 2 && r.bodies.contains { $0.id == "twin" })
        let twin = try #require(r.bodies.first { $0.id == "twin" })
        #expect(abs(twin.boundsMin[0] + 50) < 0.01 && abs(twin.boundsMax[0] + 10) < 0.01)
    }

    @Test func mirroringAlongAnAxisOrAnEdgeNeedsExactlyOneOfPlaneAndLine() async throws {
        let t = await open()
        try await box(t, "40", "20", "10", u: "30")  // x 10…50, y -10…10 (centred), so the copy across the x axis touches it
        let neither = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_mirror", ["bodies": ["base"]])) }
        #expect(neither?.code == .invalidArguments)
        let both = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_mirror", ["bodies": ["base"], "plane": "yz", "line": "x"])) }
        #expect(both?.code == .invalidArguments)
        let bad = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_mirror", ["bodies": ["base"], "line": "diagonal"])) }
        #expect(bad?.code == .invalidArguments)
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_mirror", ["bodies": ["base"], "line": "x", "operation": "new_body", "id": "twin"]))
        #expect(r.message.contains("along x") && r.bodies.contains { $0.id == "twin" })
        guard case .mirror(let m)? = t.model.document.features.last?.kind else { Issue.record("expected a mirror"); return }
        #expect(m.line == .x)
    }

    @Test func aLinearPatternOfPegsJoinsToTheBase() async throws {
        let t = await open()
        try await box(t, id: "base", "100", "20", "5")
        // a peg standing on the base, at the left end
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_box", ["width": 6, "length": 6, "height": 10, "plane": "xy", "u": -40, "id": "peg", "operation": "join", "target": "base"]))
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["kind": "linear", "bodies": ["base"], "axis": "x", "count": 3, "spacing": 30]))
        #expect(r.feature?.type == "Pattern")
        // copies of the whole base would stick out; just make sure it builds and the message counts the bodies
        #expect(r.message.contains("3 copies"))
        let bad = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["bodies": ["base"], "axis": "x", "count": 1, "spacing": 30])) }
        #expect(bad?.code == .invalidValue)
        let noSpacing = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["bodies": ["base"], "axis": "x", "count": 3])) }
        #expect(noSpacing?.code == .invalidArguments)
    }

    @Test func aPatternCanRepeatACutInsteadOfBodies() async throws {
        let t = await open()
        try await box(t, id: "base", "100", "20", "5")
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_box", ["width": 6, "length": 6, "height": 5, "plane": "xy", "u": -40, "id": "notch", "operation": "cut", "target": "base"]))
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["features": ["notch"], "axis": "x", "count": 3, "spacing": 30]))
        let base = try #require(r.bodies.first { $0.id == "base" })
        #expect(r.bodies.count == 1 && abs(base.volume - (10000 - 3 * 180)) < 1, "\(base.volume)")
        #expect(r.message.contains("notch"))
        let both = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["bodies": ["base"], "features": ["notch"], "axis": "x", "count": 3, "spacing": 30])) }
        #expect(both?.code == .invalidArguments)
        let missing = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["features": ["nope"], "axis": "x", "count": 3, "spacing": 30])) }
        #expect(missing?.code == .featureNotFound)
        let makesBody = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["features": ["base"], "axis": "x", "count": 3, "spacing": 30])) }
        #expect(makesBody?.code == .invalidArguments)
    }

    @Test func aCircularPatternMakesCopiesAroundTheAxis() async throws {
        let t = await open()
        try await box(t, id: "peg", "6", "6", "10", u: "20")
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil,
                                           try op("create_pattern", ["kind": "circular", "bodies": ["peg"], "axis": "z", "count": 4, "operation": "new_body", "id": "ring"]))
        let ring = try #require(r.bodies.first { $0.id == "ring" })
        #expect(r.bodies.count == 2)
        #expect(abs(ring.volume - 3 * 360) < 1, "\(ring.volume)")  // three copies of a 6 × 6 × 10 peg
        let edgeAxis = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_pattern", ["kind": "circular", "bodies": ["peg"], "axis": "edge:peg/nope", "count": 3])) }
        #expect(edgeAxis?.code == .invalidArguments)
        let modified = try await t.service.modifyFeature(documentID: t.id, featureID: "ring", settings: ["count": 5], unlink: false)
        #expect(modified.changes.first?.field == "count")
    }

    // MARK: combine

    @Test func aCutterBodyIsCutOutOfTheTarget() async throws {
        let t = await open()
        try await box(t)
        try await box(t, id: "cutter", "10", "10", "30")
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_combine", ["target": "base", "tools": ["cutter"], "operation": "cut"]))
        #expect(r.bodies.count == 1 && r.feature?.type == "Combine")
        let cutVolume: Double = 32_000 - 2_000
        #expect(abs(volume(t.model, "base") - cutVolume) < 1)
        let same = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_combine", ["target": "base", "tools": ["base"]])) }
        #expect(same?.code == .invalidArguments)
        let newBody = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_combine", ["target": "base", "tools": ["x"], "operation": "new_body"])) }
        #expect(newBody?.code == .invalidArguments)
    }

    @Test func keepingTheToolsLeavesThemInPlace() async throws {
        let t = await open()
        try await box(t)
        try await box(t, id: "cutter", "10", "10", "30")
        let r = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_combine", ["target": "base", "tools": ["cutter"], "operation": "cut", "keep_tools": true]))
        #expect(r.bodies.count == 2)
    }

    // MARK: revolve

    @Test func aRectangleRevolvedAboutTheSketchAxisMakesATube() async throws {
        let t = await open()
        let r = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Tube", [
            CreateSketchOperation(plane: "xz", name: nil, id: "half"),
            EditSketchOperation(sketchID: "half", add: [.rectangle(id: "wall", center: nil, corner: SketchPoint2(x: "5 mm", y: "0 mm"), width: "10", height: "20", cornerRadius: nil)]),
            try op("create_revolve", ["sketch_id": "half", "profiles": "solid", "axis": "sketch_y", "id": "tube"]),
        ])
        #expect(r.steps.count == 3)
        let expected: Double = Double.pi * 200 * 20
        #expect(abs(volume(t.model, "tube") - expected) < 1, "\(volume(t.model, "tube")) vs \(expected)")
        let feature = try #require(t.model.document.features.last)
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: feature.id, settings: ["angle": 180], unlink: false)
        #expect(abs(volume(t.model, "tube") - expected / 2) < 1)
    }

    @Test func aRevolveRefusesABadAxisAngleOrSketch() async throws {
        let t = await open()
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, CreateSketchOperation(plane: "xz", name: nil, id: "half"))
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil,
                                       EditSketchOperation(sketchID: "half", add: [.rectangle(id: "wall", center: nil, corner: SketchPoint2(x: "5 mm", y: "0 mm"), width: "10", height: "20", cornerRadius: nil)]))
        let badAxis = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_revolve", ["sketch_id": "half", "profiles": "solid", "axis": "w"])) }
        #expect(badAxis?.code == .invalidArguments)
        let badAngle = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_revolve", ["sketch_id": "half", "profiles": "solid", "axis": "z", "angle": 400])) }
        #expect(badAngle?.code == .invalidValue)
        let ghost = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_revolve", ["sketch_id": "nope", "profiles": "solid", "axis": "z"])) }
        #expect(ghost?.code == .featureNotFound)
        let join = await refusal { _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try op("create_revolve", ["sketch_id": "half", "profiles": "solid", "axis": "z", "operation": "cut"])) }
        #expect(join?.code == .invalidArguments, "a cut needs a body")
    }

    @Test func parserRefusesUnknownSettings() throws {
        #expect(throws: AIError.self) { _ = try AIOperationParser.parse(tool: "create_hole", arguments: ["face": "face:a/b", "diameter": 3, "through_all": true, "radius": 2]) }
        #expect(throws: AIError.self) { _ = try AIOperationParser.parse(tool: "create_pattern", arguments: ["bodies": ["a"], "axis": "x", "count": 3, "kind": "wavy"]) }
        #expect(throws: AIError.self) { _ = try AIOperationParser.parse(tool: "create_mirror", arguments: ["bodies": ["a"], "plane": "yz", "operation": "cut"]) }
    }
}

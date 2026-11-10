// Sweeps, lofts, threads, drafts, planes, moves, scales, and files, made through the AI interface.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIShapingTests {
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

    private func op(_ tool: String, _ args: JSONValue) throws -> any AIOperation { try AIOperationParser.parse(tool: tool, arguments: args) }
    private func run(_ t: Rig, _ tool: String, _ args: JSONValue) async throws -> ChangeResult {
        try await t.service.change(documentID: t.id, expectedRevision: nil, try op(tool, args))
    }

    private func volume(_ t: Rig, _ id: String) -> Double { t.model.result?.bodies.first { $0.id == id }?.body.volume ?? 0 }
    /// The tight box (the kernel's own bounds are padded a little).
    private func bounds(_ t: Rig, _ id: String) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        (try? t.model.result?.bodies.first { $0.id == id }?.body.measure(.body))?.bounds
    }

    private func box(_ t: Rig, id: String = "base", _ w: Double = 40, _ l: Double = 40, _ h: Double = 20) async throws {
        _ = try await run(t, "create_box", ["width": .double(w), "length": .double(l), "height": .double(h), "id": .string(id)])
    }

    /// A circle sketch extruded: a round shaft standing on the xy plane.
    private func shaft(_ t: Rig, diameter: Double, height: Double, id: String = "shaft") async throws {
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "\(id)_sk"),
            EditSketchOperation(sketchID: "\(id)_sk", add: [.circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: AIValues.number(diameter), radius: nil)]),
            try op("create_extrude", ["sketch_id": .string("\(id)_sk"), "profiles": "solid", "distance": .double(height), "id": .string(id)]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Shaft", steps)
    }

    // MARK: plane, move, scale

    @Test func aConstructionPlaneCanBeSketchedOnAndMovedLater() async throws {
        let t = await open()
        let r = try await run(t, "create_plane", ["base": "xy", "offset": 15, "id": "mid"])
        #expect(r.feature?.type == "Plane" && r.message.contains("plane:mid"))
        _ = try await run(t, "create_sketch", ["plane": "plane:mid", "id": "s"])
        let moved = try await t.service.modifyFeature(documentID: t.id, featureID: "mid", settings: ["offset": 25], unlink: false)
        #expect(moved.changes.first?.field == "offset")
        let bad = await refusal { _ = try await run(t, "create_plane", ["base": "plane:ghost"]) }
        #expect(bad?.code == .invalidArguments)
    }

    @Test func aMoveShiftsABodyAndItsValuesCanBeChanged() async throws {
        let t = await open()
        try await box(t)
        let before = try #require(bounds(t, "base"))
        let r = try await run(t, "create_move", ["bodies": ["base"], "dx": 50, "dz": 5, "id": "shift"])
        #expect(r.feature?.type == "Move")
        let after = try #require(bounds(t, "base"))
        #expect(abs(after.min.x - before.min.x - 50) < 0.05 && abs(after.min.z - before.min.z - 5) < 0.05)
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: "shift", settings: ["dx": 10], unlink: false)
        let again = try #require(bounds(t, "base"))
        #expect(abs(again.min.x - before.min.x - 10) < 0.05)
        let nothing = await refusal { _ = try await run(t, "create_move", ["bodies": ["base"]]) }
        #expect(nothing?.code == .invalidArguments)
        let ghost = await refusal { _ = try await run(t, "create_move", ["bodies": ["ghost"], "dx": 1]) }
        #expect(ghost?.code == .featureNotFound)
    }

    @Test func aTurnStandsABodyOnItsSide() async throws {
        let t = await open()
        try await box(t, id: "base", 40, 20, 10)
        _ = try await run(t, "create_move", ["bodies": ["base"], "ry": 90])
        let b = try #require(bounds(t, "base"))
        #expect(abs((b.max.x - b.min.x) - 10) < 0.1 && abs((b.max.z - b.min.z) - 40) < 0.1, "\(b)")
    }

    @Test func aTurnCanBeAboutAPivotPoint() async throws {
        let t = await open()
        try await box(t, id: "base", 40, 20, 10)
        let before = try #require(bounds(t, "base"))
        let pivot = SIMD3(before.max.x, before.max.y, before.min.z)  // a corner of the box
        _ = try await run(t, "create_move", ["bodies": ["base"], "rz": 90, "px": .double(pivot.x), "py": .double(pivot.y), "pz": .double(pivot.z)])
        let b = try #require(bounds(t, "base"))
        // The box was 40 by 20 and lay at x -40…0, y -20…0 from that corner; a quarter turn puts it at x 0…20, y -40…0.
        #expect(abs(b.min.x - pivot.x) < 0.1 && abs(b.max.x - (pivot.x + 20)) < 0.1, "\(b)")
        #expect(abs(b.max.y - pivot.y) < 0.1 && abs(b.min.y - (pivot.y - 40)) < 0.1, "\(b)")
        let partial = await refusal { _ = try await run(t, "create_move", ["bodies": ["base"], "rz": 90, "px": 5]) }
        #expect(partial?.code == .invalidArguments)
    }

    @Test func aScaleMultipliesTheVolumeByTheCube() async throws {
        let t = await open()
        try await box(t)
        let before = volume(t, "base")
        _ = try await run(t, "create_scale", ["bodies": ["base"], "factor": 2, "id": "big"])
        #expect(abs(volume(t, "base") - before * 8) < 1)
        let one = await refusal { _ = try await run(t, "create_scale", ["bodies": ["base"], "factor": 1]) }
        #expect(one?.code == .invalidValue)
        let zero = await refusal { _ = try await run(t, "create_scale", ["bodies": ["base"], "factor": 0]) }
        #expect(zero?.code == .invalidValue)
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: "big", settings: ["factor": 3], unlink: false)
        #expect(abs(volume(t, "base") - before * 27) < 1)
    }

    // MARK: draft

    @Test func aDraftLeansTheWallsAwayFromTheBottom() async throws {
        let t = await open()
        try await box(t)
        let body = try await t.service.getBody(documentID: t.id, bodyID: "base")
        let walls = body.faces.filter { ["+x", "-x", "+y", "-y"].contains($0.facing ?? "") }.map(\.id)
        let bottom = try #require(body.faces.first { $0.facing == "-z" }).id
        #expect(walls.count == 4)
        let before = volume(t, "base")
        let r = try await run(t, "create_draft", ["body": "base", "faces": .array(walls.map { .string($0) }), "fixed_face": .string(bottom), "angle": 5])
        #expect(r.feature?.type == "Draft")
        #expect(volume(t, "base") < before - 100, "\(volume(t, "base")) vs \(before)")
        let bad = await refusal { _ = try await run(t, "create_draft", ["body": "base", "faces": .array(walls.map { .string($0) }), "fixed_face": .string(bottom), "angle": 90]) }
        #expect(bad?.code == .invalidValue)
        let same = await refusal { _ = try await run(t, "create_draft", ["body": "base", "faces": [.string(bottom)], "fixed_face": .string(bottom), "angle": 3]) }
        #expect(same?.code == .invalidArguments)
    }

    // MARK: sweep and loft

    @Test func aCircleSweptAlongALineMakesACylinder() async throws {
        let t = await open()
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "prof"),
            EditSketchOperation(sketchID: "prof", add: [.circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: "6", radius: nil)]),
            CreateSketchOperation(plane: "xz", name: nil, id: "route"),
            EditSketchOperation(sketchID: "route", add: [.line(id: "rail", from: SketchPoint2(x: "0 mm", y: "0 mm"), to: SketchPoint2(x: "0 mm", y: "30 mm"))]),
            try op("create_sweep", ["sketch_id": "prof", "profiles": "solid", "path_sketch": "route", "path": ["rail"], "id": "pipe"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Pipe", steps)
        let expected: Double = Double.pi * 9 * 30
        #expect(abs(volume(t, "pipe") - expected) < 1, "\(volume(t, "pipe")) vs \(expected)")
        let same = await refusal { _ = try await run(t, "create_sweep", ["sketch_id": "prof", "profiles": "solid", "path_sketch": "prof", "path": ["c"]]) }
        #expect(same?.code == .invalidArguments)
        let ghost = await refusal { _ = try await run(t, "create_sweep", ["sketch_id": "prof", "profiles": "solid", "path_sketch": "route", "path": ["nope"]]) }
        #expect(ghost?.code == .featureNotFound)
    }

    @Test func aLoftBlendsASquareIntoACircle() async throws {
        let t = await open()
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "low"),
            EditSketchOperation(sketchID: "low", add: [.rectangle(id: "sq", center: SketchPoint2(x: "0 mm", y: "0 mm"), corner: nil, width: "20", height: "20", cornerRadius: nil)]),
            try op("create_plane", ["base": "xy", "offset": 20, "id": "top"]),
            CreateSketchOperation(plane: "plane:top", name: nil, id: "high"),
            EditSketchOperation(sketchID: "high", add: [.circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: "10", radius: nil)]),
            try op("create_loft", ["sections": [["sketch_id": "low", "profile": "solid"], ["sketch_id": "high", "profile": "solid"]], "id": "funnel"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Funnel", steps)
        let b = try #require(bounds(t, "funnel"))
        #expect(abs(b.max.z - 20) < 0.05 && abs(b.min.z) < 0.05, "\(b)")
        let v = volume(t, "funnel")
        let low: Double = 400 * 20, high: Double = Double.pi * 25 * 20
        #expect(v > high && v < low, "\(v)")
        let one = await refusal { _ = try await run(t, "create_loft", ["sections": [["sketch_id": "low", "profile": "solid"]]]) }
        #expect(one?.code == .invalidArguments)
    }

    @Test func aLoftFollowsAPath() async throws {
        let t = await open()
        let sections: JSONValue = [["sketch_id": "low", "profile": "solid"], ["sketch_id": "high", "profile": "solid"]]
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "low"),
            EditSketchOperation(sketchID: "low", add: [.rectangle(id: "sq", center: SketchPoint2(x: "0 mm", y: "0 mm"), corner: nil, width: "20", height: "20", cornerRadius: nil)]),
            try op("create_plane", ["base": "xy", "offset": 30, "id": "top"]),
            CreateSketchOperation(plane: "plane:top", name: nil, id: "high"),
            EditSketchOperation(sketchID: "high", add: [.circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: "10", radius: nil)]),
            // The path: up from the middle of the square, out to x = 15 halfway, and back to the middle of the circle.
            CreateSketchOperation(plane: "xz", name: nil, id: "route"),
            EditSketchOperation(sketchID: "route", add: [.line(id: "up", from: SketchPoint2(x: "0 mm", y: "0 mm"), to: SketchPoint2(x: "15 mm", y: "15 mm")),
                                                         .line(id: "back", from: SketchPoint2(x: "15 mm", y: "15 mm"), to: SketchPoint2(x: "0 mm", y: "30 mm"))]),
            try op("create_loft", ["sections": sections, "id": "plain"]),
            try op("create_loft", ["sections": sections, "path_sketch": "route", "path": ["up", "back"], "id": "bent"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Bent funnel", steps)
        let plain = try #require(bounds(t, "plain")), bent = try #require(bounds(t, "bent"))
        #expect(plain.max.x < 10.1 && bent.max.x > 18, "the path pushes the middle out: \(bent)")
        #expect(abs(bent.max.z - 30) < 0.05 && abs(bent.min.z) < 0.05, "\(bent)")
        let feature = try await t.service.getFeature(documentID: t.id, featureID: "bent")
        #expect("\(feature)".contains("curve:route/up"), "get_feature shows the path: \(feature)")

        let ruled = await refusal { _ = try await run(t, "create_loft", ["sections": sections, "path_sketch": "route", "path": ["up", "back"], "ruled": true]) }
        #expect(ruled?.code == .invalidArguments)
        let own = await refusal { _ = try await run(t, "create_loft", ["sections": sections, "path_sketch": "low", "path": ["sq.1"]]) }
        #expect(own != nil, "a path in a section's own sketch is refused")
    }

    // MARK: thread

    @Test func aThreadGoesOnARoundFaceAndNotAFlatOne() async throws {
        let t = await open()
        try await shaft(t, diameter: 10, height: 20)
        let body = try await t.service.getBody(documentID: t.id, bodyID: "shaft")
        let round = try #require(body.faces.first { $0.shape == "cylinder" }).id
        let flat = try #require(body.faces.first { $0.shape == "plane" }).id
        let before = volume(t, "shaft")
        let r = try await run(t, "create_thread", ["faces": [.string(round)], "size": "M10x1.5", "length": 10])
        #expect(r.feature?.type == "Thread", "\(r)")
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        #expect(volume(t, "shaft") < before, "a thread removes material")
        let notRound = await refusal { _ = try await run(t, "create_thread", ["faces": [.string(flat)], "size": "M10x1.5"]) }
        #expect(notRound?.code == .invalidArguments)
        let badSize = await refusal { _ = try await run(t, "create_thread", ["faces": [.string(round)], "size": "M7x9"]) }
        #expect(badSize?.code == .invalidArguments && badSize?.reason?.contains("M10x1.5") == true)
    }

    // MARK: files

    @Test func exportWritesAFileAndNeverOverwritesOne() async throws {
        let t = await open()
        try await box(t)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simplmaker-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await t.service.exportFile(documentID: t.id, bodyIDs: nil, format: "stl", fileName: "My Part/../x.stl", folder: folder)
        #expect(first.success && first.bytes > 100 && first.path.hasPrefix(folder.path))
        #expect(!first.path.contains(".."), "no way out of the folder: \(first.path)")
        let second = try await t.service.exportFile(documentID: t.id, bodyIDs: ["base"], format: "stl", fileName: "My Part/../x.stl", folder: folder)
        #expect(second.path != first.path && FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
        let step = try await t.service.exportFile(documentID: t.id, bodyIDs: nil, format: "step", fileName: nil, folder: folder)
        #expect(step.path.hasSuffix(".step") && step.bytes > 100)
        let threeMF = try await t.service.exportFile(documentID: t.id, bodyIDs: nil, format: "3mf", fileName: nil, folder: folder)
        #expect(threeMF.path.hasSuffix(".3mf") && threeMF.bytes > 200)
        let badFormat = await refusal { _ = try await t.service.exportFile(documentID: t.id, bodyIDs: nil, format: "obj", fileName: nil, folder: folder) }
        #expect(badFormat?.code == .invalidArguments)
        let ghost = await refusal { _ = try await t.service.exportFile(documentID: t.id, bodyIDs: ["ghost"], format: "stl", fileName: nil, folder: folder) }
        #expect(ghost?.code == .featureNotFound)
    }

    @Test func aStepFileComesBackInAsABody() async throws {
        let t = await open()
        try await box(t)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simplmaker-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await t.service.exportFile(documentID: t.id, bodyIDs: nil, format: "step", fileName: "cube", folder: folder)
        let r = try await run(t, "import_file", ["path": .string(file.path), "id": "copy", "name": "Copy"])
        #expect(r.feature?.type == "Import" && r.bodies.count == 2, "\(r)")
        #expect(abs(volume(t, "copy") - volume(t, "base")) < 1)
        #expect(t.model.document.bodyNames["copy"] == "Copy")
    }

    @Test func importRefusesWhatItShould() async throws {
        let t = await open()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simplmaker-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let junk = folder.appendingPathComponent("junk.stl")
        try Data("not a model at all".utf8).write(to: junk)
        for (path, why) in [("relative/x.step", "relative"), (text.path, "wrong type"), (folder.appendingPathComponent("missing.step").path, "missing"), (folder.path, "a folder")] {
            let e = await refusal { _ = try await run(t, "import_file", ["path": .string(path)]) }
            #expect(e?.code == .invalidArguments, "\(why): \(String(describing: e))")
        }
        let notAModel = await refusal { _ = try await run(t, "import_file", ["path": .string(junk.path)]) }
        #expect(notAModel?.code == .rebuildFailed, "\(String(describing: notAModel))")
        #expect(t.model.document.features.isEmpty)
    }

    @Test func fileNamesAreMadeSafe() {
        #expect(CADService.safeFileName("../../etc/passwd") == "passwd")
        #expect(CADService.safeFileName("   ") == "Part" && CADService.safeFileName("My Part (v2)") == "My Part (v2)")
        #expect(CADService.safeFileName(String(repeating: "a", count: 200)).count == 80)
    }
}

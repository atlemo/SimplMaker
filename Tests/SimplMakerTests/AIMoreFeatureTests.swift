// Ribs, pipes, splits, lay on floor, projections, body appearance and reference pictures, made through the AI interface.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIMoreFeatureTests {
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
    private func bounds(_ t: Rig, _ id: String) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        (try? t.model.result?.bodies.first { $0.id == id }?.body.measure(.body))?.bounds
    }

    private func box(_ t: Rig, id: String = "base", _ w: Double = 40, _ l: Double = 40, _ h: Double = 20) async throws {
        _ = try await run(t, "create_box", ["width": .double(w), "length": .double(l), "height": .double(h), "id": .string(id)])
    }

    // MARK: pipe

    private func routeSketch(_ t: Rig) async throws {
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xz", name: nil, id: "route"),
            EditSketchOperation(sketchID: "route", add: [.line(id: "rail", from: SketchPoint2(x: "0 mm", y: "0 mm"), to: SketchPoint2(x: "0 mm", y: "30 mm"))]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Route", steps)
    }

    @Test func aPipeFollowsAPathAndCanBeHollow() async throws {
        let t = await open()
        try await routeSketch(t)
        let solid = try await run(t, "create_pipe", ["path_sketch": "route", "path": ["rail"], "diameter": 6, "id": "rod"])
        #expect(solid.feature?.type == "Pipe", "\(solid)")
        #expect(abs(volume(t, "rod") - Double.pi * 9 * 30) < 1, "\(volume(t, "rod"))")
        _ = try await run(t, "create_pipe", ["path_sketch": "route", "path": ["rail"], "diameter": 6, "wall": 1, "id": "tube"])
        #expect(abs(volume(t, "tube") - Double.pi * (9 - 4) * 30) < 1, "\(volume(t, "tube"))")
        // the diameter can be changed afterwards, and a wall that leaves no hole is refused
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: "rod", settings: ["diameter": 10], unlink: false)
        #expect(abs(volume(t, "rod") - Double.pi * 25 * 30) < 2, "\(volume(t, "rod"))")
        let thick = await refusal { _ = try await run(t, "create_pipe", ["path_sketch": "route", "path": ["rail"], "diameter": 6, "wall": 3]) }
        #expect(thick?.code == .invalidValue)
        let ghost = await refusal { _ = try await run(t, "create_pipe", ["path_sketch": "route", "path": ["nope"], "diameter": 6]) }
        #expect(ghost?.code == .featureNotFound)
    }

    // MARK: rib

    @Test func aRibBracesAnUprightAgainstItsPlate() async throws {
        let t = await open()
        // An L-bracket (a plate and an upright wall joined), and a diagonal rib between them drawn in the plane y = 0.
        let steps: [any AIOperation] = [
            try op("create_box", ["width": 60, "length": 40, "height": 4, "id": "bracket"]),
            try op("create_box", ["width": 4, "length": 40, "height": 30, "u": -28, "operation": "join", "target": "bracket", "id": "upright"]),
            CreateSketchOperation(plane: "xz", name: nil, id: "brace"),
            EditSketchOperation(sketchID: "brace", add: [.line(id: "diag", from: SketchPoint2(x: "-26 mm", y: "16 mm"), to: SketchPoint2(x: "-8 mm", y: "4 mm"))]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Bracket", steps)
        let before = volume(t, "bracket")
        let r = try await run(t, "create_rib", ["path_sketch": "brace", "path": ["diag"], "thickness": 3, "target": "bracket", "id": "gusset"])
        #expect(r.feature?.type == "Rib", "\(r)")
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        #expect(volume(t, "bracket") > before + 50, "\(volume(t, "bracket")) vs \(before)")
        let thicker = try await t.service.modifyFeature(documentID: t.id, featureID: "gusset", settings: ["thickness": 6], unlink: false)
        #expect(thicker.changes.first?.field == "thickness")
        let none = await refusal { _ = try await run(t, "create_rib", ["path_sketch": "brace", "path": [], "thickness": 3]) }
        #expect(none?.code == .invalidArguments)
    }

    // MARK: split and lay on floor

    @Test func aSplitMakesTwoBodiesAndTheirIdsAreListed() async throws {
        let t = await open()
        try await box(t)
        let whole = volume(t, "base")
        let r = try await run(t, "create_split", ["bodies": ["base"], "plane": "yz", "id": "halves"])
        #expect(r.feature?.type == "Split", "\(r)")
        let bodies = try #require(t.model.result?.bodies)
        #expect(bodies.count == 2, "\(bodies.map(\.id))")
        #expect(abs(bodies.map(\.body.volume).reduce(0, +) - whole) < 0.01)
        #expect(abs(bodies[0].body.volume - whole / 2) < 0.01)
        #expect(r.bodies.count == 2)
        let two = await refusal { _ = try await run(t, "create_split", ["bodies": ["base"], "plane": "yz", "face": "face:base/x"]) }
        #expect(two?.code == .invalidArguments)
        let none = await refusal { _ = try await run(t, "create_split", ["bodies": ["base"]]) }
        #expect(none?.code == .invalidArguments)
        let ghost = await refusal { _ = try await run(t, "create_split", ["bodies": ["ghost"], "plane": "xy"]) }
        #expect(ghost?.code == .featureNotFound)
    }

    @Test func aBodyCanBeSplitAtAHeightWithAPlane() async throws {
        let t = await open()
        try await box(t)
        _ = try await run(t, "create_plane", ["base": "xy", "offset": 5, "id": "cut_at"])
        _ = try await run(t, "create_split", ["bodies": ["base"], "plane": "plane:cut_at"])
        let bodies = try #require(t.model.result?.bodies)
        #expect(bodies.count == 2)
        let volumes = bodies.map(\.body.volume).sorted()
        #expect(abs(volumes[0] - 40 * 40 * 5) < 0.01 && abs(volumes[1] - 40 * 40 * 15) < 0.01, "\(volumes)")
    }

    @Test func laidOnTheFloorASideFaceBecomesTheBottom() async throws {
        let t = await open()
        try await box(t, id: "slab", 40, 20, 10)
        _ = try await run(t, "create_move", ["bodies": ["slab"], "ry": 90, "dz": 30])  // on its side and up in the air
        let body = try await t.service.getBody(documentID: t.id, bodyID: "slab")
        // The largest face is the one a print should lie on.
        let big = try #require(body.faces.filter { $0.shape == "plane" }.max { $0.area < $1.area }).id
        let r = try await run(t, "create_lay_on_floor", ["face": .string(big)])
        #expect(r.feature?.type == "LayOnFloor" || r.feature?.type == "Lay on Floor", "\(r.feature?.type ?? "nil")")
        let b = try #require(bounds(t, "slab"))
        #expect(abs(b.min.z) < 0.05, "the body sits on z = 0, not at \(b.min.z)")
        #expect(abs((b.max.z - b.min.z) - 10) < 0.1, "the 40 × 20 face is down, so it is 10 high: \(b)")
        let round = await refusal { _ = try await run(t, "create_lay_on_floor", ["face": "face:slab/nope"]) }
        #expect(round?.code == .featureNotFound)
    }

    // MARK: project

    @Test func textProjectedOntoACylinderIsRaisedOrCutIn() async throws {
        let t = await open()
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "can_sk"),
            EditSketchOperation(sketchID: "can_sk", add: [.circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: "30", radius: nil)]),
            try op("create_extrude", ["sketch_id": "can_sk", "profiles": "solid", "distance": 30, "id": "can"]),
            try op("create_plane", ["base": "xz", "offset": 40, "id": "wall"]),
            CreateSketchOperation(plane: "plane:wall", name: nil, id: "logo"),
            EditSketchOperation(sketchID: "logo", add: [.rectangle(id: "r", center: SketchPoint2(x: "0 mm", y: "15 mm"), corner: nil, width: "10", height: "6", cornerRadius: nil)]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Can", steps)
        let before = volume(t, "can")
        var r: ChangeResult?
        for flipped in [false, true] where r == nil {  // which way the plane looks decides which way is "onto the can"
            r = try? await run(t, "create_project", ["sketch_id": "logo", "profiles": "solid", "target": "can", "mode": "emboss", "height": 1.5, "flipped": .bool(flipped), "id": "badge"])
        }
        let made = try #require(r, "one of the two directions lands on the can")
        #expect(made.feature?.type == "Project")
        #expect(volume(t, "can") > before + 10, "\(volume(t, "can")) vs \(before)")
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: "badge", settings: ["height": 3], unlink: false)
        let bad = await refusal { _ = try await run(t, "create_project", ["sketch_id": "logo", "profiles": "solid", "target": "can", "mode": "carve"]) }
        #expect(bad?.code == .invalidArguments)
        let ghost = await refusal { _ = try await run(t, "create_project", ["sketch_id": "logo", "profiles": "solid", "target": "ghost"]) }
        #expect(ghost?.code == .featureNotFound)
    }

    // MARK: how a body looks

    @Test func aBodyCanBeNamedColouredAndHiddenAndItUndoesAsOneStep() async throws {
        let t = await open()
        try await box(t)
        let r = try await run(t, "set_body", ["body": "base", "name": "Base", "color": "#E8812A", "visible": false])
        #expect(t.model.document.bodyNames["base"] == "Base")
        #expect(t.model.document.bodyColors["base"]?.hex == "#E8812A")
        #expect(t.model.document.hidden.contains("base"))
        #expect(r.bodies.first?.name == "Base" && r.bodies.first?.visible == false, "\(r.bodies)")
        _ = try await run(t, "set_body", ["body": "base", "color": "default", "visible": true])
        #expect(t.model.document.bodyColors["base"] == nil && !t.model.document.hidden.contains("base"))
        t.undo.undo()
        #expect(t.model.document.hidden.contains("base"), "undo goes back one step")
        let nothing = await refusal { _ = try await run(t, "set_body", ["body": "base"]) }
        #expect(nothing?.code == .invalidArguments)
        let badColor = await refusal { _ = try await run(t, "set_body", ["body": "base", "color": "orange"]) }
        #expect(badColor?.code == .invalidValue)
        let ghost = await refusal { _ = try await run(t, "set_body", ["body": "ghost", "name": "x"]) }
        #expect(ghost?.code == .featureNotFound)
    }

    // MARK: reference picture

    private func writePNG(width: Int, height: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = dir.appendingPathComponent("photo.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url.path
    }

    @Test func aPictureIsPlacedAtAKnownWidthWithItsOwnProportions() async throws {
        let t = await open()
        let path = try writePNG(width: 200, height: 100)
        let r = try await run(t, "create_image", ["path": .string(path), "width": 80, "u": 10, "opacity": 0.3, "id": "photo"])
        #expect(r.message.contains("80 × 40 mm"), "\(r.message)")
        guard case .image(let image)? = t.model.document.features.first(where: { $0.id == "photo" })?.kind else { Issue.record("no image feature"); return }
        #expect(image.pixelWidth == 200 && image.pixelHeight == 100 && abs(image.opacity - 0.3) < 1e-9 && image.fileName == "photo.png")
        _ = try await t.service.modifyFeature(documentID: t.id, featureID: "photo", settings: ["width": 120], unlink: false)
        let relative = await refusal { _ = try await run(t, "create_image", ["path": "photo.png"]) }
        #expect(relative?.code == .invalidArguments)
        let missing = await refusal { _ = try await run(t, "create_image", ["path": "/nonexistent/photo.png"]) }
        #expect(missing?.code == .invalidArguments)
        let notPicture = FileManager.default.temporaryDirectory.appendingPathComponent("not-\(UUID().uuidString).png")
        try Data("hello".utf8).write(to: notPicture)
        let fake = await refusal { _ = try await run(t, "create_image", ["path": .string(notPicture.path)]) }
        #expect(fake?.code == .invalidArguments)
        let strange = await refusal { _ = try await run(t, "create_image", ["path": .string(path), "opacity": 3]) }
        #expect(strange?.code == .invalidValue)
    }
}

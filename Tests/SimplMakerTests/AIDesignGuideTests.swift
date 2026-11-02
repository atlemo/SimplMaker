// The design guide's recipes, run through the real tools: a recipe that does not build is worse than none.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIDesignGuideTests {
    private typealias Rig = (service: CADService, id: String, model: DocumentModel, rig: AIServiceTests.Rig)

    private func open() async -> Rig {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        model.undoManager = UndoManager()
        return (rig.service, id, model, rig)
    }

    private func step(_ tool: String, _ arguments: JSONValue) -> JSONValue { ["tool": .string(tool), "arguments": arguments] }

    private func params(_ pairs: [(String, JSONValue)]) -> [JSONValue] {
        pairs.map { step("set_parameter", ["name": .string($0.0), "value": $0.1]) }
    }

    private func batch(_ t: Rig, _ label: String, _ steps: [JSONValue]) async throws -> BatchResult {
        var operations: [any AIOperation] = []
        for s in steps { operations.append(try AIOperationParser.parse(tool: s["tool"]?.string ?? "", arguments: s["arguments"] ?? [:])) }
        return try await t.service.batch(documentID: t.id, expectedRevision: nil, label: label, operations)
    }

    private func volume(_ t: Rig, _ id: String) -> Double { t.model.result?.bodies.first { $0.id == id }?.body.volume ?? 0 }

    @Test func theSnapFitLidBoxBuildsInOneBatch() async throws {
        let t = await open()
        let r = try await batch(t, "Snap-fit box", AIRecipes.snapFitBoxPhaseOne)
        #expect(r.success)
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        #expect(r.bodies.map(\.id).sorted() == ["base", "lid"], "\(r.bodies.map(\.id))")
        let lid = try #require(r.bodies.first { $0.id == "lid" })
        #expect(abs(lid.boundsMax[2] - 30) < 0.05 && abs(lid.boundsMin[2] - 21) < 0.2, "\(lid.boundsMin) \(lid.boundsMax)")
        let base = try #require(r.bodies.first { $0.id == "base" })
        #expect(abs(base.boundsMax[2] - 27) < 0.05 && base.volume > 1000 && base.isValid && lid.isValid)
    }

    /// Edges of a body lying flat at height `z` (both ends there) that pass `outer` (a test on an end point's x and y).
    private func flatEdges(_ t: Rig, _ body: String, z: Double, outer: (Double, Double) -> Bool) async throws -> [String] {
        try await t.service.getBody(documentID: t.id, bodyID: body).edges.filter { e in
            guard let a = e.start, let b = e.end else { return false }
            return abs(a[2] - z) < 0.01 && abs(b[2] - z) < 0.01 && outer(a[0], a[1]) && outer(b[0], b[1])
        }.map(\.id)
    }

    @Test func theSnapFitChamfersFollowFromTheEdgesReadAfterPhaseOne() async throws {
        let t = await open()
        _ = try await batch(t, "Snap-fit box", AIRecipes.snapFitBoxPhaseOne)
        let before = (volume(t, "base"), volume(t, "lid"))
        // groove: the corners of its back wall, at the bottom (z 22) and the top (z 23.5) of the groove
        let grooveEdges = try await flatEdges(t, "base", z: 22) { abs($0) > 20.8 || abs($1) > 23.3 } + flatEdges(t, "base", z: 23.5) { abs($0) > 20.8 || abs($1) > 23.3 }
        // bead: the outer corners of its underside and top
        let beadEdges = try await flatEdges(t, "lid", z: 22) { abs($0) > 20.55 || abs($1) > 23.05 } + flatEdges(t, "lid", z: 23.5) { abs($0) > 20.55 || abs($1) > 23.05 }
        #expect(grooveEdges.count == 16 && beadEdges.count == 16, "two loops of eight: \(grooveEdges.count), \(beadEdges.count)")
        let r = try await batch(t, "Snap-fit chamfers", [
            step("create_chamfer", ["edges": .array(grooveEdges.map { .string($0) }), "size": 0.4, "id": "groove_chamfer"]),
            step("create_chamfer", ["edges": .array(beadEdges.map { .string($0) }), "size": 0.4, "id": "bead_chamfer"]),
        ])
        #expect(r.success && t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        #expect(volume(t, "base") > before.0, "a chamfer in the groove's concave corners fills them: the groove gets sloped sides")
        #expect(volume(t, "lid") < before.1, "a chamfer on the bead's convex corners takes material off")
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DUMP_DIR"] {
            for view in [SnapshotDirection.iso, .front] {
                let picture = try await t.service.viewportImage(documentID: t.id, direction: view, azimuth: nil, elevation: nil, width: 900, height: 700, axes: false)
                try? picture.image.png.write(to: URL(fileURLWithPath: dir + "/snapfit-\(view.rawValue).png"))
            }
        }
    }

    @Test func theRoundedOpenBoxBuilds() async throws {
        let t = await open()
        let r = try await batch(t, "Box", AIRecipes.roundedOpenBox)
        #expect(r.success && t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        let body = try #require(r.bodies.first)
        #expect(abs(body.boundsMax[0] - body.boundsMin[0] - 60) < 0.1 && abs(body.boundsMax[2] - 25) < 0.1 && body.isValid)
        // everything follows the parameters
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "width", "value": 80]))
        let wider = try #require(t.model.result?.bodies.first)
        let box = try wider.body.measure(.body).bounds
        #expect(t.model.result?.errors.isEmpty == true && abs(box.max.x - box.min.x - 80) < 0.1, "\(box)")
    }

    @Test func theNameTagBuildsWithItsTextOnTop() async throws {
        let t = await open()
        let r = try await batch(t, "Name tag", AIRecipes.nameTag)
        #expect(r.success && t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        let body = try #require(r.bodies.first { $0.id == "plate" })
        #expect(abs(body.boundsMax[2] - 4) < 0.05, "3 mm plate and 1 mm lettering: \(body.boundsMax)")
        #expect(body.volume > 60 * 25 * 3 * 0.7, "\(body.volume)")
    }

    @Test func theScrewPostCaseHasFourPostsWithPilotHolesAndALidThatLinesUp() async throws {
        let t = await open()
        let r = try await batch(t, "Screw case", AIRecipes.screwPostCase)
        #expect(r.success && t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        #expect(r.bodies.map(\.id).sorted() == ["case", "lid"], "\(r.bodies.map(\.id))")
        #expect(r.bodies.allSatisfy { $0.isValid })
        // four pilot holes (radius 1.3) and four post surfaces (radius 3.5) in the case, all in the one body
        let faces = try await t.service.getBody(documentID: t.id, bodyID: "case").faces.filter { $0.shape == "cylinder" }
        #expect(faces.filter { abs(($0.radius ?? 0) - 1.3) < 0.01 }.count == 4, "pilot holes: \(faces.compactMap(\.radius))")
        #expect(faces.filter { abs(($0.radius ?? 0) - 3.5) < 0.01 }.count == 4, "posts: \(faces.compactMap(\.radius))")
        // the lid: a rounded plate less four holes, sitting on the rim
        let lid = try #require(r.bodies.first { $0.id == "lid" })
        let plate = (60 * 40 - (4 - Double.pi) * 25) * 2.5
        #expect(abs(lid.volume - (plate - 4 * Double.pi * 1.7 * 1.7 * 2.5)) < 5, "\(lid.volume)")
        #expect(abs(lid.boundsMin[2] - 25) < 0.05 && abs(lid.boundsMax[2] - 27.5) < 0.05)
        // the holes line up: every lid hole's axis is a post's axis
        let lidHoles = try await t.service.getBody(documentID: t.id, bodyID: "lid").faces.filter { $0.shape == "cylinder" && abs(($0.radius ?? 0) - 1.7) < 0.01 }
        #expect(lidHoles.count == 4, "four clearance holes in the lid (the corners are cylinders too, of radius 5)")
        let pilot = faces.filter { abs(($0.radius ?? 0) - 1.3) < 0.01 }
        for hole in lidHoles {
            #expect(pilot.contains { abs($0.center[0] - hole.center[0]) < 0.01 && abs($0.center[1] - hole.center[1]) < 0.01 }, "\(hole.center)")
        }
        // follows the parameters: a wider case moves the posts and the lid's holes together
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "width", "value": 80]))
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        let wider = try await t.service.getBody(documentID: t.id, bodyID: "case").faces.filter { $0.shape == "cylinder" && abs(($0.radius ?? 0) - 1.3) < 0.01 }
        #expect(wider.allSatisfy { abs(abs($0.center[0]) - 35) < 0.01 }, "\(wider.map(\.center))")
    }

    @Test func thePrintInPlaceHingeMakesTwoBodiesThatDoNotTouch() async throws {
        let t = await open()
        let r = try await batch(t, "Hinge", AIRecipes.printInPlaceHinge)
        #expect(r.success && t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        #expect(r.bodies.map(\.id).sorted() == ["hinge_a", "hinge_b"], "\(r.bodies.map(\.id))")
        #expect(r.bodies.allSatisfy { $0.isValid })
        let a = try #require(r.bodies.first { $0.id == "hinge_a" }), b = try #require(r.bodies.first { $0.id == "hinge_b" })
        // the hinge is 3 knuckles and 2 gaps long, along Y; B (the middle knuckle) is the shorter
        #expect(abs((a.boundsMax[1] - a.boundsMin[1]) - 30.8) < 0.1 && abs((b.boundsMax[1] - b.boundsMin[1]) - 10) < 0.1, "\(a.boundsMin) \(a.boundsMax) | \(b.boundsMin) \(b.boundsMax)")
        // each leaf reaches to its own side
        #expect(a.boundsMin[0] < -19.9 && a.boundsMax[0] <= 4.05 && b.boundsMax[0] > 19.9 && b.boundsMin[0] >= -4.05, "\(a.boundsMin[0])…\(a.boundsMax[0]) | \(b.boundsMin[0])…\(b.boundsMax[0])")
        // free to turn: the closest the two bodies come is the clearance round the pin or the gap between knuckles, never zero
        let m = try await t.service.measure(documentID: t.id, a: "hinge_a", b: "hinge_b")
        #expect((m.distance ?? 0) > 0.35 && (m.distance ?? 0) < 0.45, "\(m.distance ?? -1)")
        // the clearance can be tuned afterwards
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "clr", "value": 0.3]))
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "set_parameter", arguments: ["name": "gap", "value": 0.3]))
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")
        let tuned = try await t.service.measure(documentID: t.id, a: "hinge_a", b: "hinge_b")
        #expect((tuned.distance ?? 0) > 0.25 && (tuned.distance ?? 0) < 0.35, "\(tuned.distance ?? -1)")
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DUMP_DIR"] {
            for view in [SnapshotDirection.iso, .front] {
                let picture = try await t.service.viewportImage(documentID: t.id, direction: view, azimuth: nil, elevation: nil, width: 900, height: 600, axes: false)
                try? picture.image.png.write(to: URL(fileURLWithPath: dir + "/hinge-\(view.rawValue).png"))
            }
        }
    }

    // MARK: the guide

    @Test func everyTopicIsServedAndTheListNamesThemAll() async throws {
        let t = await open()
        let list = try t.service.designGuide(topic: nil)
        let ids = list["topics"]?.array?.compactMap { $0["id"]?.string } ?? []
        #expect(ids == AIDesignGuide.topics.map(\.id) && ids.contains("workflow") && ids.contains("parameters") && ids.contains("snap_fit_lid"))
        for id in ids {
            let r = try t.service.designGuide(topic: id)
            let text = try #require(r["guide"]?.string)
            #expect(text.count > 300 && text.count < 14_000, "\(id): \(text.count) characters")
        }
        #expect(throws: AIError.self) { _ = try t.service.designGuide(topic: "nope") }
    }

    @Test func theRecipesInTheGuideAreTheOnesThatWereRun() async throws {
        let t = await open()
        let guide = try #require(try t.service.designGuide(topic: "snap_fit_lid")["guide"]?.string)
        #expect(guide.contains(AIRecipes.text(AIRecipes.snapFitBoxPhaseOne)), "the guide prints the exact steps the test builds")
        #expect(guide.contains("create_chamfer") && guide.contains("bead_z"))
        let box = try #require(try t.service.designGuide(topic: "rounded_box")["guide"]?.string)
        #expect(box.contains(AIRecipes.text(AIRecipes.roundedOpenBox)))
        let tag = try #require(try t.service.designGuide(topic: "name_tag")["guide"]?.string)
        #expect(tag.contains(AIRecipes.text(AIRecipes.nameTag)))
        let posts = try #require(try t.service.designGuide(topic: "screw_post_case")["guide"]?.string)
        #expect(posts.contains(AIRecipes.text(AIRecipes.screwPostCase)) && posts.contains("pilot_d"))
        let hinge = try #require(try t.service.designGuide(topic: "hinges_and_print_in_place")["guide"]?.string)
        #expect(hinge.contains(AIRecipes.text(AIRecipes.printInPlaceHinge)) && hinge.contains("clr"))
    }

    @Test func guideTopicsDoNotPromiseToolsThatDoNotExist() throws {
        let known = Set(AITools.make(service: AIServiceTests.Rig().service).map(\.name))
        let mentioned = AIDesignGuide.topics.flatMap { topic in
            topic.body.split(whereSeparator: { !($0.isLetter || $0 == "_") }).map(String.init).filter { $0.hasPrefix("create_") || $0.hasPrefix("get_") || $0.hasPrefix("check_") || $0.hasSuffix("_parameter") || $0.hasSuffix("_feature") }
        }
        let unknown = Set(mentioned).filter { !known.contains($0) && !["get_body", "get_viewport_image"].contains($0) }
        #expect(unknown.isEmpty, "\(unknown.sorted())")
    }

    // MARK: the checker

    private func codes(_ t: Rig, bed: [Double]? = nil) async throws -> [String] {
        try await t.service.checkDesign(documentID: t.id, bed: bed, minWall: nil).findings.map(\.code)
    }

    @Test func aWellMadeBoxWithParametersHasNothingToFix() async throws {
        let t = await open()
        _ = try await batch(t, "Box", AIRecipes.roundedOpenBox)
        let result = try await t.service.checkDesign(documentID: t.id, bed: nil, minWall: nil)
        let serious = result.findings.filter { $0.severity != "note" }
        #expect(serious.isEmpty, "\(serious)")
    }

    @Test func aThinWallIsFlaggedAndAThickOneIsNot() async throws {
        let thin = await open()
        _ = try await batch(thin, "Box", AIRecipes.roundedOpenBox.map { s in
            s["arguments"]?["name"]?.string == "wall" ? step("set_parameter", ["name": "wall", "value": 0.8]) : s })
        #expect(try await codes(thin).contains("THIN_WALL"))
        let ok = await open()
        _ = try await batch(ok, "Box", AIRecipes.roundedOpenBox)
        #expect(try await !codes(ok).contains("THIN_WALL"))
    }

    @Test func aPartTooBigForTheBedIsFlaggedAndOneThatNeedsTurningIsANote() async throws {
        let t = await open()
        _ = try await t.service.createBox(documentID: t.id, CADService.BoxRequest(width: "300", length: "50", height: "20", id: "long"))
        let found = try await t.service.checkDesign(documentID: t.id, bed: nil, minWall: nil).findings
        #expect(found.contains { $0.code == "TOO_BIG" && $0.severity == "warning" })
        let small = try await t.service.checkDesign(documentID: t.id, bed: [100, 100, 100], minWall: nil).findings
        #expect(small.contains { $0.code == "TOO_BIG" })
        let rotated = try await t.service.checkDesign(documentID: t.id, bed: [60, 60, 320], minWall: nil).findings
        #expect(rotated.contains { $0.code == "NEEDS_ROTATING" && $0.severity == "note" }, "\(rotated)")
    }

    @Test func aMushroomOverhangsAsModelledButNotUpsideDown() async throws {
        let t = await open()
        // a thin stem with a wide cap on top: the cap's underside faces down in the air
        _ = try await t.service.createBox(documentID: t.id, CADService.BoxRequest(width: "10", length: "10", height: "20", id: "stem"))
        _ = try await t.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "create_plane", arguments: ["offset": 20, "id": "p20"]))
        _ = try await t.service.createBox(documentID: t.id, CADService.BoxRequest(width: "50", length: "50", height: "5", plane: "plane:p20", id: "cap", operation: .join, target: "stem"))
        let found = try await t.service.checkDesign(documentID: t.id, bed: nil, minWall: nil).findings
        // as modelled the cap's underside hangs in the air; turned over it sits on the bed
        #expect(found.contains { ($0.code == "OVERHANG" || $0.code == "PRINT_ORIENTATION") && $0.message.contains("upside down") }, "\(found.map(\.message))")
    }

    @Test func theSnapFitBoxShowsItsClearanceAndTheLidPrintsUpsideDown() async throws {
        let t = await open()
        _ = try await batch(t, "Snap-fit box", AIRecipes.snapFitBoxPhaseOne)
        let found = try await t.service.checkDesign(documentID: t.id, bed: nil, minWall: nil).findings
        if ProcessInfo.processInfo.environment["DESIGN_DEBUG"] != nil { for f in found { FileHandle.standardError.write(Data("[\(f.severity)] \(f.code): \(f.message)\n".utf8)) } }
        let clearance = try #require(found.first { $0.code == "CLEARANCE" }, "\(found)")
        #expect(clearance.message.contains("0.2"), "\(clearance.message)")
        #expect(found.contains { ($0.code == "OVERHANG" || $0.code == "PRINT_ORIENTATION") && $0.message.contains("upside down") }, "the lid plate faces down as modelled: \(found.map(\.message))")
        #expect(!found.contains { $0.code == "THIN_WALL" }, "the 1.4 mm wall at the groove is thick enough: \(found.filter { $0.code == "THIN_WALL" }.map(\.message))")
        #expect(!found.contains { $0.severity == "error" })
    }

    @Test func aPartWithManyFixedSizesAndNoParametersIsToldSo() async throws {
        let t = await open()
        for n in 0..<3 { _ = try await t.service.createBox(documentID: t.id, CADService.BoxRequest(width: "10", length: "10", height: "10", u: "\(n * 20)", id: "b\(n)")) }
        #expect(try await codes(t).contains("NO_PARAMETERS"))
    }

    @Test func theToolsAnswerOverMCP() async throws {
        let t = await open()
        _ = try await batch(t, "Box", AIRecipes.roundedOpenBox)
        let server = AITools.makeServer(service: t.service, version: "test")
        func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
            let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]
            let data = try #require(await server.handle(Data(request.text().utf8)))
            return try #require(try JSONDecoder().decode(JSONValue.self, from: data)["result"])
        }
        let guide = try await call("get_design_guide", ["topic": "parameters"])
        #expect(guide["structuredContent"]?["guide"]?.string?.contains("set_parameter") == true && guide["isError"] == nil)
        let check = try await call("check_design", ["document_id": .string(t.id), "bed": [250, 250, 250]])
        #expect(check["structuredContent"]?["summary"]?.string != nil && check["isError"] == nil)
        let bad = try await call("check_design", ["document_id": .string(t.id), "bed": [1, 2]])
        #expect(bad["isError"] == true)
    }
}

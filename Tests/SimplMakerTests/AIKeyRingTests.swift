// The goal of the sketch tools, as an assistant would use them: "a key ring with the name Jane Doe on it, about 35 mm long and 3 mm
// thick", built through the JSON-RPC server in a single batch, then inspected and changed.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIKeyRingTests {
    /// A server over a part, called the way a client calls it.
    @MainActor private struct Rig {
        let rig = AIServiceTests.Rig()
        let id: String
        let model: DocumentModel
        let undo = UndoManager()
        let server: MCPServer

        init(_ doc: CADDocument = CADDocument()) async {
            let (id, model) = await rig.open(doc)
            self.id = id
            self.model = model
            model.undoManager = undo
            server = AITools.makeServer(service: rig.service, version: "test")
        }

        /// A tool call's result (isError and structuredContent included).
        func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
            let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]
            let data = try #require(await server.handle(Data(request.text().utf8)))
            let answer = try JSONDecoder().decode(JSONValue.self, from: data)
            return try #require(answer["result"], "\(answer.text())")
        }
    }

    private func keyRingBatch(_ documentID: String, name: String = "Jane Doe", length: JSONValue = 35, textHeight: JSONValue = 3.5) -> JSONValue {
        [
            "document_id": .string(documentID), "label": "Key ring",
            "operations": [
                ["tool": "create_sketch", "arguments": ["plane": "xy", "id": "outline", "name": "Outline"]],
                ["tool": "edit_sketch", "arguments": ["sketch_id": "outline", "add": [
                    ["type": "rectangle", "id": "plate", "width": length, "height": 15, "corner_radius": 7.5],
                    ["type": "circle", "id": "ring_hole", "center": [-12, 0], "diameter": 4],
                ]]],
                ["tool": "create_extrude", "arguments": ["sketch_id": "outline", "profiles": "solid", "distance": 3, "id": "keyring", "name": "Key ring"]],
                ["tool": "create_sketch", "arguments": ["plane": "face:keyring/keyring.end", "id": "lettering", "name": "Lettering"]],
                ["tool": "edit_sketch", "arguments": ["sketch_id": "lettering", "add": [
                    ["type": "text", "id": "name", "text": .string(name), "at": [4, 0], "height": textHeight, "anchor": "center"],
                ]]],
                ["tool": "create_extrude", "arguments": ["sketch_id": "lettering", "profiles": "solid", "distance": 1, "operation": "join",
                                                          "target": "keyring", "id": "letters", "name": "Letters"]],
            ],
        ]
    }

    @Test func aKeyRingWithANameIsBuiltInOneBatch() async throws {
        let t = await Rig()
        let r = try await t.call("batch", keyRingBatch(t.id))
        #expect(r["isError"] == nil, "\(r.text(pretty: true))")
        let content = try #require(r["structuredContent"])
        #expect(content["success"] == true && content["steps"]?.array?.count == 6)
        #expect(t.model.result?.errors.isEmpty == true, "\(t.model.result?.errors ?? [:])")

        // One body: the plate with the letters raised on it.
        let bodies = try #require(content["bodies"]?.array)
        #expect(bodies.count == 1 && bodies[0]["id"] == "keyring" && bodies[0]["is_valid"] == true)
        let min = try #require(bodies[0]["bounds_min"]?.array?.compactMap { $0.number }), max = try #require(bodies[0]["bounds_max"]?.array?.compactMap { $0.number })
        #expect(abs(min[0] + 17.5) < 1e-3 && abs(max[0] - 17.5) < 1e-3, "35 long: \(min[0]) … \(max[0])")
        #expect(abs(min[1] + 7.5) < 1e-3 && abs(max[1] - 7.5) < 1e-3, "15 wide: \(min[1]) … \(max[1])")
        #expect(abs(min[2]) < 1e-3 && abs(max[2] - 4) < 1e-3, "3 mm plate with letters 1 mm proud: \(min[2]) … \(max[2])")
        let plateOnly = (35.0 - 15) * 15 + Double.pi * 7.5 * 7.5 - Double.pi * 4
        let volume = try #require(bodies[0]["volume"]?.number)
        #expect(volume > plateOnly * 3 + 5, "the letters add material: \(volume) vs \(plateOnly * 3)")
        #expect(volume < plateOnly * 3 + 80, "but not a whole second plate: \(volume)")

        // The lettering fits on the plate, clear of the ring hole.
        let letters = try #require(t.model.result?.sketches["lettering"])
        let boxes = letters.regions.indices.map { CADService.bounds(ofRegion: $0, in: letters) }.filter { $0.count == 4 }
        let left = boxes.map { $0[0] }.min() ?? 0, right = boxes.map { $0[2] }.max() ?? 0
        #expect(left > -9.5 && right < 17.5, "between the hole and the end: \(left) … \(right)")

        // The undo history has one entry, with the name asked for.
        #expect(t.undo.undoActionName == "AI: Key ring")
        t.undo.undo()
        #expect(t.model.document.features.isEmpty, "the whole key ring is one Undo")
    }

    @Test func theLettersAreRaisedWithoutFillingTheirHoles() async throws {
        let t = await Rig()
        _ = try await t.call("batch", keyRingBatch(t.id, name: "Dao"))
        // 'D' and 'o' have holes. If their insides had been extruded too, the letters would be solid blobs: compare with the area of the profiles.
        let letters = try #require(t.model.result?.sketches["lettering"])
        let all = letters.regions.map(\.area).reduce(0, +)
        let body = try #require(t.model.result?.body("keyring"))
        let plate = ((35.0 - 15) * 15 + Double.pi * 7.5 * 7.5 - Double.pi * 4) * 3
        let raised = body.volume - plate
        #expect(raised > 0 && raised < all * 1.0 + 1, "the raised volume (\(raised)) is smaller than all regions' area × 1 mm (\(all)) because the holes stay empty")
        let info = try await t.rig.service.getFeature(documentID: t.id, featureID: "lettering")
        let enclosed = info.sketch?.profiles.filter { $0.insideProfile != nil } ?? []
        #expect(enclosed.count >= 2, "the insides of D and o are marked as lying inside another profile: \(enclosed.count)")
    }

    @Test func theKeyRingCanBeMadeLongerAndAThickerPlateAndRead() async throws {
        let t = await Rig()
        _ = try await t.call("batch", keyRingBatch(t.id))
        // "Make it 45 long."
        let longer = try await t.call("modify_feature", ["document_id": .string(t.id), "feature_id": "outline", "parameters": ["plate.width": 45]])
        #expect(longer["isError"] == nil, "\(longer.text(pretty: true))")
        let described = try await t.call("get_document", ["document_id": .string(t.id)])
        let ringBody = try #require(described["structuredContent"]?["bodies"]?.array?.first)
        let lo = try #require(ringBody["bounds_min"]?.array?.compactMap { $0.number }), hi = try #require(ringBody["bounds_max"]?.array?.compactMap { $0.number })
        #expect(abs((hi[0] - lo[0]) - 45) < 1e-3, "now 45 long: \(lo[0]) … \(hi[0])")
        // "And 4 mm thick."
        let thicker = try await t.call("modify_feature", ["document_id": .string(t.id), "feature_id": "keyring", "parameters": ["distance": 4]])
        #expect(thicker["isError"] == nil)
        let after4 = try await t.call("get_document", ["document_id": .string(t.id)])
        let top = try #require(after4["structuredContent"]?["bodies"]?.array?.first?["bounds_max"]?.array?.compactMap { $0.number })
        #expect(abs(top[2] - 5) < 1e-3, "a 4 mm plate with the 1 mm letters on its new top face: \(top[2])")
        // The assistant checks its work: a measurement of the plate's thickness, from the faces.
        let faces = try await t.call("get_body", ["document_id": .string(t.id), "body_id": "keyring"])
        let list = try #require(faces["structuredContent"]?["faces"]?.array)
        let bottom = try #require(list.first { $0["facing"] == "-z" })
        let bottomID = try #require(bottom["id"]?.string)
        let tops = list.filter { $0["facing"] == "+z" }
        #expect(!tops.isEmpty && tops.allSatisfy { ($0["area"]?.number ?? 0) > 0 })
        let largestTop = try #require(tops.max { ($0["area"]?.number ?? 0) < ($1["area"]?.number ?? 0) })
        let measured = try await t.call("measure", ["document_id": .string(t.id), "a": .string(bottomID), "b": largestTop["id"] ?? .null])
        #expect(measured["isError"] == nil, "\(measured.text(pretty: true))")
        let content = try #require(measured["structuredContent"])
        #expect(content["normals_angle_degrees"] == 180 || content["normals_angle_degrees"]?.number.map { abs($0 - 180) < 0.01 } == true, "opposite faces: \(content.text())")
        #expect(content["distance"]?.number.map { abs($0 - 4) < 1e-3 } == true, "the plate is 4 thick: \(content["distance"]?.text() ?? "")")
    }

    @Test func aNameThatDoesNotFitIsVisibleInTheBoundsSoItCanBeShrunk() async throws {
        let t = await Rig()
        let r = try await t.call("batch", keyRingBatch(t.id, name: "Bartholomew Montgomery", textHeight: 6))
        // It builds (a long name is not an error), but the profile bounds show it running off the plate.
        #expect(r["isError"] == nil)
        let sketch = try #require(r["structuredContent"]?["steps"]?.array?[4]["sketch"])
        let boxes = sketch["profiles"]?.array?.compactMap { $0["bounds"]?.array?.compactMap { $0.number } }.filter { $0.count == 4 } ?? []
        let right = boxes.map { $0[2] }.max() ?? 0, left = boxes.map { $0[0] }.min() ?? 0
        #expect(right > 17.5 || left < -17.5, "too wide for a 35 mm plate: \(left) … \(right)")
        // The fix: change the text's height, in one change.
        let fixed = try await t.call("modify_feature", ["document_id": .string(t.id), "feature_id": "lettering", "parameters": ["name.height": 1.5]])
        #expect(fixed["isError"] == nil, "\(fixed.text(pretty: true))")
        let after = try #require(fixed["structuredContent"]?["sketch"]?["profiles"]?.array?.compactMap { $0["bounds"]?.array?.compactMap { $0.number } }.filter { $0.count == 4 })
        #expect((after.map { $0[2] }.max() ?? 99) < 17.5 && (after.map { $0[0] }.min() ?? -99) > -17.5, "\(after)")
    }

    @Test func aMistakeInAStepRefusesTheWholeKeyRing() async throws {
        let t = await Rig()
        let batch = keyRingBatch(t.id)
        // The fifth step asks for a text without any words.
        let steps = try #require(batch["operations"]?.array)
        var broken = steps
        broken[4] = ["tool": "edit_sketch", "arguments": ["sketch_id": "lettering", "add": [["type": "text", "id": "name", "text": "  ", "at": [4, 0]]]]]
        var object = try #require(batch.object)
        object["operations"] = .array(broken)
        let r = try await t.call("batch", .object(object))
        #expect(r["isError"] == true)
        let error = try #require(r["structuredContent"]?["error"])
        #expect(error["code"] == "INVALID_ARGUMENTS" && error["message"]?.string?.hasPrefix("Step 5 of 6 (edit_sketch)") == true, "\(error.text())")
        #expect(error["reason"]?.string?.contains("None of the steps was applied") == true)
        #expect(t.model.document.features.isEmpty && !t.undo.canUndo, "the first four steps left no trace")
    }

    @Test func misspelledOrUnknownSettingsAreRefusedNotIgnored() async throws {
        let t = await Rig()
        let wrongKey = try await t.call("create_box", ["document_id": .string(t.id), "width": 1, "length": 1, "height": 1, "heigth": 5])
        #expect(wrongKey["isError"] == true && wrongKey["structuredContent"]?["error"]?["message"]?.string?.contains("heigth") == true)
        let shape = try await t.call("batch", ["document_id": .string(t.id), "operations": [
            ["tool": "create_sketch", "arguments": [:]],
            ["tool": "edit_sketch", "arguments": ["sketch_id": "x", "add": [["type": "circle", "diameter_mm": 5]]]],
        ]])
        #expect(shape["structuredContent"]?["error"]?["message"]?.string?.contains("diameter_mm") == true, "\(shape.text())")
        let notAShape = try await t.call("batch", ["document_id": .string(t.id), "operations": [["tool": "get_document", "arguments": [:]]]])
        #expect(notAShape["structuredContent"]?["error"]?["reason"]?.string?.contains("A batch can run") == true)
        let nested = try await t.call("batch", ["document_id": .string(t.id), "operations": [["tool": "create_sketch", "arguments": ["document_id": "doc_1"]]]])
        #expect(nested["structuredContent"]?["error"]?["message"]?.string?.contains("given once") == true)
        #expect(t.model.document.features.isEmpty)
    }

    @Test func bodiesFacesAndMeasurementsAreReadableAndRefuseGuesses() async throws {
        let t = await Rig()
        _ = try await t.call("create_box", ["document_id": .string(t.id), "width": 20, "length": 10, "height": 5, "id": "block"])
        let described = try await t.call("get_body", ["document_id": .string(t.id), "body_id": "block"])
        let content = try #require(described["structuredContent"])
        #expect(content["faces"]?.array?.count == 6 && content["edges"]?.array?.count == 12 && content["truncated"] == false)
        let faces = try #require(content["faces"]?.array)
        let top = try #require(faces.first { $0["facing"] == "+z" })
        #expect(top["shape"] == "plane" && top["area"]?.number.map { abs($0 - 200) < 1e-6 } == true)
        let edges = try #require(content["edges"]?.array)
        #expect(edges.allSatisfy { $0["shape"] == "line" && ($0["faces"]?.array?.count ?? 0) == 2 })
        let one = try await t.call("measure", ["document_id": .string(t.id), "a": "block"])
        #expect(one["structuredContent"]?["a"]?["volume"]?.number.map { abs($0 - 1000) < 1e-6 } == true)
        #expect(one["structuredContent"]?["a"]?["extent"] == [20, 10, 5])
        let angle = try await t.call("measure", ["document_id": .string(t.id), "a": top["id"] ?? .null,
                                                  "b": faces.first { $0["facing"] == "+x" }?["id"] ?? .null])
        #expect(angle["structuredContent"]?["angle_degrees"]?.number.map { abs($0 - 90) < 1e-6 } == true)
        for bad in ["nothing", "face:block/ghost", "edge:ghost/x", "cube:1/2"] {
            let r = try await t.call("measure", ["document_id": .string(t.id), "a": .string(bad)])
            #expect(r["isError"] == true, "\(bad)")
        }
        let missing = try await t.call("get_body", ["document_id": .string(t.id), "body_id": "nope"])
        #expect(missing["structuredContent"]?["error"]?["code"] == "FEATURE_NOT_FOUND" && missing["structuredContent"]?["error"]?["reason"]?.string?.contains("block") == true)
    }

    @Test func theNameCanBeChangedByRemakingTheLetters() async throws {
        let t = await Rig()
        _ = try await t.call("batch", keyRingBatch(t.id))
        // Changing only the words would leave the raised letters pointing at profiles that no longer exist: it is refused whole.
        let alone = try await t.call("modify_feature", ["document_id": .string(t.id), "feature_id": "lettering", "parameters": ["name.text": "John"]])
        #expect(alone["isError"] == true && alone["structuredContent"]?["error"]?["code"] == "REBUILD_FAILED", "\(alone.text())")
        #expect(t.model.document.features.count == 4, "and nothing was changed")
        // Remaking them in the same batch works.
        let before = t.model.document
        let r = try await t.call("batch", ["document_id": .string(t.id), "label": "Rename", "operations": [
            ["tool": "delete_feature", "arguments": ["feature_id": "letters"]],
            ["tool": "modify_feature", "arguments": ["feature_id": "lettering", "parameters": ["name.text": "John"]]],
            ["tool": "create_extrude", "arguments": ["sketch_id": "lettering", "profiles": "solid", "distance": 1, "operation": "join", "target": "keyring", "id": "letters", "name": "Letters"]],
        ]])
        #expect(r["isError"] == nil, "\(r.text(pretty: true))")
        let sketch = try await t.rig.service.getFeature(documentID: t.id, featureID: "lettering")
        #expect(sketch.sketch?.texts.map(\.text) == ["John"])
        let boxes = sketch.sketch?.profiles.map(\.bounds).filter { $0.count == 4 } ?? []
        let left = boxes.map { $0[0] }.min() ?? 0, right = boxes.map { $0[2] }.max() ?? 0
        #expect(abs((left + right) / 2 - 4) < 0.6, "still centred on x = 4: \(left) … \(right)")
        #expect(t.model.result?.errors.isEmpty == true && t.model.result?.bodies.count == 1)
        t.undo.undo()
        #expect(t.model.document == before || t.model.document.features.count == before.features.count, "one Undo for the whole rename")
    }
}

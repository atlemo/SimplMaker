// The picture an assistant can ask for: made offscreen with the app's renderer, from named directions, as an image in the tool result.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite(.serialized) @MainActor struct AIViewportImageTests {
    private func part() async throws -> (rig: AIServiceTests.Rig, id: String, model: DocumentModel) {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        _ = try await rig.service.createBox(documentID: id, CADService.BoxRequest(width: "60", length: "40", height: "20", id: "base"))
        let faces = try await rig.service.getBody(documentID: id, bodyID: "base").faces
        let top = try #require(faces.first { $0.facing == "+z" })
        _ = try await rig.service.change(documentID: id, expectedRevision: nil, try AIOperationParser.parse(tool: "create_fillet", arguments: ["faces": [.string(top.id)], "size": 3]))
        return (rig, id, model)
    }

    private func decode(_ png: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let rep = try #require(NSBitmapImageRep(data: png))
        let image = try #require(rep.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    /// The share of pixels that are not the background (the colour of the corner).
    private func share(_ p: (width: Int, height: Int, rgba: [UInt8])) -> Double {
        let bg = Array(p.rgba[0..<4])
        var different = 0
        for i in stride(from: 0, to: p.rgba.count, by: 4) where abs(Int(p.rgba[i]) - Int(bg[0])) + abs(Int(p.rgba[i + 1]) - Int(bg[1])) + abs(Int(p.rgba[i + 2]) - Int(bg[2])) > 24 { different += 1 }
        return Double(different) / Double(p.width * p.height)
    }

    private func dump(_ data: Data, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DUMP_DIR"] else { return }
        try? data.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
    }

    @Test func theIsoPictureShowsThePartAndNotJustTheBackground() async throws {
        let t = try await part()
        let r = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 1024, height: 768, axes: true)
        dump(r.image.png, "iso")
        #expect(r.image.width == 1024 && r.image.height == 768 && r.bodies == ["base"])
        let pixels = try decode(r.image.png)
        let covered = share(pixels)
        #expect(covered > 0.08 && covered < 0.9, "the part fills a good part of the picture: \(covered)")
    }

    @Test func differentDirectionsGiveDifferentPictures() async throws {
        let t = try await part()
        var shares: [String: Double] = [:]
        var images: [String: Data] = [:]
        for direction in [SnapshotDirection.top, .front, .right] {
            let r = try await t.rig.service.viewportImage(documentID: t.id, direction: direction, azimuth: nil, elevation: nil, width: 640, height: 480, axes: false)
            dump(r.image.png, direction.rawValue)
            images[direction.rawValue] = r.image.png
            shares[direction.rawValue] = share(try decode(r.image.png))
        }
        #expect(Set(images.values).count == 3)
        #expect(shares.values.allSatisfy { $0 > 0.05 }, "\(shares)")
    }

    @Test func aPictureLeavesThePartAndTheUsersViewAlone() async throws {
        let t = try await part()
        let revision = t.model.documentRevision
        let undoCount = t.model.document.features.count
        _ = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: 30, elevation: 20, width: 512, height: 384, axes: true)
        #expect(t.model.documentRevision == revision && t.model.document.features.count == undoCount)
    }

    // MARK: options

    /// A hollow box with a lid-sized plate beside it, and a sketch used by an extrude (so it is hidden).
    private func assembly() async throws -> (rig: AIServiceTests.Rig, id: String, model: DocumentModel) {
        let rig = AIServiceTests.Rig()
        let (id, model) = await rig.open(CADDocument())
        let steps: [any AIOperation] = [
            try AIOperationParser.parse(tool: "create_box", arguments: ["width": 40, "length": 40, "height": 30, "id": "tub"]),
            try AIOperationParser.parse(tool: "create_box", arguments: ["width": 20, "length": 20, "height": 4, "u": 60, "id": "plate"]),
            CreateSketchOperation(plane: "xy", name: nil, id: "ring_sk"),
            EditSketchOperation(sketchID: "ring_sk", add: [.circle(id: "c", center: SketchPoint2(x: "-60 mm", y: "0 mm"), diameter: "20", radius: nil)]),
        ]
        _ = try await rig.service.batch(documentID: id, expectedRevision: nil, label: "Assembly", steps)
        let top = try #require(try await rig.service.getBody(documentID: id, bodyID: "tub").faces.first { $0.facing == "+z" })
        _ = try await rig.service.change(documentID: id, expectedRevision: nil, try AIOperationParser.parse(tool: "create_shell", arguments: ["body": "tub", "open_faces": [.string(top.id)], "thickness": 2]))
        return (rig, id, model)
    }

    @Test func onlyShowsTheBodiesNamedAndHiddenOnesToo() async throws {
        let t = try await assembly()
        let both = try await t.rig.service.viewportImage(documentID: t.id, direction: .top, azimuth: nil, elevation: nil, width: 640, height: 480, axes: false)
        let one = try await t.rig.service.viewportImage(documentID: t.id, direction: .top, azimuth: nil, elevation: nil, width: 640, height: 480, axes: false,
                                                        options: SnapshotOptions(only: ["plate"]))
        dump(one.image.png, "only-plate")
        #expect(both.bodies == ["tub", "plate"] && one.bodies == ["plate"])
        #expect(both.image.png != one.image.png)
        // A hidden body can be looked at on its own.
        _ = try await t.rig.service.change(documentID: t.id, expectedRevision: nil, try AIOperationParser.parse(tool: "set_body", arguments: ["body": "tub", "visible": false]))
        let hidden = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 640, height: 480, axes: false,
                                                           options: SnapshotOptions(only: ["tub"]))
        let hiddenShare = share(try decode(hidden.image.png))
        #expect(hidden.bodies == ["tub"] && hiddenShare > 0.05)
        let ghost = await refusalOf { _ = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 640, height: 480,
                                                                              axes: true, options: SnapshotOptions(only: ["ghost"])) }
        #expect(ghost?.code == .featureNotFound)
    }

    @Test func aSectionOpensTheBoxAndSaysWhereItCut() async throws {
        let t = try await assembly()
        let whole = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 800, height: 600, axes: false,
                                                          options: SnapshotOptions(only: ["tub"]))
        let cut = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 800, height: 600, axes: false,
                                                        options: SnapshotOptions(only: ["tub"], section: SnapshotSection(axis: 1, offset: 0, cutPositive: nil)))
        dump(whole.image.png, "section-before")
        dump(cut.image.png, "section-iso")
        let note = try #require(cut.image.section)
        #expect(note.contains("y = 0") && note.contains("cut away"), "\(note)")
        #expect(whole.image.section == nil && cut.image.png != whole.image.png)
        // The renderer is left as it was: a picture afterwards is not cut.
        let after = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 800, height: 600, axes: false,
                                                          options: SnapshotOptions(only: ["tub"]))
        #expect(after.image.png == whole.image.png)
        // From the front, cutting away the near half (negative y) shows the inside; from the top, cutting z shows the floor of the hollow.
        let front = try await t.rig.service.viewportImage(documentID: t.id, direction: .front, azimuth: nil, elevation: nil, width: 800, height: 600, axes: false,
                                                          options: SnapshotOptions(only: ["tub"], section: SnapshotSection(axis: 1, offset: nil, cutPositive: nil)))
        dump(front.image.png, "section-front")
        #expect(front.image.section?.contains("lower y side is cut away") == true, "\(front.image.section ?? "nil")")
        let wrongSide = try await t.rig.service.viewportImage(documentID: t.id, direction: .front, azimuth: nil, elevation: nil, width: 800, height: 600, axes: false,
                                                              options: SnapshotOptions(only: ["tub"], section: SnapshotSection(axis: 1, offset: nil, cutPositive: true)))
        dump(wrongSide.image.png, "section-front-far-half-cut")
        #expect(wrongSide.image.png != front.image.png)
    }

    @Test func aSketchCanBeDrawnEvenWhenItIsHidden() async throws {
        let t = try await assembly()
        let plain = try await t.rig.service.viewportImage(documentID: t.id, direction: .top, azimuth: nil, elevation: nil, width: 640, height: 480, axes: false)
        let withSketch = try await t.rig.service.viewportImage(documentID: t.id, direction: .top, azimuth: nil, elevation: nil, width: 640, height: 480, axes: false,
                                                               options: SnapshotOptions(sketches: ["ring_sk"]))
        dump(withSketch.image.png, "with-sketch")
        #expect(withSketch.sketches == ["ring_sk"] && withSketch.image.png != plain.image.png)
        let ghost = await refusalOf { _ = try await t.rig.service.viewportImage(documentID: t.id, direction: .top, azimuth: nil, elevation: nil, width: 640, height: 480,
                                                                              axes: true, options: SnapshotOptions(sketches: ["nope"])) }
        #expect(ghost?.code == .featureNotFound)
    }

    private func refusalOf(_ body: () async throws -> Void) async -> AIError? {
        do { try await body() } catch { return error as? AIError }
        return nil
    }

    @Test func nothingToShowAndBadSizesAreRefused() async throws {
        let rig = AIServiceTests.Rig()
        let (id, _) = await rig.open(CADDocument())
        do { _ = try await rig.service.viewportImage(documentID: id, direction: .iso, azimuth: nil, elevation: nil, width: 1024, height: 768, axes: true); Issue.record("no bodies") } catch {
            #expect((error as? AIError)?.code == .invalidArguments)
        }
        let t = try await part()
        do { _ = try await t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 10, height: 10, axes: true); Issue.record("size") } catch {
            #expect((error as? AIError)?.code == .invalidArguments)
        }
        let unlicensed = AIServiceTests.Rig(licensed: false)
        let (uid, _) = await unlicensed.open(CADDocument())
        do { _ = try await unlicensed.service.viewportImage(documentID: uid, direction: .iso, azimuth: nil, elevation: nil, width: 1024, height: 768, axes: true); Issue.record("licence") } catch {
            #expect((error as? AIError) == AIError.licenseRequired || (error as? AIError)?.code == AIError.licenseRequired.code)
        }
    }

    @Test func theToolAnswersWithAnImageBlockAndTheFacts() async throws {
        let t = try await part()
        let server = AITools.makeServer(service: t.rig.service, version: "test")
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": "get_viewport_image", "arguments": ["document_id": .string(t.id), "view": "front", "width": 512, "height": 384]]]
        let data = try #require(await server.handle(Data(request.text().utf8)))
        let answer = try JSONDecoder().decode(JSONValue.self, from: data)
        let result = try #require(answer["result"])
        let blocks = try #require(result["content"]?.array)
        let image = try #require(blocks.first { $0["type"]?.string == "image" })
        #expect(image["mimeType"]?.string == "image/png")
        let encoded = try #require(image["data"]?.string)
        let png = try #require(Data(base64Encoded: encoded))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let facts = try #require(result["structuredContent"])
        #expect(facts["view"]?.string == "front" && facts["orientation"]?.string?.contains("+X to the right") == true)
        #expect(facts["_images"] == nil, "the picture is in the content, not repeated as text")
        #expect(result["isError"] == nil)
    }

    @Test func twoPicturesAskedForAtOnceBothShowThePart() async throws {
        let t = try await part()
        async let a = t.rig.service.viewportImage(documentID: t.id, direction: .iso, azimuth: nil, elevation: nil, width: 512, height: 384, axes: true)
        async let b = t.rig.service.viewportImage(documentID: t.id, direction: .top, azimuth: nil, elevation: nil, width: 512, height: 384, axes: true)
        let (first, second) = try await (a, b)
        let shares = [share(try decode(first.image.png)), share(try decode(second.image.png))]
        #expect(shares.allSatisfy { $0 > 0.08 }, "one does not wipe the other's scene: \(shares)")
    }
}

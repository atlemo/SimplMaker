// slice_body (a body cut by a plane, outline and sizes back) and create_twist_sweep, through the AI interface.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
import simd
@testable import SimplMaker

@Suite @MainActor struct AISliceTests {
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

    /// A 10 × 2 bar drawn on the yz plane, in a sketch of its own, ready to sweep along X.
    private func bar(_ t: Rig, id: String = "bar") async throws {
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "yz", name: nil, id: "\(id)_sk"),
            EditSketchOperation(sketchID: "\(id)_sk", add: [.rectangle(id: "r", center: SketchPoint2(x: "0 mm", y: "0 mm"), corner: nil,
                                                                       width: "10", height: "2", cornerRadius: nil)]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Bar", steps)
    }

    // MARK: BodySlicer

    @Test func aBoxCutAcrossIsItsRectangle() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 40, "length": 30, "height": 20, "id": "b"])
        let r = try await t.service.sliceBody(documentID: t.id, bodyID: "b", axis: "z", offsets: [10], tolerance: 0.02, includePoints: true)
        let s = try #require(r.sections.first)
        #expect(r.plane == "xy" && s.loops.count == 1)
        let loop = try #require(s.loops.first)
        #expect(loop.closed && !loop.hole && loop.points?.count == 4, "four corners, no extra points: \(String(describing: loop.points))")
        #expect(abs((s.area ?? 0) - 1200) < 0.5)
        #expect(abs((s.length ?? 0) - 40) < 0.01 && abs((s.width ?? 0) - 30) < 0.01)
        #expect(abs(r.bodyRange[1] - r.bodyRange[0] - 20) < 0.05, "z runs 20 mm: \(r.bodyRange)")
    }

    @Test func slicingManyStationsGivesOneSectionEachAndMissesAreEmpty() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 40, "length": 30, "height": 20, "id": "b"])
        let r = try await t.service.sliceBody(documentID: t.id, bodyID: "b", axis: "x", offsets: [-10, 0, 10, 500], tolerance: 0.02, includePoints: false)
        #expect(r.sections.count == 4 && r.plane == "yz")
        #expect(r.sections[0].loops.count == 1 && r.sections[0].loops[0].points == nil, "the sizes only, when points are not wanted")
        #expect(abs((r.sections[1].area ?? 0) - 600) < 0.5, "30 × 20 across the length")
        #expect(r.sections[3].loops.isEmpty && r.sections[3].area == nil, "a plane that misses the body gives an empty section")
    }

    @Test func aHoleShowsAsAClockwiseLoopInsideTheOutline() async throws {
        let t = await open()
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "sk"),
            EditSketchOperation(sketchID: "sk", add: [.rectangle(id: "r", center: SketchPoint2(x: "0 mm", y: "0 mm"), corner: nil, width: "40", height: "40", cornerRadius: nil),
                                                      .circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: "10", radius: nil)]),
            try op("create_extrude", ["sketch_id": "sk", "profiles": "solid", "distance": 5, "id": "plate"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Plate", steps)
        let r = try await t.service.sliceBody(documentID: t.id, bodyID: "plate", axis: "z", offsets: [2.5], tolerance: 0.01, includePoints: true)
        let s = try #require(r.sections.first)
        #expect(s.loops.count == 2)
        #expect(s.loops[0].hole == false && s.loops[1].hole == true, "the biggest loop is the outline, the other a hole")
        #expect(abs((s.area ?? 0) - (1600 - Double.pi * 25)) < 0.5, "the hole is taken off the area: \(String(describing: s.area))")
    }

    @Test func aTolerancePrunesTheCornersOfARoundOutline() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 20, "length": 20, "height": 10, "id": "b"])
        let steps: [any AIOperation] = [
            CreateSketchOperation(plane: "xy", name: nil, id: "sk"),
            EditSketchOperation(sketchID: "sk", add: [.circle(id: "c", center: SketchPoint2(x: "0 mm", y: "0 mm"), diameter: "30", radius: nil)]),
            try op("create_extrude", ["sketch_id": "sk", "profiles": "solid", "distance": 8, "id": "drum"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Drum", steps)
        let rough = try await t.service.sliceBody(documentID: t.id, bodyID: "drum", axis: "z", offsets: [4], tolerance: 0.5, includePoints: true)
        let fine = try await t.service.sliceBody(documentID: t.id, bodyID: "drum", axis: "z", offsets: [4], tolerance: 0, includePoints: true)
        let roughCount = try #require(rough.sections[0].loops.first?.points?.count), fineCount = try #require(fine.sections[0].loops.first?.points?.count)
        #expect(roughCount >= 8 && roughCount < fineCount, "\(roughCount) corners against \(fineCount)")
        #expect(abs((rough.sections[0].area ?? 0) - Double.pi * 225) < Double.pi * 225 * 0.03, "still the same circle, give or take")
        #expect(abs((fine.sections[0].area ?? 0) - Double.pi * 225) < Double.pi * 225 * 0.002)
    }

    @Test func badArgumentsSaySoAndAnUnknownBodyIsNotFound() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 10, "length": 10, "height": 10, "id": "b"])
        let axis = await refusal { _ = try await t.service.sliceBody(documentID: t.id, bodyID: "b", axis: "w", offsets: [1], tolerance: 0.02, includePoints: true) }
        #expect(axis?.code == .invalidArguments)
        let none = await refusal { _ = try await t.service.sliceBody(documentID: t.id, bodyID: "b", axis: "z", offsets: [], tolerance: 0.02, includePoints: true) }
        #expect(none?.code == .invalidArguments)
        let tolerance = await refusal { _ = try await t.service.sliceBody(documentID: t.id, bodyID: "b", axis: "z", offsets: [1], tolerance: -1, includePoints: true) }
        #expect(tolerance?.code == .invalidArguments)
        let ghost = await refusal { _ = try await t.service.sliceBody(documentID: t.id, bodyID: "ghost", axis: "z", offsets: [1], tolerance: 0.02, includePoints: true) }
        #expect(ghost?.code == .featureNotFound)
    }

    // MARK: twist sweep, read back with slice_body

    @Test func aTwistedBarReadsBackItsTiltAtEveryStation() async throws {
        let t = await open()
        try await bar(t)
        let made = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 40, "end_angle": 60, "id": "twisted"])
        #expect(made.feature?.type == "Twist Sweep", "\(made)")
        // The sketch is on yz, so the bar runs along X; at a fraction t of the way it has turned t × 60°. Slices across X give the
        // 10 × 2 section turned in the yz plane; its long direction is that angle.
        let r = try await t.service.sliceBody(documentID: t.id, bodyID: "twisted", axis: "x", offsets: [5, 20, 35], tolerance: 0.02, includePoints: false)
        let tilts = r.sections.map { $0.majorAxisDegrees ?? .nan }
        #expect(abs(tilts[0] - 7.5) < 0.5 && abs(tilts[1] - 30) < 0.5 && abs(tilts[2] - 52.5) < 0.5, "\(tilts)")
        for s in r.sections {
            #expect(abs((s.length ?? 0) - 10) < 0.15 && abs((s.width ?? 0) - 2) < 0.1, "the section keeps its size: \(s)")
        }
    }

    @Test func theCurveHoldsTheTurnBackUntilTheEnd() async throws {
        let t = await open()
        try await bar(t)
        _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 40, "end_angle": 80, "curve": 2, "id": "late"])
        let r = try await t.service.sliceBody(documentID: t.id, bodyID: "late", axis: "x", offsets: [10, 20, 40 - 0.01], tolerance: 0.02, includePoints: false)
        let tilts = r.sections.map { $0.majorAxisDegrees ?? .nan }
        // t^2 × 80°: a quarter of the way 5°, half way 20°, all the way 80° (read at -90...90, so it stays 80).
        #expect(abs(tilts[0] - 5) < 0.6 && abs(tilts[1] - 20) < 0.6 && abs(tilts[2] - 80) < 1.0, "\(tilts)")
    }

    @Test func aSlideShowsUpAsTheCentroidMoving() async throws {
        let t = await open()
        try await bar(t)
        _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 40, "end_angle": 0, "shift": [0, 12], "id": "rise"])
        let r = try await t.service.sliceBody(documentID: t.id, bodyID: "rise", axis: "x", offsets: [0.01, 20, 39.99], tolerance: 0.02, includePoints: false)
        let rises = r.sections.map { $0.centroid?[1] ?? .nan }
        #expect(abs(rises[0]) < 0.1 && abs(rises[1] - 6) < 0.1 && abs(rises[2] - 12) < 0.1, "\(rises)")
    }

    @Test func theBladeRecipeBuildsAndModifyFeatureRetwistsIt() async throws {
        let t = await open()
        try await bar(t)
        let steps: [any AIOperation] = [
            try op("create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 60, "end_angle": -30, "curve": 2, "shift": [0, 8], "id": "plate"]),
            CreateSketchOperation(plane: "xy", name: nil, id: "plan"),
            EditSketchOperation(sketchID: "plan", add: [.rectangle(id: "r", center: nil, corner: SketchPoint2(x: "0 mm", y: "-3 mm"), width: "60", height: "6", cornerRadius: nil)]),
            try op("create_extrude", ["sketch_id": "plan", "profiles": "solid", "distance": 100, "direction": "symmetric", "operation": "intersect", "target": "plate", "id": "outline"]),
        ]
        _ = try await t.service.batch(documentID: t.id, expectedRevision: nil, label: "Blade", steps)
        let body = try #require(t.model.result?.bodies.first { $0.id == "plate" }?.body)
        #expect(body.isValid && t.model.result?.errors.isEmpty == true)
        let before = body.volume
        let moved = try await t.service.modifyFeature(documentID: t.id, featureID: "plate", settings: ["end_angle": -50, "distance": 55], unlink: false)
        #expect(moved.changes.map(\.field).sorted() == ["distance", "end_angle"], "\(moved.changes)")
        let after = try #require(t.model.result?.bodies.first { $0.id == "plate" }?.body)
        #expect(after.isValid && abs(after.volume - before) / before < 0.25)
        t.undo.undo()
        await t.model.rebuilt()
        let back = try #require(t.model.result?.bodies.first { $0.id == "plate" }?.body)
        #expect(abs(back.volume - before) < 0.01, "one undo step per change")
    }

    @Test func aTwistSweepRefusesWhatCannotWork() async throws {
        let t = await open()
        try await bar(t)
        let noSketch = await refusal { _ = try await run(t, "create_twist_sweep", ["sketch_id": "ghost", "profiles": "solid", "distance": 10, "end_angle": 30]) }
        #expect(noSketch?.code == .featureNotFound)
        let zero = await refusal { _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 0, "end_angle": 30]) }
        #expect(zero?.code == .invalidValue)
        let curve = await refusal { _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 10, "end_angle": 30, "curve": 0]) }
        #expect(curve?.code == .invalidValue)
        let turns = await refusal { _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 10, "end_angle": 3000]) }
        #expect(turns?.code == .invalidValue)
        let misspelled = await refusal { _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 10, "end_angle": 30, "angle": 5]) }
        #expect(misspelled?.code == .invalidArguments)
        let missing = await refusal { _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 10]) }
        #expect(missing?.code == .invalidArguments, "end_angle is required")
        #expect(t.model.document.features.count == 1, "nothing was added by the refusals: only the sketch is there")
    }

    // MARK: create_sections and loft stations

    /// The corners of a square of side `s` about the origin, as the JSON an AI would send.
    private static func squarePoints(_ s: Double) -> JSONValue {
        let h = s / 2
        let corners: [[Double]] = [[-h, -h], [h, -h], [h, h], [-h, h]]
        return .array(corners.map { .array($0.map { .double($0) }) })
    }

    @Test func sectionsOfATwistedBarAreSketchesThatLoftBackToTheSameBar() async throws {
        let t = await open()
        try await bar(t)
        _ = try await run(t, "create_twist_sweep", ["sketch_id": "bar_sk", "profiles": "solid", "distance": 40, "end_angle": 60, "id": "twisted"])
        let original = try #require(t.model.result?.bodies.first { $0.id == "twisted" }?.body).volume
        let r = try await run(t, "create_sections", ["body": "twisted", "axis": "x", "from": 0.5, "to": 39.5, "count": 14, "tolerance": 0.02, "id": "sec"])
        let made = try #require(r.created?["sections"]?.array)
        #expect(made.count == 14 && made[0]["sketch_id"]?.string == "sec_s1" && made[0]["plane_id"]?.string == "sec_p1", "\(r.message)")
        #expect(made.allSatisfy { ($0["outlines"]?.number ?? 0) == 1 && ($0["corners"]?.number ?? 0) >= 4 && ($0["corners"]?.number ?? 0) <= 8 })
        // Each sketch is a drawing of the cut on a plane at its station: the 10 × 2 section, turned.
        let first = try #require(t.model.result?.sketches["sec_s1"])
        #expect(first.regions.count == 1 && abs(first.regions[0].area - 20) < 0.5, "\(first.regions.map(\.area))")
        let plane = try #require(t.model.result?.planes["sec_p1"])
        #expect(abs(plane.origin.x - 0.5) < 1e-6, "on the plane at x = 0.5: \(plane.origin)")
        // Lofted back through, the sections give the bar again, within what 14 stations can tell.
        let sections: [JSONValue] = (1...14).map { ["sketch_id": .string("sec_s\($0)"), "profile": "solid"] }
        _ = try await run(t, "create_loft", ["sections": .array(sections), "id": "again"])
        let again = try #require(t.model.result?.bodies.first { $0.id == "again" }?.body)
        #expect(again.isValid && abs(again.volume - original * 38.99 / 40) / original < 0.05, "\(again.volume) against \(original)")
    }

    @Test func sectionsAcrossYSitOnTheirPlanesDespiteTheXzPlanesFlippedNormal() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 10, "length": 30, "height": 4, "id": "slab"])
        let r = try await run(t, "create_sections", ["body": "slab", "axis": "y", "offsets": [-10, 5], "id": "cut"])
        #expect(r.created?["sections"]?.array?.count == 2, "\(r.message)")
        for (id, y) in [("cut_p1", -10.0), ("cut_p2", 5.0)] {
            let plane = try #require(t.model.result?.planes[id])
            #expect(abs(plane.origin.y - y) < 1e-6, "\(id) should be at y = \(y): \(plane.origin)")
        }
        let s = try #require(t.model.result?.sketches["cut_s2"])
        #expect(abs((s.regions.first?.area ?? 0) - 40) < 0.1, "10 wide, 4 high: \(s.regions.map(\.area))")
    }

    @Test func stationsGivenInlineMakeThePlanesSketchesAndTheLoft() async throws {
        let t = await open()
        func square(_ s: Double) -> JSONValue { Self.squarePoints(s) }
        let r = try await run(t, "create_loft", ["axis": "z", "ruled": true, "id": "frustum",
                                                  "stations": [["offset": 0, "points": square(10)], ["offset": 10, "points": square(4)]]])
        #expect(r.feature?.type == "Loft" && r.message.contains("frustum_s1"), "\(r.message)")
        let body = try #require(t.model.result?.bodies.first { $0.id == "frustum" }?.body)
        // a frustum of 10 × 10 to 4 × 4 over 10 mm: h / 3 × (A1 + A2 + √(A1 A2))
        #expect(abs(body.volume - 10.0 / 3 * (100 + 16 + 40)) < 0.5, "\(body.volume)")
        #expect(t.model.document.features.map(\.id).contains("frustum_p2") && t.model.document.features.map(\.id).contains("frustum_s2"))
    }

    @Test func aRingStationLoftsHollowAndAStationAlongYIsInThePlaneItSays() async throws {
        let t = await open()
        func ring(_ outer: Double, _ inner: Double) -> JSONValue {
            return [Self.squarePoints(outer), Self.squarePoints(inner)]
        }
        _ = try await run(t, "create_loft", ["axis": "y", "ruled": true, "id": "tube",
                                              "stations": [["offset": 0, "loops": ring(10, 6)], ["offset": 20, "loops": ring(10, 6)]]])
        let body = try #require(t.model.result?.bodies.first { $0.id == "tube" }?.body)
        #expect(body.isValid && abs(body.volume - (100 - 36) * 20) < 1, "a square tube 20 long: \(body.volume)")
        let b = try body.measure(.body).bounds
        #expect(abs(b.min.y) < 0.05 && abs(b.max.y - 20) < 0.05, "from y = 0 to 20: \(b)")
    }

    @Test func sectionsAndStationsRefuseWhatCannotWork() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 10, "length": 10, "height": 10, "id": "b"])
        let ghost = await refusal { _ = try await run(t, "create_sections", ["body": "ghost", "axis": "x", "offsets": [1]]) }
        #expect(ghost?.code == .featureNotFound)
        let miss = await refusal { _ = try await run(t, "create_sections", ["body": "b", "axis": "x", "offsets": [500]]) }
        #expect(miss?.code == .invalidValue)
        let axis = await refusal { _ = try await run(t, "create_sections", ["body": "b", "axis": "q", "offsets": [1]]) }
        #expect(axis?.code == .invalidArguments)
        let few = await refusal { _ = try await run(t, "create_loft", ["axis": "z", "stations": [["offset": 0, "points": [[0, 0], [1, 0]]], ["offset": 5, "points": [[0, 0], [1, 0], [1, 1]]]]]) }
        #expect(few?.code == .invalidArguments, "a station needs three points at least")
        let both = await refusal { _ = try await run(t, "create_loft", ["axis": "z", "sections": [["sketch_id": "a", "profile": "solid"]], "stations": []]) }
        #expect(both?.code == .invalidArguments)
        let noAxis = await refusal { _ = try await run(t, "create_loft", ["stations": [["offset": 0, "points": [[0, 0], [1, 0], [1, 1]]], ["offset": 5, "points": [[0, 0], [1, 0], [1, 1]]]]]) }
        #expect(noAxis?.code == .invalidArguments)
        #expect(t.model.document.features.count == 1, "nothing was left behind by the refusals")
    }

    // MARK: through the tool handlers, as a client calls them

    @Test func theToolsAnswerWhenCalledTheWayAClientCallsThem() async throws {
        let t = await open()
        _ = try await run(t, "create_box", ["width": 40, "length": 30, "height": 20, "id": "b"])
        let tools = AITools.make(service: t.service)
        func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
            try await #require(tools.first { $0.name == name }).handler(arguments)
        }
        // offsets, and from/to/count: both ways of naming the stations
        let listed = try await call("slice_body", ["document_id": .string(t.id), "body_id": "b", "axis": "z", "offsets": [5, 15], "points": false])
        #expect(listed["sections"]?.array?.count == 2 && listed["plane"]?.string == "xy", "\(listed)")
        let ranged = try await call("slice_body", ["document_id": .string(t.id), "body_id": "b", "axis": "x", "from": -15, "to": 15, "count": 4])
        #expect(ranged["sections"]?.array?.count == 4 && ranged["sections"]?.array?[0]["loops"]?.array?.first?["points"]?.array?.count == 4, "\(ranged)")
        let both = await refusal { _ = try await call("slice_body", ["body_id": "b", "axis": "z", "offsets": [1], "from": 0, "to": 5, "count": 3]) }
        #expect(both?.code == .invalidArguments)
        let neither = await refusal { _ = try await call("slice_body", ["body_id": "b", "axis": "z"]) }
        #expect(neither?.code == .invalidArguments)
        let stray = await refusal { _ = try await call("slice_body", ["body_id": "b", "axis": "z", "offsets": [1], "offset": 3]) }
        #expect(stray?.code == .invalidArguments, "a misspelled setting is refused, not ignored")
        // the same stations draw sketches
        let made = try await call("create_sections", ["document_id": .string(t.id), "body": "b", "axis": "z", "from": 2, "to": 18, "count": 3, "id": "cut"])
        #expect(made["success"]?.bool == true && made["created"]?["sections"]?.array?.count == 3, "\(made)")
        let loft = try await call("create_loft", ["document_id": .string(t.id), "axis": "z", "ruled": true, "id": "blockagain", "stations": [
            ["offset": 0, "points": [[0, 0], [10, 0], [10, 10], [0, 10]]], ["offset": 8, "points": [[0, 0], [10, 0], [10, 10], [0, 10]]]]])
        #expect(loft["success"]?.bool == true, "\(loft)")
        #expect(abs((t.model.result?.bodies.first { $0.id == "blockagain" }?.body.volume ?? 0) - 800) < 0.5)
    }
}

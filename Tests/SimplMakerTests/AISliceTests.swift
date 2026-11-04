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
}
